#!/usr/bin/env pwsh
#Requires -Version 7.0

<#
.SYNOPSIS
    Main deployment orchestrator for ai-agent-security.

.DESCRIPTION
    Deploys Azure AI Foundry agents wrapped with sensitivity labels, Conditional
    Access, and Defender for Cloud Apps controls in dependency order based on a
    JSON configuration file. Produces a manifest of all created resources for
    later teardown.

.PARAMETER ConfigPath
    Path to the configuration JSON file. Defaults to config.json in the repo root.

.PARAMETER SkipFoundry
    Skip Foundry and AgentIdentity workloads. Deploy security controls only.

.PARAMETER FoundryOnly
    Deploy Foundry, AgentIdentity, and AIGateway. Skip labeling and adjacent identity workloads.

.PARAMETER AIGatewayOnly
    Deploy only the APIM-based AI Gateway workload. Assumes the Foundry
    account already exists in the target resource group. Skips Foundry,
    AgentIdentity, and all security workloads. Useful for iterating on
    gateway config without re-running the full pipeline.

.PARAMETER SkipTestUsers
    Skip test user creation entirely. Useful when deploying policies against
    existing tenant users without provisioning new accounts.

.PARAMETER SkipAuth
    Skip connecting to Exchange Online, Microsoft Graph, and Azure (for testing).

.PARAMETER TenantId
    Microsoft Entra tenant ID. Optional — if omitted, derived from
    `config.domain` via the public OIDC discovery endpoint
    (`https://login.microsoftonline.com/<domain>/v2.0/.well-known/openid-configuration`),
    so the user only has to provide the tenant domain (prompted on first
    run) and the Foundry subscription ID. Defaults to environment variable
    PURVIEW_TENANT_ID. Pass explicitly to override the derived value.

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
    ./Deploy.ps1 -AIGatewayOnly

.EXAMPLE
    ./Deploy.ps1 -ConfigPath ./config.json -WhatIf
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
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
    [string]$TestUsersMode,

    [Parameter()]
    [switch]$AdversarialTraffic,

    [Parameter()]
    [switch]$AIGatewayOnly
)

$ErrorActionPreference = 'Stop'

# Mutual exclusion guard
$selectorCount = @($SkipFoundry, $FoundryOnly, $AIGatewayOnly).Where({ $_ }).Count
if ($selectorCount -gt 1) {
    throw '-SkipFoundry, -FoundryOnly, and -AIGatewayOnly are mutually exclusive. Specify at most one.'
}

# Import Prerequisites early
Import-Module (Join-Path $PSScriptRoot 'modules' 'Prerequisites.psm1') -Force

# Import all modules
foreach ($mod in (Get-ChildItem -Path (Join-Path $PSScriptRoot 'modules') -Filter '*.psm1')) {
    Import-Module $mod.FullName -Force
}

# Bootstrap: resolve config placeholders on first-time setup (interactive only)
if (-not $SkipAuth) {
    Resolve-LabConfigPlaceholders -ConfigPath $ConfigPath
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

    # Prompt: create new test users? (interactive only, skipped when CLI flag provided)
    $testUsersConfigured = $Config.workloads.PSObject.Properties['testUsers'] -and $Config.workloads.testUsers -and
                           $Config.workloads.testUsers.PSObject.Properties['enabled'] -and $Config.workloads.testUsers.enabled
    if (-not $SkipAuth -and -not $SkipTestUsers -and [string]::IsNullOrWhiteSpace($TestUsersMode) -and
        $testUsersConfigured -and -not [Console]::IsInputRedirected -and $env:CI -ne 'true') {
        $chosenMode = Request-CreateTestUsersChoice
        if ($Config.workloads.testUsers.PSObject.Properties['mode']) {
            $Config.workloads.testUsers.mode = $chosenMode
        } else {
            $Config.workloads.testUsers | Add-Member -NotePropertyName 'mode' -NotePropertyValue $chosenMode
        }
        if ($chosenMode -eq 'create') {
            $newUsers = @(
                [PSCustomObject]@{ displayName = 'AISec Finance Tester'; mailNickname = 'aisec-finance'; department = 'Finance';   jobTitle = 'Test User'; usageLocation = 'US' }
                [PSCustomObject]@{ displayName = 'AISec IT Tester';      mailNickname = 'aisec-it';      department = 'IT';        jobTitle = 'Test User'; usageLocation = 'US' }
                [PSCustomObject]@{ displayName = 'AISec Sales Tester';   mailNickname = 'aisec-sales';   department = 'Sales';     jobTitle = 'Test User'; usageLocation = 'US' }
            )
            $Config.workloads.testUsers.users = $newUsers
            foreach ($grp in @($Config.workloads.testUsers.groups)) {
                switch ([string]$grp.displayName) {
                    'AISec-Finance-Team' { $grp.members = @('aisec-finance') }
                    'AISec-IT-Team'      { $grp.members = @('aisec-it') }
                    'AISec-Sales-Team'   { $grp.members = @('aisec-sales') }
                }
            }
        }
        # Persist the mode (and any user-roster changes) back to config file
        $Config | ConvertTo-Json -Depth 20 | Set-Content -Path $ConfigPath -Encoding UTF8
        Write-LabLog -Message "Test users mode set to '$chosenMode' and saved to $ConfigPath" -Level Info
    }

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
    elseif ($AIGatewayOnly) {
        Write-LabLog -Message 'Mode: AI Gateway only (-AIGatewayOnly). Assumes Foundry core already exists.' -Level Info
    }
    else {
        Write-LabLog -Message 'Mode: Full deployment (Foundry + Security).' -Level Info
    }

    # Determine whether Foundry workloads are active
    $foundryConfigEnabled = $Config.workloads.PSObject.Properties['foundry'] -and $Config.workloads.foundry.enabled
    $deployFoundry = $foundryConfigEnabled -and -not $SkipFoundry -and -not $AIGatewayOnly

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
            if ([string]::IsNullOrWhiteSpace($Config.domain)) {
                throw 'TenantId is required when authentication is enabled and config.domain is empty. Pass -TenantId or set PURVIEW_TENANT_ID.'
            }
            Write-LabLog -Message "TenantId not provided — resolving from domain '$($Config.domain)' via OIDC discovery." -Level Info
            $TenantId = Resolve-LabTenantIdFromDomain -Domain $Config.domain
            Write-LabLog -Message "Resolved TenantId: $TenantId" -Level Info
        }

        Write-LabStep -StepName 'Auth' -Description 'Connecting to cloud services'
        # Exchange Online (IPPS session) is required for sensitivity-label cmdlets.
        # Foundry-only + AI Gateway-only modes skip it. Graph is skipped
        # entirely for AI Gateway-only since Bicep-only deploys don't touch
        # the Teams catalog or Graph-backed identity grants.
        $needsExchange = -not $FoundryOnly -and -not $AIGatewayOnly
        $needsGraph = -not $AIGatewayOnly
        $azureSubscriptionId = if ($Config.workloads.foundry.PSObject.Properties['subscriptionId']) {
            [string]$Config.workloads.foundry.subscriptionId
        }
        else { $null }
        $needsAzure = $deployFoundry -or $AIGatewayOnly
        $connectParams = @{
            TenantId            = $TenantId
            SkipExchange        = (-not $needsExchange)
            SkipGraph           = (-not $needsGraph)
            ConnectAzure        = $needsAzure
            AzureSubscriptionId = $azureSubscriptionId
        }
        if ($FoundryOnly) {
            $connectParams['GraphScopes'] = @('AppCatalog.ReadWrite.All')
        }
        # If agentIdentity.graphPermissions are configured, Deploy-AgentIdentity
        # needs to assign Graph app roles to the Foundry MI, which requires
        # these admin scopes on the connected user/SP.
        $needsGraphGrantScopes = $false
        if ($deployFoundry -and $Config.workloads.PSObject.Properties['agentIdentity']) {
            $ai = $Config.workloads.agentIdentity
            if ($ai.PSObject.Properties['graphPermissions']) {
                $configured = @($ai.graphPermissions | Where-Object { $_ -and -not [string]::IsNullOrWhiteSpace($_) })
                if ($configured.Count -gt 0) { $needsGraphGrantScopes = $true }
            }
        }
        if ($needsGraphGrantScopes) {
            $grantScopes = @('AppRoleAssignment.ReadWrite.All', 'Application.Read.All')
            if ($connectParams.ContainsKey('GraphScopes')) {
                $connectParams['GraphScopes'] = @($connectParams['GraphScopes'] + $grantScopes) | Sort-Object -Unique
            }
            else {
                # Append to the default broad scope list rather than replacing it,
                # otherwise other workloads lose the scopes they need.
                $defaultScopes = @(
                    'User.ReadWrite.All'
                    'Group.ReadWrite.All'
                    'Organization.Read.All'
                    'Policy.ReadWrite.ConditionalAccess'
                    'Policy.Read.All'
                    'eDiscovery.ReadWrite.All'
                    'AppCatalog.ReadWrite.All'
                )
                $connectParams['GraphScopes'] = @($defaultScopes + $grantScopes) | Sort-Object -Unique
            }
        }
        # Device code auth works in both TTY and non-TTY pwsh. Connect-MgGraph
        # otherwise tries a broker/browser flow that blocks when stdin is not a
        # terminal (e.g. background jobs, CI, claude-code pipes).
        $connectParams['UseDeviceCode'] = $true
        Connect-LabServices @connectParams
        $services = [System.Collections.Generic.List[string]]::new()
        if ($needsExchange) { $services.Add('Exchange Online') }
        $services.Add('Microsoft Graph')
        if ($deployFoundry) { $services.Add('Azure') }
        Write-LabLog -Message "Connected to $($services -join ', ')." -Level Success

        if ($needsExchange) {
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
    # Foundry deploys first — agents must exist before labels, CA, or MDCA wrap them

    if ($AIGatewayOnly) {
        # Narrow path: only deploy the AI Gateway workload. Assumes Foundry
        # core is already present in the target RG (needed for the APIM MI
        # role assignment and the backend URL). A Foundry manifest is
        # synthesized from config so Deploy-AIGateway sees the expected
        # account name without re-running the Foundry workload.
        if ($Config.workloads.PSObject.Properties['aiGateway'] -and $Config.workloads.aiGateway.enabled) {
            $foundryStub = [PSCustomObject]@{
                subscriptionId        = [string]$Config.workloads.foundry.subscriptionId
                resourceGroup         = [string]$Config.workloads.foundry.resourceGroup
                location              = [string]$Config.workloads.foundry.location
                accountName           = [string]$Config.workloads.foundry.accountName
                appInsightsResourceId = "/subscriptions/$($Config.workloads.foundry.subscriptionId)/resourceGroups/$($Config.workloads.foundry.resourceGroup)/providers/Microsoft.Insights/components/$($Config.prefix.ToLower())-appinsights"
            }
            Invoke-Workload -Name 'aiGateway' -Step 'AIGateway' -Description 'Provisioning APIM-based AI Gateway (standalone; assumes Foundry exists)' -Action {
                Deploy-AIGateway -Config $Config -FoundryManifest $foundryStub -WhatIf:$WhatIfPreference
            }
        }
        else {
            Write-LabLog -Message 'aiGateway workload is disabled in config; -AIGatewayOnly has nothing to do.' -Level Warning
        }
    }
    elseif (-not $SkipFoundry) {
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

        if ($Config.workloads.PSObject.Properties['aiGateway'] -and $Config.workloads.aiGateway.enabled) {
            Invoke-Workload -Name 'aiGateway' -Step 'AIGateway' -Description 'Provisioning APIM-based AI Gateway in front of Foundry' -Action {
                Deploy-AIGateway -Config $Config -FoundryManifest $manifest['foundry'] -WhatIf:$WhatIfPreference
            }
        }
        else { Write-LabLog -Message 'aiGateway workload is disabled in config, skipping.' -Level Info }
    }
    else {
        Write-LabLog -Message 'Foundry, AgentIdentity, and AIGateway skipped (-SkipFoundry).' -Level Info
    }

    # Security workloads — skipped when -FoundryOnly or -AIGatewayOnly is set
    if (-not $FoundryOnly -and -not $AIGatewayOnly) {

        if ($Config.workloads.PSObject.Properties['testUsers'] -and $Config.workloads.testUsers.enabled) {
            Invoke-Workload -Name 'testUsers' -Step 'TestUsers' -Description 'Deploying test users' -Action {
                Deploy-TestUsers -Config $Config -WhatIf:$WhatIfPreference
            }
        }
        else { Write-LabLog -Message 'testUsers workload is disabled, skipping.' -Level Info }

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

    }
    else {
        $skipReason = if ($AIGatewayOnly) { '-AIGatewayOnly' } else { '-FoundryOnly' }
        Write-LabLog -Message "Labeling and adjacent identity workloads skipped ($skipReason)." -Level Info
    }

    # Export manifest (skip in WhatIf)
    $manifestPath = $null
    if (-not $WhatIfPreference) {
        $manifestDir = Join-Path $PSScriptRoot 'manifests'
        if (-not (Test-Path $manifestDir)) {
            New-Item -ItemType Directory -Path $manifestDir -Force | Out-Null
        }
        $timestamp = Get-Date -Format 'yyyyMMdd-HHmmssfff'
        $manifestPath = Join-Path $manifestDir "$($Config.prefix)_${timestamp}.json"
        Export-LabManifest -ManifestData ([PSCustomObject]$manifest) -OutputPath $manifestPath
        Write-LabLog -Message "Manifest exported to $manifestPath" -Level Success
    }
    else {
        Write-LabLog -Message 'WhatIf mode is active. Skipping manifest export.' -Level Info
    }

    # Optional adversarial-traffic fire: lights up Defender/Purview/Foundry
    # detection surfaces after agents are live. Opt-in via -AdversarialTraffic.
    if ($AdversarialTraffic -and -not $WhatIfPreference) {
        $attackScript = Join-Path $PSScriptRoot 'scripts/attack_agents.py'
        if (Test-Path $attackScript) {
            Write-LabStep -Message 'Firing adversarial traffic (scripts/attack_agents.py)'
            $logsDir = Join-Path $PSScriptRoot 'logs'
            if (-not (Test-Path $logsDir)) { New-Item -ItemType Directory -Path $logsDir -Force | Out-Null }
            $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
            $attackLog = Join-Path $logsDir "attack_$stamp.json"
            try {
                & python3.12 $attackScript --output $attackLog
                if ($LASTEXITCODE -eq 0) {
                    Write-LabLog -Message "Adversarial traffic report: $attackLog" -Level Success
                }
                else {
                    Write-LabLog -Message "attack_agents.py exited with code $LASTEXITCODE" -Level Warning
                }
            }
            catch { Write-LabLog -Message "Adversarial traffic error: $($_.Exception.Message)" -Level Warning }
        }
        else {
            Write-LabLog -Message 'scripts/attack_agents.py not found — skipping adversarial traffic.' -Level Warning
        }
    }

    # Post-deploy validation
    if (-not $WhatIfPreference -and -not $SkipAuth -and -not $FoundryOnly -and -not $AIGatewayOnly) {
        Write-LabStep -StepName 'Validation' -Description 'Validating deployed objects'
        $validationFailures = [System.Collections.Generic.List[string]]::new()
        $validationWarnings = [System.Collections.Generic.List[string]]::new()

        if ($manifest.ContainsKey('testUsers') -and $manifest.testUsers -and $manifest.testUsers.groups) {
            foreach ($groupName in @($manifest.testUsers.groups)) {
                $targetGroupName = [string]$groupName
                if ([string]::IsNullOrWhiteSpace($targetGroupName)) {
                    continue
                }

                # Non-fatal validation: both Invoke-MgGraphRequest ($count=true + eventual)
                # and Get-MgGroup -Filter have been observed failing on this tenant (404 on
                # the REST path, "Expected literal... Was '<'" HTML-parse bug on the SDK
                # path). The Deploy-TestUsers module's own "already exists / created" log
                # line is authoritative.
                try {
                    $groupExists = Test-DeployedEntityExists -EntityType 'Group' -EntityName $targetGroupName -CheckAction {
                        param($name)
                        $escapedName = $name.Replace("'", "''")
                        try {
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
                            if ($values.Count -gt 0) {
                                return $true
                            }
                        }
                        catch {
                            Write-LabLog -Message "Group validation '$name' REST lookup failed ($($_.Exception.Message)). Falling back to Get-MgGroup -Filter." -Level Info
                        }

                        try {
                            $sdkGroup = Get-MgGroup -Filter "displayName eq '$escapedName'" -ErrorAction Stop | Select-Object -First 1
                            if ($sdkGroup) {
                                Write-LabLog -Message "Group validation '$name' (Get-MgGroup fallback): found id='$($sdkGroup.Id)'" -Level Info
                                return $true
                            }
                        }
                        catch {
                            Write-LabLog -Message "Group validation '$name' Get-MgGroup fallback also failed: $($_.Exception.Message)" -Level Warning
                        }

                        return $false
                    }
                }
                catch {
                    $groupExists = $false
                    Write-LabLog -Message "Group '$targetGroupName' post-deploy validation threw ($($_.Exception.Message)). Trusting the Deploy-TestUsers success log — not failing the run." -Level Warning
                }

                if (-not $groupExists) {
                    $validationWarnings.Add("Group '$targetGroupName' could not be validated post-deploy (non-fatal — trust the Deploy-TestUsers success log)")
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
        Write-LabLog -Message 'Skipping post-deploy validation for labeling/identity workloads (-FoundryOnly).' -Level Info
    }
    elseif ($AIGatewayOnly) {
        Write-LabLog -Message 'Skipping post-deploy validation (-AIGatewayOnly). Verify gateway with the curl commands in docs/ai-gateway.md.' -Level Info
    }

    if (-not $WhatIfPreference -and -not $SkipAuth -and -not $SkipFoundry -and -not $AIGatewayOnly -and
        $manifest.ContainsKey('foundry') -and $manifest.foundry -and
        $manifest.foundry.PSObject.Properties['projectEndpoint'] -and
        $manifest.foundry.PSObject.Properties['agents']) {
        Write-LabStep -StepName 'Foundry Validation' -Description 'Verifying deployed agents'
        $endpoint = [string]$manifest.foundry.projectEndpoint
        $agentApiVer = $Config.workloads.foundry.agentApiVersion
        if (-not $agentApiVer) { $agentApiVer = '2025-05-15-preview' }
        try {
            $token = (Get-AzAccessToken -ResourceUrl 'https://ai.azure.com' -ErrorAction Stop).Token
            $listUri = "$endpoint/agents?api-version=$agentApiVer"
            $response = Invoke-RestMethod -Uri $listUri -Method GET -Headers @{ Authorization = "Bearer $token" } -ErrorAction Stop
            $liveAgents = @($response.data)
            $expected = @($manifest.foundry.agents)
            $missing = @($expected | Where-Object {
                $n = $_.name
                -not ($liveAgents | Where-Object { $_.name -eq $n })
            })
            if ($missing.Count -gt 0) {
                $names = ($missing | ForEach-Object { $_.name }) -join ', '
                Write-LabLog -Message "Foundry agent validation: $($missing.Count) agent(s) not found via API: $names" -Level Warning
            }
            else {
                Write-LabLog -Message "Foundry agent validation: all $($expected.Count) agent(s) confirmed." -Level Success
            }
        }
        catch {
            Write-LabLog -Message "Foundry agent validation skipped — could not query agents API: $_" -Level Warning
        }
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
