#Requires -Version 7.0

<#
.SYNOPSIS
    Main deployment orchestrator for ai-agent-security.

.DESCRIPTION
    Deploys Azure AI Foundry agents wrapped with Microsoft Purview security controls
    in dependency order based on a JSON configuration file. Produces a manifest of all
    created resources for later teardown.

.PARAMETER ConfigPath
    Path to the configuration JSON file. Defaults to config.json in the repo root.

.PARAMETER SkipFoundry
    Skip Foundry and AgentIdentity workloads. Deploy security controls only.

.PARAMETER FoundryOnly
    Deploy Foundry and AgentIdentity only. Skip all Purview security workloads.

.PARAMETER SkipTestUsers
    Skip test user creation entirely. Useful when deploying policies against
    existing tenant users without provisioning new accounts.

.PARAMETER SkipAuth
    Skip connecting to Exchange Online, Microsoft Graph, and Azure (for testing).

.PARAMETER TenantId
    Microsoft Entra tenant ID. Defaults to environment variable PURVIEW_TENANT_ID.
    Required unless -SkipAuth is specified.

.PARAMETER Cloud
    Cloud environment to use (`commercial` or `gcc`). If omitted, uses config value.

.PARAMETER TestUsersMode
    Controls test user provisioning behavior (`create` or `existing`).

.EXAMPLE
    ./Deploy.ps1

.EXAMPLE
    ./Deploy.ps1 -SkipFoundry -TenantId 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx'

.EXAMPLE
    ./Deploy.ps1 -FoundryOnly -Cloud commercial

.EXAMPLE
    ./Deploy.ps1 -ConfigPath ./config.json -WhatIf
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config.json'),

    [Parameter()]
    [switch]$SkipFoundry,

    [Parameter()]
    [switch]$FoundryOnly,

    [Parameter()]
    [switch]$SkipTestUsers,

    [Parameter()]
    [switch]$SkipAuth,

    [Parameter()]
    [string]$TenantId = $env:PURVIEW_TENANT_ID,

    [Parameter()]
    [ValidateSet('commercial', 'gcc')]
    [string]$Cloud = 'commercial',

    [Parameter()]
    [ValidateSet('create', 'existing')]
    [string]$TestUsersMode
)

$ErrorActionPreference = 'Stop'

# Mutual exclusion guard
if ($SkipFoundry -and $FoundryOnly) {
    throw '-SkipFoundry and -FoundryOnly are mutually exclusive. Specify at most one.'
}

# Import Prerequisites early
Import-Module (Join-Path $PSScriptRoot 'modules' 'Prerequisites.psm1') -Force

# Import all modules
foreach ($mod in (Get-ChildItem -Path (Join-Path $PSScriptRoot 'modules') -Filter '*.psm1')) {
    Import-Module $mod.FullName -Force
}

try {
    # Initialize logging
    Initialize-LabLogging -Prefix 'AIAgentSec'
    Write-LabLog -Message 'Deploy started.' -Level Info

    # Load configuration
    Write-LabStep -StepName 'Config' -Description 'Loading configuration'
    $Config = Import-LabConfig -ConfigPath $ConfigPath
    if (-not (Test-LabConfigValidity -Config $Config)) {
        Write-LabLog -Message 'Configuration has validation warnings. Review above messages.' -Level Warning
    }
    $resolvedCloud = Resolve-LabCloud -Cloud $Cloud -Config $Config

    # Apply SkipTestUsers override
    if ($SkipTestUsers -and $Config.workloads.PSObject.Properties['testUsers'] -and $Config.workloads.testUsers) {
        if ($Config.workloads.testUsers.PSObject.Properties['enabled']) {
            $Config.workloads.testUsers.enabled = $false
        }
        else {
            $Config.workloads.testUsers | Add-Member -NotePropertyName 'enabled' -NotePropertyValue $false
        }
        Write-LabLog -Message 'Test user creation skipped (-SkipTestUsers).' -Level Info
    }

    # Apply TestUsersMode: CLI flag wins, else respect config, else default to 'create'
    if ($Config.workloads.PSObject.Properties['testUsers'] -and $Config.workloads.testUsers) {
        $configHasMode = $Config.workloads.testUsers.PSObject.Properties['mode'] -and
                         -not [string]::IsNullOrWhiteSpace($Config.workloads.testUsers.mode)

        if (-not [string]::IsNullOrWhiteSpace($TestUsersMode)) {
            $effectiveMode = $TestUsersMode
        }
        elseif ($configHasMode) {
            $effectiveMode = $Config.workloads.testUsers.mode
        }
        else {
            $effectiveMode = 'create'
        }

        if ($Config.workloads.testUsers.PSObject.Properties['mode']) {
            $Config.workloads.testUsers.mode = $effectiveMode
        }
        else {
            $Config.workloads.testUsers | Add-Member -NotePropertyName 'mode' -NotePropertyValue $effectiveMode
        }
    }

    Write-LabLog -Message "Lab: $($Config.labName) | Prefix: $($Config.prefix) | Domain: $($Config.domain) | Cloud: $resolvedCloud" -Level Info
    if ($SkipFoundry) {
        Write-LabLog -Message 'Mode: Security only (-SkipFoundry).' -Level Info
    }
    elseif ($FoundryOnly) {
        Write-LabLog -Message 'Mode: Foundry only (-FoundryOnly).' -Level Info
    }
    else {
        Write-LabLog -Message 'Mode: Full deployment (Foundry + Security).' -Level Info
    }

    # Determine whether Foundry workloads are active
    $foundryConfigEnabled = $Config.workloads.PSObject.Properties['foundry'] -and $Config.workloads.foundry.enabled
    $deployFoundry = $foundryConfigEnabled -and -not $SkipFoundry

    # Test prerequisites
    Write-LabStep -StepName 'Prerequisites' -Description 'Validating prerequisites'
    $checkFoundryModules = $deployFoundry -and -not $SkipAuth
    if (-not (Test-LabPrerequisites -IncludeFoundry:$checkFoundryModules)) {
        Write-LabLog -Message 'Prerequisites check failed. Exiting.' -Level Error
        exit 1
    }
    Write-LabLog -Message 'All prerequisites satisfied.' -Level Success

    # Connect to services
    if (-not $SkipAuth) {
        if ([string]::IsNullOrWhiteSpace($TenantId)) {
            throw 'TenantId is required when authentication is enabled. Use -TenantId or set PURVIEW_TENANT_ID.'
        }

        Write-LabStep -StepName 'Auth' -Description 'Connecting to cloud services'
        $needsPurview = -not $FoundryOnly
        $azureSubscriptionId = if ($deployFoundry -and $Config.workloads.foundry.PSObject.Properties['subscriptionId']) {
            [string]$Config.workloads.foundry.subscriptionId
        }
        else { $null }
        Connect-LabServices -TenantId $TenantId `
            -SkipExchange:(-not $needsPurview) `
            -SkipGraph:(-not $needsPurview) `
            -ConnectAzure:$deployFoundry `
            -AzureSubscriptionId $azureSubscriptionId
        $services = [System.Collections.Generic.List[string]]::new()
        if ($needsPurview) { $services.Add('Exchange Online'); $services.Add('Microsoft Graph') }
        if ($deployFoundry) { $services.Add('Azure') }
        Write-LabLog -Message "Connected to $($services -join ', ')." -Level Success

        if ($needsPurview) {
            $resolvedDomain = Resolve-LabTenantDomain -ConfiguredDomain $Config.domain
            if (-not [string]::Equals($resolvedDomain, [string]$Config.domain, [System.StringComparison]::OrdinalIgnoreCase)) {
                Write-LabLog -Message "Configured domain '$($Config.domain)' is not verified in this tenant. Using '$resolvedDomain'." -Level Warning
                $Config.domain = $resolvedDomain
            }
        }
    }
    else {
        Write-LabLog -Message 'Skipping authentication (-SkipAuth).' -Level Warning
    }

    # DLP enforcement preflight (only when DLP is enabled and not FoundryOnly and not SkipAuth)
    if (-not $FoundryOnly -and -not $SkipAuth -and $Config.workloads.PSObject.Properties['dlp'] -and $Config.workloads.dlp.enabled) {
        Write-LabStep -StepName 'DLPPreflight' -Description 'Validating DLP enforcement configuration'

        $dlpPreflightBlockers = [System.Collections.Generic.List[string]]::new()
        $dlpPreflightWarnings = [System.Collections.Generic.List[string]]::new()
        $newPolicyCommand = Get-Command -Name New-DlpCompliancePolicy -ErrorAction SilentlyContinue
        $setPolicyCommand = Get-Command -Name Set-DlpCompliancePolicy -ErrorAction SilentlyContinue
        $newRuleCommand = Get-Command -Name New-DlpComplianceRule -ErrorAction SilentlyContinue
        $setRuleCommand = Get-Command -Name Set-DlpComplianceRule -ErrorAction SilentlyContinue
        $policyCommands = @($newPolicyCommand, $setPolicyCommand) | Where-Object { $_ }
        $ruleCommands = @($newRuleCommand, $setRuleCommand) | Where-Object { $_ }

        if ($policyCommands.Count -eq 0) {
            $dlpPreflightBlockers.Add('New/Set-DlpCompliancePolicy cmdlets are unavailable.')
        }
        if ($ruleCommands.Count -eq 0) {
            $dlpPreflightBlockers.Add('New/Set-DlpComplianceRule cmdlets are unavailable.')
        }

        if ($policyCommands.Count -gt 0 -and $ruleCommands.Count -gt 0) {
            foreach ($policy in @($Config.workloads.dlp.policies)) {
                $policyName = "$($Config.prefix)-$($policy.name)"

                $appliesToGroups = Get-LabStringArray -Value $policy.appliesToGroups
                if ($appliesToGroups.Count -gt 0) {
                    $scopeSupport = Get-LabSupportedParameterName -Commands $policyCommands -CandidateNames @('ExchangeSenderMemberOf', 'ExchangeSenderMemberOfGroups', 'UserScope')
                    if (-not $scopeSupport) {
                        $dlpPreflightWarnings.Add("Policy '$policyName' uses appliesToGroups, but no supported policy scope parameter exists on Set/New-DlpCompliancePolicy. Group scoping will be ignored.")
                    }
                }

                $excludeGroups = Get-LabStringArray -Value $policy.excludeGroups
                if ($excludeGroups.Count -gt 0) {
                    $excludeSupport = Get-LabSupportedParameterName -Commands $policyCommands -CandidateNames @('ExceptIfUserMemberOf', 'ExchangeSenderMemberOfException', 'ExcludedUsers')
                    if (-not $excludeSupport) {
                        $dlpPreflightWarnings.Add("Policy '$policyName' uses excludeGroups, but no supported exclusion parameter exists. Exclusions will be ignored.")
                    }
                }

                foreach ($rule in @($policy.rules)) {
                    $ruleName = "$($Config.prefix)-$($rule.name)"
                    $configuredLabels = Get-LabDlpConfiguredLabels -Policy $policy -Rule $rule
                    if ($configuredLabels.Count -gt 0) {
                        $labelSupport = Get-LabSupportedParameterName -Commands $ruleCommands -CandidateNames @('SensitivityLabels', 'SensitivityLabel', 'Labels')
                        if (-not $labelSupport) {
                            $dlpPreflightWarnings.Add("Rule '$ruleName' uses label conditions, but Set/New-DlpComplianceRule has no supported label parameter. Label conditions will be ignored.")
                        }
                    }

                    $enforcement = if (($rule.PSObject.Properties.Name -contains 'enforcement') -and $null -ne $rule.enforcement) { $rule.enforcement } else { $null }
                    if (-not $enforcement) {
                        continue
                    }

                    $action = if (($enforcement.PSObject.Properties.Name -contains 'action') -and -not [string]::IsNullOrWhiteSpace([string]$enforcement.action)) {
                        ([string]$enforcement.action).Trim()
                    }
                    else {
                        $null
                    }

                    if ($action) {
                        $actionSupport = Get-LabSupportedParameterName -Commands $ruleCommands -CandidateNames @('BlockAccess', 'Mode', 'EnforcementMode', 'Action')
                        if (-not $actionSupport) {
                            $dlpPreflightWarnings.Add("Rule '$ruleName' requests enforcement action '$action', but no supported action parameter exists on Set/New-DlpComplianceRule. Baseline rule creation will continue.")
                        }

                        if ($action -eq 'allowWithJustification') {
                            $overrideSupport = Get-LabSupportedParameterName -Commands $ruleCommands -CandidateNames @('AllowOverrideWithJustification', 'AllowOverride', 'UserCanOverride')
                            if (-not $overrideSupport) {
                                $dlpPreflightWarnings.Add("Rule '$ruleName' requests allowWithJustification, but no override parameter exists on Set/New-DlpComplianceRule. Rule will fall back to audit behavior.")
                            }
                        }
                    }

                    $notifySupport = Get-LabSupportedParameterName -Commands $ruleCommands -CandidateNames @('NotifyUser', 'UserNotificationEnabled')
                    if (-not $notifySupport) {
                        $dlpPreflightWarnings.Add("Rule '$ruleName' has enforcement configured, but no supported notify parameter exists.")
                    }
                    $policyTipSupport = Get-LabSupportedParameterName -Commands $ruleCommands -CandidateNames @('NotifyPolicyTipCustomText', 'PolicyTipCustomText')
                    if (-not $policyTipSupport) {
                        $dlpPreflightWarnings.Add("Rule '$ruleName' has enforcement configured, but no supported policy tip parameter exists.")
                    }

                    if (($enforcement.PSObject.Properties.Name -contains 'alert') -and $null -ne $enforcement.alert -and [bool]$enforcement.alert.enabled) {
                        $alertSupport = Get-LabSupportedParameterName -Commands $ruleCommands -CandidateNames @('GenerateAlert', 'AlertEnabled')
                        if (-not $alertSupport) {
                            $dlpPreflightWarnings.Add("Rule '$ruleName' requests alerts, but no supported alert parameter exists.")
                        }
                    }

                    if (($enforcement.PSObject.Properties.Name -contains 'incidentReport') -and $null -ne $enforcement.incidentReport -and [bool]$enforcement.incidentReport.enabled) {
                        $incidentSupport = Get-LabSupportedParameterName -Commands $ruleCommands -CandidateNames @('IncidentReportEnabled', 'GenerateIncidentReport')
                        if (-not $incidentSupport) {
                            $dlpPreflightWarnings.Add("Rule '$ruleName' requests incident reports, but no supported incident-report parameter exists.")
                        }
                    }
                }
            }
        }

        foreach ($warning in @($dlpPreflightWarnings | Sort-Object -Unique)) {
            Write-LabLog -Message $warning -Level Warning
        }

        if ($dlpPreflightBlockers.Count -gt 0) {
            $blockerSummary = (@($dlpPreflightBlockers | Sort-Object -Unique) -join '; ')
            throw "DLP enforcement preflight failed: $blockerSummary"
        }

        Write-LabLog -Message 'DLP enforcement preflight passed.' -Level Success
    }

    # Initialize manifest
    $manifest = @{}
    $failedWorkloads = @()
    $deployedWorkloads = @()

    # Helper: deploy a workload with error isolation
    function Invoke-Workload {
        param([string]$Name, [string]$Step, [string]$Description, [scriptblock]$Action)
        Write-LabStep -StepName $Step -Description $Description
        try {
            $result = & $Action
            if ($result) { $manifest[$Name] = $result }
            $script:deployedWorkloads += $Name
            Write-LabLog -Message "$Step deployment complete." -Level Success
        }
        catch {
            Write-LabLog -Message "$Step FAILED: $_" -Level Error
            $script:failedWorkloads += $Name
        }
    }

    function Test-DeployedEntityExists {
        param(
            [Parameter(Mandatory)]
            [string]$EntityType,

            [Parameter(Mandatory)]
            [string]$EntityName,

            [Parameter(Mandatory)]
            [scriptblock]$CheckAction
        )

        $maxAttempts = 6

        for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
            try {
                if (& $CheckAction $EntityName) {
                    return $true
                }
            }
            catch {
                if ($attempt -eq $maxAttempts) {
                    throw "Validation check failed for $EntityType '$EntityName': $($_.Exception.Message)"
                }

                Write-LabLog -Message "Validation check error for $EntityType '$EntityName' (attempt $attempt/$maxAttempts): $($_.Exception.Message)" -Level Warning
            }

            if ($attempt -lt $maxAttempts) {
                Start-Sleep -Seconds 5
            }
        }

        return $false
    }

    # Deploy workloads in dependency order
    # Foundry deploys first — agents must exist before Purview policies that govern them

    if (-not $SkipFoundry) {
        if ($foundryConfigEnabled) {
            Invoke-Workload -Name 'foundry' -Step 'Foundry' -Description 'Deploying Azure AI Foundry account, project, and agents' -Action {
                Deploy-Foundry -Config $Config -WhatIf:$WhatIfPreference
            }
            Invoke-Workload -Name 'agentIdentity' -Step 'AgentIdentity' -Description 'Configuring agent managed identity and RBAC' -Action {
                Deploy-AgentIdentity -Config $Config -FoundryManifest $manifest['foundry'] -WhatIf:$WhatIfPreference
            }
        }
        else {
            Write-LabLog -Message 'foundry workload is disabled in config, skipping.' -Level Info
        }
    }
    else {
        Write-LabLog -Message 'Foundry and AgentIdentity skipped (-SkipFoundry).' -Level Info
    }

    # Security workloads — skipped when -FoundryOnly is set
    if (-not $FoundryOnly) {

        if ($Config.workloads.PSObject.Properties['testUsers'] -and $Config.workloads.testUsers.enabled) {
            Invoke-Workload -Name 'testUsers' -Step 'TestUsers' -Description 'Deploying test users' -Action {
                Deploy-TestUsers -Config $Config -WhatIf:$WhatIfPreference
            }
        }
        else { Write-LabLog -Message 'testUsers workload is disabled, skipping.' -Level Info }

        if ($Config.workloads.PSObject.Properties['sensitivityLabels'] -and $Config.workloads.sensitivityLabels.enabled) {
            Invoke-Workload -Name 'sensitivityLabels' -Step 'SensitivityLabels' -Description 'Deploying sensitivity labels' -Action {
                Deploy-SensitivityLabels -Config $Config -WhatIf:$WhatIfPreference
            }
        }
        else { Write-LabLog -Message 'sensitivityLabels workload is disabled, skipping.' -Level Info }

        if ($Config.workloads.PSObject.Properties['collectionPolicies'] -and $Config.workloads.collectionPolicies.enabled) {
            Invoke-Workload -Name 'collectionPolicies' -Step 'CollectionPolicies' -Description 'Deploying DSPM-for-AI collection policies (prerequisite for DLP/IRM/CC/eDiscovery/Retention)' -Action {
                Deploy-CollectionPolicies -Config $Config -WhatIf:$WhatIfPreference
            }
        }
        else { Write-LabLog -Message 'collectionPolicies workload is disabled, skipping.' -Level Info }

        if ($Config.workloads.PSObject.Properties['dlp'] -and $Config.workloads.dlp.enabled) {
            Invoke-Workload -Name 'dlp' -Step 'DLP' -Description 'Deploying DLP policies' -Action {
                Deploy-DLP -Config $Config -WhatIf:$WhatIfPreference
            }
        }
        else { Write-LabLog -Message 'dlp workload is disabled, skipping.' -Level Info }

        if ($Config.workloads.PSObject.Properties['retention'] -and $Config.workloads.retention.enabled) {
            Invoke-Workload -Name 'retention' -Step 'Retention' -Description 'Deploying retention policies' -Action {
                Deploy-Retention -Config $Config -WhatIf:$WhatIfPreference
            }
        }
        else { Write-LabLog -Message 'retention workload is disabled, skipping.' -Level Info }

        if ($Config.workloads.PSObject.Properties['eDiscovery'] -and $Config.workloads.eDiscovery.enabled) {
            Invoke-Workload -Name 'eDiscovery' -Step 'EDiscovery' -Description 'Deploying eDiscovery cases' -Action {
                Deploy-EDiscovery -Config $Config -WhatIf:$WhatIfPreference
            }
        }
        else { Write-LabLog -Message 'eDiscovery workload is disabled, skipping.' -Level Info }

        if ($Config.workloads.PSObject.Properties['communicationCompliance'] -and $Config.workloads.communicationCompliance.enabled) {
            Invoke-Workload -Name 'communicationCompliance' -Step 'CommunicationCompliance' -Description 'Deploying communication compliance policies' -Action {
                Deploy-CommunicationCompliance -Config $Config -WhatIf:$WhatIfPreference
            }
        }
        else { Write-LabLog -Message 'communicationCompliance workload is disabled, skipping.' -Level Info }

        if ($Config.workloads.PSObject.Properties['insiderRisk'] -and $Config.workloads.insiderRisk.enabled) {
            Invoke-Workload -Name 'insiderRisk' -Step 'InsiderRisk' -Description 'Deploying insider risk management policies' -Action {
                Deploy-InsiderRisk -Config $Config -WhatIf:$WhatIfPreference
            }
        }
        else { Write-LabLog -Message 'insiderRisk workload is disabled, skipping.' -Level Info }

        if ($Config.workloads.PSObject.Properties['conditionalAccess'] -and $Config.workloads.conditionalAccess.enabled) {
            Invoke-Workload -Name 'conditionalAccess' -Step 'ConditionalAccess' -Description 'Deploying Conditional Access policies' -Action {
                Deploy-ConditionalAccess -Config $Config -WhatIf:$WhatIfPreference
            }
        }

        if ($Config.workloads.PSObject.Properties['mdca'] -and $Config.workloads.mdca.enabled) {
            Invoke-Workload -Name 'mdca' -Step 'MDCA' -Description 'Configuring Defender for Cloud Apps policies' -Action {
                Deploy-MDCA -Config $Config -FoundryManifest $manifest['foundry'] -WhatIf:$WhatIfPreference
            }
        }

        if ($Config.workloads.PSObject.Properties['auditConfig'] -and $Config.workloads.auditConfig.enabled) {
            Invoke-Workload -Name 'auditConfig' -Step 'AuditConfig' -Description 'Configuring audit logging for AI activities' -Action {
                Deploy-AuditConfig -Config $Config -WhatIf:$WhatIfPreference
            }
        }

    }
    else {
        Write-LabLog -Message 'Security workloads skipped (-FoundryOnly).' -Level Info
    }

    # Export manifest (skip in WhatIf)
    $manifestPath = $null
    if (-not $WhatIfPreference) {
        $manifestDir = Join-Path $PSScriptRoot 'manifests'
        if (-not (Test-Path $manifestDir)) {
            New-Item -ItemType Directory -Path $manifestDir -Force | Out-Null
        }
        $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $manifestPath = Join-Path $manifestDir "$($Config.prefix)_${timestamp}.json"
        Export-LabManifest -ManifestData ([PSCustomObject]$manifest) -OutputPath $manifestPath
        Write-LabLog -Message "Manifest exported to $manifestPath" -Level Success
    }
    else {
        Write-LabLog -Message 'WhatIf mode is active. Skipping manifest export.' -Level Info
    }

    # Post-deploy validation
    if (-not $WhatIfPreference -and -not $SkipAuth -and -not $FoundryOnly) {
        Write-LabStep -StepName 'Validation' -Description 'Validating deployed objects'
        $validationFailures = [System.Collections.Generic.List[string]]::new()
        $validationWarnings = [System.Collections.Generic.List[string]]::new()

        if ($manifest.ContainsKey('testUsers') -and $manifest.testUsers -and $manifest.testUsers.groups) {
            foreach ($groupName in @($manifest.testUsers.groups)) {
                $targetGroupName = [string]$groupName
                if ([string]::IsNullOrWhiteSpace($targetGroupName)) {
                    continue
                }

                $groupExists = Test-DeployedEntityExists -EntityType 'Group' -EntityName $targetGroupName -CheckAction {
                    param($name)
                    # Use Invoke-MgGraphRequest directly rather than Get-MgGroup -Filter.
                    # The Get-MgGroup SDK cmdlet has been observed returning "Expected literal...
                    # Was '<'" JSON-parse errors against this tenant — the raw request is more
                    # predictable and lets us distinguish HTML (session state corruption) from
                    # real 404s.
                    $escapedName = $name.Replace("'", "''")
                    $uri = "/v1.0/groups?`$filter=displayName eq '$escapedName'&`$count=true"
                    $response = Invoke-MgGraphRequest -Method GET -Uri $uri -Headers @{ 'ConsistencyLevel' = 'eventual' } -ErrorAction Stop
                    $values = @()
                    if ($response -is [System.Collections.IDictionary] -and $response.Contains('value')) {
                        $values = @($response['value'])
                    }
                    elseif ($response.PSObject.Properties['value']) {
                        $values = @($response.value)
                    }
                    Write-LabLog -Message "Group validation '$name': response value count = $($values.Count)" -Level Info
                    return ($values.Count -gt 0)
                }

                if (-not $groupExists) {
                    $validationFailures.Add("Group '$targetGroupName'")
                }
            }
        }

        if ($manifest.ContainsKey('dlp') -and $manifest.dlp -and $manifest.dlp.policies) {
            foreach ($policyName in @($manifest.dlp.policies)) {
                $targetPolicyName = [string]$policyName
                if ([string]::IsNullOrWhiteSpace($targetPolicyName)) {
                    continue
                }

                $policyExists = Test-DeployedEntityExists -EntityType 'DLP policy' -EntityName $targetPolicyName -CheckAction {
                    param($name)
                    $policy = Get-DlpCompliancePolicy -Identity $name -ErrorAction Stop
                    return [bool]$policy
                }

                if (-not $policyExists) {
                    $validationFailures.Add("DLP policy '$targetPolicyName'")
                }
            }
        }

        if ($Config.workloads.PSObject.Properties['dlp'] -and $Config.workloads.dlp.enabled -and $Config.workloads.dlp.policies) {
            foreach ($policy in @($Config.workloads.dlp.policies)) {
                $targetPolicyName = "$($Config.prefix)-$($policy.name)"
                foreach ($rule in @($policy.rules)) {
                    $targetRuleName = "$($Config.prefix)-$($rule.name)"

                    $ruleExists = Test-DeployedEntityExists -EntityType 'DLP rule' -EntityName $targetRuleName -CheckAction {
                        param($name)
                        $ruleObject = Get-DlpComplianceRule -Identity $name -ErrorAction Stop
                        return [bool]$ruleObject
                    }

                    if (-not $ruleExists) {
                        $validationWarnings.Add("DLP rule '$targetRuleName' could not be validated (may be access denied or transient)")
                        continue
                    }

                    $ruleObject = Get-DlpComplianceRule -Identity $targetRuleName -ErrorAction Stop
                    $configuredLabels = Get-LabDlpConfiguredLabels -Policy $policy -Rule $rule
                    if ($configuredLabels.Count -gt 0) {
                        $labelsProp = Get-LabObjectProperty -Object $ruleObject -CandidateNames @('SensitivityLabels', 'SensitivityLabel', 'Labels')
                        if ($labelsProp.found) {
                            $actualLabels = Get-LabStringArray -Value $labelsProp.value
                            foreach ($expectedLabel in $configuredLabels) {
                                if ($expectedLabel -notin $actualLabels) {
                                    $validationFailures.Add("DLP rule '$targetRuleName' missing expected label condition '$expectedLabel'")
                                }
                            }
                        }
                        else {
                            $validationWarnings.Add("DLP rule '$targetRuleName' configured labels could not be validated because no label property was returned by Get-DlpComplianceRule.")
                        }
                    }

                    $enforcement = if (($rule.PSObject.Properties.Name -contains 'enforcement') -and $null -ne $rule.enforcement) { $rule.enforcement } else { $null }
                    if (-not $enforcement) {
                        continue
                    }

                    $ruleCommands = @('New-DlpComplianceRule', 'Set-DlpComplianceRule') | ForEach-Object { Get-Command $_ -ErrorAction SilentlyContinue } | Where-Object { $_ }
                    $actionParamSupported = [bool](Get-LabSupportedParameterName -Commands $ruleCommands -CandidateNames @('BlockAccess', 'Mode', 'EnforcementMode', 'Action'))
                    $overrideParamSupported = [bool](Get-LabSupportedParameterName -Commands $ruleCommands -CandidateNames @('AllowOverrideWithJustification', 'AllowOverride', 'UserCanOverride'))
                    $notifyParamSupported = [bool](Get-LabSupportedParameterName -Commands $ruleCommands -CandidateNames @('NotifyUser', 'UserNotificationEnabled'))
                    $alertParamSupported = [bool](Get-LabSupportedParameterName -Commands $ruleCommands -CandidateNames @('GenerateAlert', 'AlertEnabled'))

                    $action = if (($enforcement.PSObject.Properties.Name -contains 'action') -and -not [string]::IsNullOrWhiteSpace([string]$enforcement.action)) {
                        ([string]$enforcement.action).Trim()
                    }
                    else {
                        $null
                    }

                    if ($action -and $actionParamSupported) {
                        $blockProp = Get-LabObjectProperty -Object $ruleObject -CandidateNames @('BlockAccess')
                        if ($blockProp.found) {
                            $isBlocked = [bool]$blockProp.value
                            if ($action -eq 'block' -and -not $isBlocked) {
                                $validationWarnings.Add("DLP rule '$targetRuleName' expected block action but BlockAccess is not enabled (enforcement may have fallen back to baseline).")
                            }
                            if ($action -eq 'auditOnly' -and $isBlocked) {
                                $validationWarnings.Add("DLP rule '$targetRuleName' expected auditOnly action but BlockAccess is enabled.")
                            }
                        }
                        else {
                            $modeProp = Get-LabObjectProperty -Object $ruleObject -CandidateNames @('Mode', 'EnforcementMode', 'Action')
                            if ($modeProp.found) {
                                $modeValue = [string]$modeProp.value
                                if ($action -eq 'block' -and $modeValue -notmatch 'Enforce|Block') {
                                    $validationWarnings.Add("DLP rule '$targetRuleName' expected block action but $($modeProp.name)='$modeValue' (enforcement may have fallen back to baseline).")
                                }
                                if ($action -eq 'auditOnly' -and $modeValue -match 'Enforce|Block') {
                                    $validationWarnings.Add("DLP rule '$targetRuleName' expected auditOnly action but $($modeProp.name)='$modeValue'.")
                                }
                            }
                            else {
                                $validationWarnings.Add("DLP rule '$targetRuleName' action '$action' could not be validated due to missing BlockAccess/Mode property.")
                            }
                        }
                    }
                    elseif ($action -and -not $actionParamSupported) {
                        $validationWarnings.Add("DLP rule '$targetRuleName' action '$action' skipped validation — cmdlet does not support action parameters in this environment.")
                    }

                    if ($action -eq 'allowWithJustification' -and $overrideParamSupported) {
                        $overrideProp = Get-LabObjectProperty -Object $ruleObject -CandidateNames @('AllowOverrideWithJustification', 'AllowOverride', 'UserCanOverride')
                        if ($overrideProp.found) {
                            if (-not [bool]$overrideProp.value) {
                                $validationWarnings.Add("DLP rule '$targetRuleName' expected user override for justification but '$($overrideProp.name)' is disabled (enforcement may have fallen back).")
                            }
                        }
                        else {
                            $validationWarnings.Add("DLP rule '$targetRuleName' allowWithJustification could not be validated due to missing override property.")
                        }
                    }
                    elseif ($action -eq 'allowWithJustification' -and -not $overrideParamSupported) {
                        $validationWarnings.Add("DLP rule '$targetRuleName' allowWithJustification skipped validation — cmdlet does not support override parameters.")
                    }

                    if (($enforcement.PSObject.Properties.Name -contains 'userNotification') -and $null -ne $enforcement.userNotification -and [bool]$enforcement.userNotification.enabled) {
                        if ($notifyParamSupported) {
                            $notifyProp = Get-LabObjectProperty -Object $ruleObject -CandidateNames @('NotifyUser', 'UserNotificationEnabled')
                            if ($notifyProp.found -and -not [bool]$notifyProp.value) {
                                $validationWarnings.Add("DLP rule '$targetRuleName' expected user notification enabled but '$($notifyProp.name)' is disabled (enforcement may have fallen back).")
                            }
                        }
                        else {
                            $validationWarnings.Add("DLP rule '$targetRuleName' user notification skipped validation — cmdlet does not support notification parameters.")
                        }
                    }

                    if (($enforcement.PSObject.Properties.Name -contains 'alert') -and $null -ne $enforcement.alert -and [bool]$enforcement.alert.enabled) {
                        if ($alertParamSupported) {
                            $alertProp = Get-LabObjectProperty -Object $ruleObject -CandidateNames @('GenerateAlert', 'AlertEnabled')
                            if ($alertProp.found -and -not [bool]$alertProp.value) {
                                $validationWarnings.Add("DLP rule '$targetRuleName' expected alert generation enabled but '$($alertProp.name)' is disabled (enforcement may have fallen back).")
                            }
                        }
                        else {
                            $validationWarnings.Add("DLP rule '$targetRuleName' alert generation skipped validation — cmdlet does not support alert parameters.")
                        }
                    }
                }
            }
        }

        if ($manifest.ContainsKey('retention') -and $manifest.retention -and $manifest.retention.policies) {
            foreach ($manifestPolicy in @($manifest.retention.policies)) {
                $targetPolicyName = $null
                if ($manifestPolicy -is [string]) {
                    $targetPolicyName = [string]$manifestPolicy
                }
                elseif ($manifestPolicy.name) {
                    $targetPolicyName = [string]$manifestPolicy.name
                }

                if ([string]::IsNullOrWhiteSpace($targetPolicyName)) {
                    continue
                }

                $policyExists = Test-DeployedEntityExists -EntityType 'Retention policy' -EntityName $targetPolicyName -CheckAction {
                    param($name)
                    $policy = Get-RetentionCompliancePolicy -Identity $name -ErrorAction Stop
                    return [bool]$policy
                }

                if (-not $policyExists) {
                    $validationFailures.Add("Retention policy '$targetPolicyName'")
                }
            }
        }

        if ($manifest.ContainsKey('eDiscovery') -and $manifest.eDiscovery -and $manifest.eDiscovery.cases) {
            foreach ($manifestCase in @($manifest.eDiscovery.cases)) {
                $targetCaseName = [string]$manifestCase.caseName
                $targetCaseId = [string]$manifestCase.caseId
                if ([string]::IsNullOrWhiteSpace($targetCaseName)) {
                    continue
                }

                # Prefer direct GET by caseId — avoids OData filter edge cases (URL encoding,
                # eventual-consistency 404s on the filter endpoint) that don't affect a direct
                # object lookup. Fall back to displayName filter if the manifest lacks an id.
                $checkCase = {
                    param($name)
                    if (-not [string]::IsNullOrWhiteSpace($targetCaseId)) {
                        $response = Invoke-MgGraphRequest -Method GET -Uri "/v1.0/security/cases/ediscoveryCases/$targetCaseId" -ErrorAction Stop
                        $caseObjId = $null
                        if ($response -is [System.Collections.IDictionary] -and $response.Contains('id')) {
                            $caseObjId = [string]$response['id']
                        }
                        elseif ($response.PSObject.Properties['id']) {
                            $caseObjId = [string]$response.id
                        }
                        Write-LabLog -Message "eDiscovery case validation '$name': got id='$caseObjId'" -Level Info
                        return (-not [string]::IsNullOrWhiteSpace($caseObjId))
                    }

                    $filter = "displayName eq '$($name -replace "'","''")'"
                    $response = Invoke-MgGraphRequest -Method GET -Uri "/v1.0/security/cases/ediscoveryCases?`$filter=$filter" -ErrorAction Stop
                    $values = @()
                    if ($response -is [System.Collections.IDictionary] -and $response.Contains('value')) {
                        $values = @($response['value'])
                    }
                    elseif ($response.PSObject.Properties['value']) {
                        $values = @($response.value)
                    }
                    Write-LabLog -Message "eDiscovery case validation '$name' (filter): value count = $($values.Count)" -Level Info
                    return ($values.Count -gt 0)
                }.GetNewClosure()

                $caseExists = Test-DeployedEntityExists -EntityType 'eDiscovery case' -EntityName $targetCaseName -CheckAction $checkCase

                if (-not $caseExists) {
                    $validationFailures.Add("eDiscovery case '$targetCaseName'")
                }
            }
        }

        if ($manifest.ContainsKey('communicationCompliance') -and $manifest.communicationCompliance -and $manifest.communicationCompliance.policies) {
            foreach ($manifestPolicy in @($manifest.communicationCompliance.policies)) {
                $targetPolicyName = $null
                if ($manifestPolicy -is [string]) {
                    $targetPolicyName = [string]$manifestPolicy
                }
                elseif ($manifestPolicy.policyName) {
                    $targetPolicyName = [string]$manifestPolicy.policyName
                }
                elseif ($manifestPolicy.name) {
                    $targetPolicyName = [string]$manifestPolicy.name
                }

                if ([string]::IsNullOrWhiteSpace($targetPolicyName)) {
                    continue
                }

                $policyExists = Test-DeployedEntityExists -EntityType 'DSPM for AI policy' -EntityName $targetPolicyName -CheckAction {
                    param($name)
                    $policy = Get-FeatureConfiguration -FeatureScenario KnowYourData -ErrorAction Stop |
                        Where-Object { $_.Name -eq $name } |
                        Select-Object -First 1
                    return [bool]$policy
                }

                if (-not $policyExists) {
                    $validationFailures.Add("DSPM for AI policy '$targetPolicyName'")
                }
            }
        }

        if ($manifest.ContainsKey('insiderRisk') -and $manifest.insiderRisk -and $manifest.insiderRisk.policies) {
            foreach ($manifestPolicy in @($manifest.insiderRisk.policies)) {
                $targetPolicyName = $null
                if ($manifestPolicy -is [string]) {
                    $targetPolicyName = [string]$manifestPolicy
                }
                elseif ($manifestPolicy.name) {
                    $targetPolicyName = [string]$manifestPolicy.name
                }

                if ([string]::IsNullOrWhiteSpace($targetPolicyName)) {
                    continue
                }

                $policyExists = Test-DeployedEntityExists -EntityType 'Insider Risk policy' -EntityName $targetPolicyName -CheckAction {
                    param($name)
                    $policy = Get-InsiderRiskPolicy -ErrorAction Stop |
                        Where-Object { $_.Name -eq $name } |
                        Select-Object -First 1
                    return [bool]$policy
                }

                if (-not $policyExists) {
                    $validationFailures.Add("Insider Risk policy '$targetPolicyName'")
                }
            }
        }

        if ($validationFailures.Count -gt 0) {
            $failureSummary = ($validationFailures | Sort-Object -Unique) -join ', '
            throw "Post-deploy validation failed. Missing or inaccessible objects: $failureSummary"
        }

        foreach ($validationWarning in @($validationWarnings | Sort-Object -Unique)) {
            Write-LabLog -Message $validationWarning -Level Warning
        }

        Write-LabLog -Message 'Post-deploy validation passed for groups/policies/cases/rules in deployed workloads.' -Level Success
    }
    elseif ($WhatIfPreference) {
        Write-LabLog -Message 'Skipping post-deploy validation in WhatIf mode.' -Level Info
    }
    elseif ($SkipAuth) {
        Write-LabLog -Message 'Skipping post-deploy validation because authentication is disabled (-SkipAuth).' -Level Warning
    }
    elseif ($FoundryOnly) {
        Write-LabLog -Message 'Skipping post-deploy validation for security workloads (-FoundryOnly).' -Level Info
    }

    # Summary
    $configuredWorkloads = @($Config.workloads.PSObject.Properties.Name)
    $disabledWorkloads = @(
        $configuredWorkloads | Where-Object { -not [bool]$Config.workloads.$_.enabled }
    )
    $successfulWorkloads = @($deployedWorkloads | Sort-Object -Unique)
    $errorSkippedWorkloads = @($failedWorkloads | Sort-Object -Unique)

    $deployedCount = $manifest.Keys.Count
    Write-LabStep -StepName 'Summary' -Description 'Deployment complete'
    Write-LabLog -Message "Workloads deployed: $deployedCount" -Level Info
    if ($successfulWorkloads.Count -gt 0) {
        Write-LabLog -Message "Workloads deployed successfully: $($successfulWorkloads -join ', ')" -Level Info
    }
    if ($manifestPath) {
        Write-LabLog -Message "Manifest: $manifestPath" -Level Info
    }
    if ($errorSkippedWorkloads.Count -gt 0) {
        Write-LabLog -Message "Workloads skipped due to error: $($errorSkippedWorkloads -join ', ')" -Level Warning
        Write-LabLog -Message 'Re-run to retry failed workloads.' -Level Warning
    }
    if ($disabledWorkloads.Count -gt 0) {
        Write-LabLog -Message "Workloads skipped by config: $($disabledWorkloads -join ', ')" -Level Info
    }
    if ($errorSkippedWorkloads.Count -eq 0) {
        Write-LabLog -Message 'Deploy finished successfully.' -Level Success
    }
}
catch {
    Write-LabLog -Message "Deploy failed: $_" -Level Error
    Write-LabLog -Message $_.ScriptStackTrace -Level Error
    throw
}
finally {
    # Intentionally do NOT call Disconnect-LabServices here. Disconnect-MgGraph and
    # Disconnect-ExchangeOnline clear the MSAL token cache for this client, so the next
    # deploy would have to re-authenticate from scratch (browser/device code). Letting the
    # process exit preserves the on-disk token cache so subsequent runs SSO silently until
    # the refresh token expires.
    Complete-LabLogging
}
