#Requires -Version 7.0

<#
.SYNOPSIS
    DLP workload module for purview-lab-deployer.
#>

$script:LocationParamCandidates = @{
    'Exchange'            = @('ExchangeLocation')
    'SharePoint'          = @('SharePointLocation')
    'OneDrive'            = @('OneDriveLocation')
    'Teams'               = @('TeamsLocation')
    'Devices'             = @('EndpointDlpLocation', 'DevicesLocation', 'DeviceLocation')
    'Copilot'             = @('CopilotLocation', 'M365CopilotLocation', 'ThirdPartyAppDlpLocation')
    'CopilotExperiences'  = @('CopilotLocation', 'M365CopilotLocation')
    'Browser'             = @('ThirdPartyAppDlpLocation', 'BrowserDlpLocation', 'BrowserLocation')
    'Network'             = @('NetworkDlpLocation', 'NetworkLocation')
    'EnterpriseAI'        = @('CopilotLocation', 'M365CopilotLocation')
}

# Fixed GUID for "Microsoft 365 Copilot and Copilot Chat" in the -Locations JSON payload.
# Used as fallback when no dedicated CopilotLocation parameter exists on the cmdlet.
$script:CopilotLocationGuid = '470f2276-e011-4e9d-a6ec-20768be3a4b0'

function Get-LabSupportedParameterName {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.CommandInfo]$CommandInfo,

        [Parameter(Mandatory)]
        [string[]]$CandidateNames
    )

    foreach ($candidate in $CandidateNames) {
        if ($CommandInfo.Parameters.ContainsKey($candidate)) {
            return $candidate
        }
    }

    return $null
}

function Get-LabDlpLocationParameter {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$Location,

        [Parameter(Mandatory)]
        [System.Management.Automation.CommandInfo]$CommandInfo
    )

    $candidates = @($script:LocationParamCandidates[$Location])
    foreach ($candidate in $candidates) {
        if ($CommandInfo.Parameters.ContainsKey($candidate)) {
            return $candidate
        }
    }

    return $null
}

function Get-LabDlpLocationParameters {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string[]]$Locations,

        [Parameter(Mandatory)]
        [System.Management.Automation.CommandInfo]$CommandInfo,

        [Parameter(Mandatory)]
        [string]$PolicyName,

        [switch]$PreferAddParameters
    )

    $locationParams = @{}
    $unresolvedCopilotExperiences = $false

    foreach ($location in @($Locations | Sort-Object -Unique)) {
        $baseParam = Get-LabDlpLocationParameter -Location $location -CommandInfo $CommandInfo
        if (-not $baseParam) {
            if ($location -eq 'CopilotExperiences') {
                $unresolvedCopilotExperiences = $true
                continue
            }
            Write-LabLog -Message "DLP location '$location' is not supported by cmdlet '$($CommandInfo.Name)' in this environment for policy '$PolicyName'. Skipping this location." -Level Warning
            continue
        }

        $targetParam = $baseParam
        $addParam = "Add$baseParam"
        if ($PreferAddParameters -and $CommandInfo.Parameters.ContainsKey($addParam)) {
            $targetParam = $addParam
        }
        elseif (-not $CommandInfo.Parameters.ContainsKey($baseParam) -and $CommandInfo.Parameters.ContainsKey($addParam)) {
            $targetParam = $addParam
        }

        if (-not $CommandInfo.Parameters.ContainsKey($targetParam)) {
            Write-LabLog -Message "DLP location parameter '$targetParam' was not available on cmdlet '$($CommandInfo.Name)' for policy '$PolicyName'." -Level Warning
            continue
        }

        $locationParams[$targetParam] = 'All'
    }

    # CopilotExperiences fallback: when no dedicated CopilotLocation parameter
    # exists, use the -Locations JSON payload + -EnforcementPlanes approach
    # documented in New-DlpCompliancePolicy Example 4 on Microsoft Learn.
    if ($unresolvedCopilotExperiences) {
        if ($CommandInfo.Parameters.ContainsKey('Locations')) {
            $copilotPayload = '[{"Workload":"Applications","Location":"' + $script:CopilotLocationGuid + '","Inclusions":[{"Type":"Tenant","Identity":"All"}]}]'
            $locationParams['Locations'] = $copilotPayload
            Write-LabLog -Message "Copilot location resolved via -Locations JSON payload for policy '$PolicyName' (Microsoft 365 Copilot and Copilot Chat)." -Level Info
        }
        else {
            Write-LabLog -Message "DLP location 'CopilotExperiences' could not be resolved for policy '$PolicyName'. Neither a dedicated CopilotLocation parameter nor the generic -Locations parameter is available on '$($CommandInfo.Name)'." -Level Warning
        }
        if ($CommandInfo.Parameters.ContainsKey('EnforcementPlanes')) {
            $locationParams['EnforcementPlanes'] = @('CopilotExperiences')
        }
    }

    return $locationParams
}

function Get-LabPolicyScopeParameters {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Policy,

        [Parameter(Mandatory)]
        [System.Management.Automation.CommandInfo]$CommandInfo,

        [Parameter(Mandatory)]
        [string]$PolicyName
    )

    $optionalParams = @{}

    $scopeMap = @(
        @{
            ConfigName = 'appliesToGroups'
            Candidates = @('ExchangeSenderMemberOf', 'ExchangeSenderMemberOfGroups', 'UserScope')
            Label      = 'appliesToGroups'
        },
        @{
            ConfigName = 'excludeGroups'
            Candidates = @('ExceptIfUserMemberOf', 'ExchangeSenderMemberOfException', 'ExcludedUsers')
            Label      = 'excludeGroups'
        }
    )

    foreach ($scope in $scopeMap) {
        if (($Policy.PSObject.Properties.Name -notcontains $scope.ConfigName) -or $null -eq $Policy.$($scope.ConfigName)) {
            continue
        }

        $configuredValues = [string[]]@($Policy.$($scope.ConfigName) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Sort-Object -Unique)
        if ($configuredValues.Count -eq 0) {
            continue
        }

        $parameterName = Get-LabSupportedParameterName -CommandInfo $CommandInfo -CandidateNames $scope.Candidates
        if (-not $parameterName) {
            Write-LabLog -Message "Policy '$PolicyName' config field '$($scope.Label)' is set but cmdlet '$($CommandInfo.Name)' does not expose a supported scope parameter." -Level Warning
            continue
        }

        $optionalParams[$parameterName] = $configuredValues
    }

    return $optionalParams
}

function Get-LabDlpRuleOptionalParameters {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Policy,

        [Parameter(Mandatory)]
        [PSCustomObject]$Rule,

        [Parameter(Mandatory)]
        [System.Management.Automation.CommandInfo]$CommandInfo,

        [Parameter(Mandatory)]
        [string]$RuleName
    )

    $optionalParams = @{}

    $labelSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($labelValue in @($Policy.labels) + @($Rule.labels)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$labelValue)) {
            $null = $labelSet.Add(([string]$labelValue).Trim())
        }
    }

    $labels = [string[]]@($labelSet | Sort-Object -Unique)
    if ($labels.Count -gt 0) {
        $labelParameter = Get-LabSupportedParameterName -CommandInfo $CommandInfo -CandidateNames @('SensitivityLabels', 'SensitivityLabel', 'Labels')
        if ($labelParameter) {
            $optionalParams[$labelParameter] = $labels
        }
        else {
            Write-LabLog -Message "Rule '$RuleName' includes label conditions, but '$($CommandInfo.Name)' has no supported label parameter." -Level Warning
        }
    }

    $enforcement = if (($Rule.PSObject.Properties.Name -contains 'enforcement') -and $null -ne $Rule.enforcement) { $Rule.enforcement } else { $null }
    if (-not $enforcement) {
        return $optionalParams
    }

    $enforcementAction = if (($enforcement.PSObject.Properties.Name -contains 'action') -and -not [string]::IsNullOrWhiteSpace([string]$enforcement.action)) {
        ([string]$enforcement.action).Trim()
    }
    else {
        $null
    }

    if ($enforcementAction) {
        $actionSwitchParameter = Get-LabSupportedParameterName -CommandInfo $CommandInfo -CandidateNames @('BlockAccess')
        if ($actionSwitchParameter) {
            switch ($enforcementAction) {
                'block' {
                    $optionalParams[$actionSwitchParameter] = $true
                }
                'auditOnly' {
                    $optionalParams[$actionSwitchParameter] = $false
                }
                'allowWithJustification' {
                    $optionalParams[$actionSwitchParameter] = $false
                }
            }
        }
        else {
            $modeParameter = Get-LabSupportedParameterName -CommandInfo $CommandInfo -CandidateNames @('Mode', 'EnforcementMode', 'Action')
            if ($modeParameter) {
                $optionalParams[$modeParameter] = switch ($enforcementAction) {
                    'block' { 'Enforce' }
                    'auditOnly' { 'Audit' }
                    'allowWithJustification' { 'Audit' }
                    default { $null }
                }
            }
        }

        # CopilotExperiences block: add -RestrictAccess ExcludeContentProcessing per MS Learn guidance
        $isCopilotPolicy = ($Policy.PSObject.Properties.Name -contains 'locations') -and (@($Policy.locations) -contains 'CopilotExperiences')
        if ($enforcementAction -eq 'block' -and $isCopilotPolicy) {
            $restrictParam = Get-LabSupportedParameterName -CommandInfo $CommandInfo -CandidateNames @('RestrictAccess')
            if ($restrictParam) {
                $optionalParams[$restrictParam] = @(@{ setting = 'ExcludeContentProcessing'; value = 'Block' })
            }
        }

        if ($enforcementAction -eq 'allowWithJustification') {
            $overrideParameter = Get-LabSupportedParameterName -CommandInfo $CommandInfo -CandidateNames @('AllowOverrideWithJustification', 'AllowOverride', 'UserCanOverride')
            if ($overrideParameter) {
                $optionalParams[$overrideParameter] = $true
                if ($actionSwitchParameter) {
                    $optionalParams[$actionSwitchParameter] = $true
                }
            }
            else {
                Write-LabLog -Message "Rule '$RuleName' requested allow-with-justification, but '$($CommandInfo.Name)' does not expose an override parameter. Falling back to audit behavior." -Level Warning
            }
        }
    }

    # User notifications — default to enabled when enforcement exists
    $notificationEnabled = $false
    $notificationMessage = $null
    if (($enforcement.PSObject.Properties.Name -contains 'userNotification') -and $null -ne $enforcement.userNotification) {
        $notification = $enforcement.userNotification
        $notificationEnabled = -not (($notification.PSObject.Properties.Name -contains 'enabled') -and -not [bool]$notification.enabled)
        if (($notification.PSObject.Properties.Name -contains 'message') -and -not [string]::IsNullOrWhiteSpace([string]$notification.message)) {
            $notificationMessage = [string]$notification.message
        }
    }
    else {
        # Default: enable notifications when enforcement is configured
        $notificationEnabled = $true
    }

    $defaultPolicyTip = 'This content matches a DLP policy. Contact your compliance team if you believe this is in error.'
    if (-not $notificationMessage) {
        $notificationMessage = $defaultPolicyTip
    }

    if ($notificationEnabled) {
        $notifyParam = Get-LabSupportedParameterName -CommandInfo $CommandInfo -CandidateNames @('NotifyUser', 'UserNotificationEnabled')
        if ($notifyParam) {
            $optionalParams[$notifyParam] = $true
        }
        $messageParam = Get-LabSupportedParameterName -CommandInfo $CommandInfo -CandidateNames @('NotifyUserMessage', 'UserNotificationText')
        if ($messageParam) {
            $optionalParams[$messageParam] = $notificationMessage
        }
    }

    # Policy tip — set separately from email notification
    $policyTipText = if (($enforcement.PSObject.Properties.Name -contains 'policyTip') -and -not [string]::IsNullOrWhiteSpace([string]$enforcement.policyTip)) {
        [string]$enforcement.policyTip
    }
    else {
        $notificationMessage
    }
    $policyTipParam = Get-LabSupportedParameterName -CommandInfo $CommandInfo -CandidateNames @('NotifyPolicyTipCustomText', 'PolicyTipCustomText')
    if ($policyTipParam) {
        $optionalParams[$policyTipParam] = $policyTipText
    }

    if (($enforcement.PSObject.Properties.Name -contains 'alert') -and $null -ne $enforcement.alert) {
        $alert = $enforcement.alert
        if (($alert.PSObject.Properties.Name -contains 'enabled') -and [bool]$alert.enabled) {
            $alertEnabledParam = Get-LabSupportedParameterName -CommandInfo $CommandInfo -CandidateNames @('GenerateAlert', 'AlertEnabled')
            if ($alertEnabledParam) {
                $optionalParams[$alertEnabledParam] = $true
            }
            $severity = if (($alert.PSObject.Properties.Name -contains 'severity') -and -not [string]::IsNullOrWhiteSpace([string]$alert.severity)) {
                (([string]$alert.severity).Trim().Substring(0, 1).ToUpperInvariant() + ([string]$alert.severity).Trim().Substring(1).ToLowerInvariant())
            }
            else {
                $null
            }
            if ($severity) {
                $severityParam = Get-LabSupportedParameterName -CommandInfo $CommandInfo -CandidateNames @('Severity', 'AlertSeverity')
                if ($severityParam) {
                    $optionalParams[$severityParam] = $severity
                }
            }
        }
    }

    if (($enforcement.PSObject.Properties.Name -contains 'incidentReport') -and $null -ne $enforcement.incidentReport) {
        $incident = $enforcement.incidentReport
        if (($incident.PSObject.Properties.Name -contains 'enabled') -and [bool]$incident.enabled) {
            $incidentEnabledParam = Get-LabSupportedParameterName -CommandInfo $CommandInfo -CandidateNames @('IncidentReportEnabled', 'GenerateIncidentReport')
            if ($incidentEnabledParam) {
                $optionalParams[$incidentEnabledParam] = $true
            }
            $incidentSeverity = if (($incident.PSObject.Properties.Name -contains 'severity') -and -not [string]::IsNullOrWhiteSpace([string]$incident.severity)) {
                (([string]$incident.severity).Trim().Substring(0, 1).ToUpperInvariant() + ([string]$incident.severity).Trim().Substring(1).ToLowerInvariant())
            }
            else {
                $null
            }
            if ($incidentSeverity) {
                $incidentSeverityParam = Get-LabSupportedParameterName -CommandInfo $CommandInfo -CandidateNames @('IncidentSeverity', 'IncidentReportSeverity')
                if ($incidentSeverityParam) {
                    $optionalParams[$incidentSeverityParam] = $incidentSeverity
                }
            }
        }
    }

    return $optionalParams
}

function Test-LabDlpNotFoundException {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [System.Exception]$Exception,

        [Parameter(Mandatory)]
        [ValidateSet('Rule', 'Policy')]
        [string]$EntityType
    )

    $current = $Exception
    while ($current) {
        $text = "$($current.GetType().FullName) $($current.Message)"
        if ($EntityType -eq 'Rule' -and (
                $text -match 'ErrorRuleNotFoundException' -or
                $text -match 'There is no rule matching identity'
            )) {
            return $true
        }

        if ($EntityType -eq 'Policy' -and (
                $text -match 'ErrorPolicyNotFoundException' -or
                $text -match 'There is no policy matching identity'
            )) {
            return $true
        }

        if ($text -match 'ManagementObjectNotFoundException') {
            return $true
        }

        $current = $current.InnerException
    }

    return $false
}

function Deploy-DLP {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Config
    )

    $createdPolicies = [System.Collections.Generic.List[string]]::new()
    $createdRules = [System.Collections.Generic.List[string]]::new()
    $newPolicyCommand = Get-Command -Name New-DlpCompliancePolicy -ErrorAction Stop
    $setPolicyCommand = Get-Command -Name Set-DlpCompliancePolicy -ErrorAction SilentlyContinue
    $newRuleCommand = Get-Command -Name New-DlpComplianceRule -ErrorAction Stop
    $setRuleCommand = Get-Command -Name Set-DlpComplianceRule -ErrorAction SilentlyContinue

    # Resolve simulation mode: deploy all policies as TestWithNotifications
    $useSimulationMode = ($Config.workloads.dlp.PSObject.Properties.Name -contains 'simulationMode') -and [bool]$Config.workloads.dlp.simulationMode
    $simulationModeParam = $null
    if ($useSimulationMode) {
        $simulationModeParam = Get-LabSupportedParameterName -CommandInfo $newPolicyCommand -CandidateNames @('Mode')
        if ($simulationModeParam) {
            Write-LabLog -Message "DLP simulation mode enabled -- all policies will deploy as TestWithNotifications." -Level Info
        }
        else {
            Write-LabLog -Message "DLP simulation mode requested but 'New-DlpCompliancePolicy' does not support '-Mode'. Policies will deploy in default mode." -Level Warning
        }
    }

    foreach ($policy in $Config.workloads.dlp.policies) {
        $policyName = "$($Config.prefix)-$($policy.name)"

        # Entra-registered AI app scope (Foundry agents).
        # See docs/foundry-purview-integration.md §5.2 and MS Learn
        # New-DlpComplianceRule example 4. The cmdlet shape is:
        #   New-DlpCompliancePolicy -Mode Enable -Locations <json> -EnforcementPlanes @('Entra')
        # where <json> is a Locations payload with Workload=Applications and
        # the app's client ID.
        $isEntraAiAppScope = ($policy.PSObject.Properties.Name -contains 'scope') -and
                             ([string]$policy.scope -eq 'entraRegisteredAiApp')

        if ($isEntraAiAppScope) {
            # Collect target app identifiers. Config supports three forms:
            #   targetedEntraAppId          (single object/app ID — use as-is)
            #   targetedEntraAppDisplayName (single displayName — Graph lookup)
            #   targetedEntraAppDisplayNames (array — Graph lookup per entry, all
            #                                 resolved apps become Locations entries)
            $resolvedApps = [System.Collections.Generic.List[PSCustomObject]]::new()

            if ($policy.PSObject.Properties.Name -contains 'targetedEntraAppId' -and
                -not [string]::IsNullOrWhiteSpace([string]$policy.targetedEntraAppId)) {
                $resolvedApps.Add([PSCustomObject]@{ appId = [string]$policy.targetedEntraAppId; displayName = 'unknown' })
            }

            $displayNamesToLookup = [System.Collections.Generic.List[string]]::new()
            if ($policy.PSObject.Properties.Name -contains 'targetedEntraAppDisplayName' -and
                -not [string]::IsNullOrWhiteSpace([string]$policy.targetedEntraAppDisplayName)) {
                $displayNamesToLookup.Add([string]$policy.targetedEntraAppDisplayName)
            }
            if ($policy.PSObject.Properties.Name -contains 'targetedEntraAppDisplayNames' -and
                $policy.targetedEntraAppDisplayNames) {
                foreach ($n in @($policy.targetedEntraAppDisplayNames)) {
                    if (-not [string]::IsNullOrWhiteSpace([string]$n)) {
                        $displayNamesToLookup.Add([string]$n)
                    }
                }
            }

            foreach ($displayName in ($displayNamesToLookup | Sort-Object -Unique)) {
                $escaped = $displayName.Replace("'", "''")
                $app = Get-MgApplication -Filter "displayName eq '$escaped'" -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($app) {
                    $resolvedApps.Add([PSCustomObject]@{ appId = [string]$app.AppId; displayName = $displayName })
                    Write-LabLog -Message "Resolved Entra AI app '$displayName' -> $($app.AppId) for policy '$policyName'." -Level Info
                }
                else {
                    Write-LabLog -Message "Entra AI app '$displayName' not found in Graph — omitting from policy '$policyName'." -Level Warning
                }
            }

            if ($resolvedApps.Count -eq 0) {
                Write-LabLog -Message "Policy '$policyName' uses entraRegisteredAiApp scope but no target apps resolved. Skipping policy (will recreate on next deploy if target apps become available)." -Level Warning
                continue
            }

            if (-not $newPolicyCommand.Parameters.ContainsKey('Locations') -or -not $newPolicyCommand.Parameters.ContainsKey('EnforcementPlanes')) {
                Write-LabLog -Message "New-DlpCompliancePolicy in this environment does not expose -Locations / -EnforcementPlanes. The Entra-registered AI app scope requires these parameters. Skipping policy '$policyName'." -Level Warning
                continue
            }

            $locationsArray = foreach ($ra in $resolvedApps) {
                [ordered]@{
                    Workload            = 'Applications'
                    Location            = $ra.appId
                    LocationDisplayName = $ra.displayName
                    LocationSource      = 'Entra'
                    LocationType        = 'Individual'
                    Inclusions          = @(
                        [ordered]@{ Type = 'Tenant'; Identity = 'All' }
                    )
                }
            }
            $locationsPayload = @($locationsArray) | ConvertTo-Json -Compress -Depth 5
            # ConvertTo-Json wraps a single-element array as an object; force array notation
            if ($resolvedApps.Count -eq 1 -and -not $locationsPayload.StartsWith('[')) {
                $locationsPayload = "[$locationsPayload]"
            }

            $createLocationParams = @{
                Locations         = $locationsPayload
                EnforcementPlanes = @('Entra')
            }
            Write-LabLog -Message "DLP policy '$policyName' targeting $($resolvedApps.Count) Entra-registered AI app(s): $(($resolvedApps | ForEach-Object { $_.displayName }) -join ', ')" -Level Info
        }
        else {
            $createLocationParams = Get-LabDlpLocationParameters -Locations ([string[]]@($policy.locations)) -CommandInfo $newPolicyCommand -PolicyName $policyName
        }

        $createScopeParams = Get-LabPolicyScopeParameters -Policy $policy -CommandInfo $newPolicyCommand -PolicyName $policyName
        if (($policy.PSObject.Properties.Name -contains 'policyMode') -and -not [string]::IsNullOrWhiteSpace([string]$policy.policyMode)) {
            Write-LabLog -Message "DLP policy mode for '$policyName': $($policy.policyMode)" -Level Info
        }
        if ($policy.PSObject.Properties.Name -contains 'endpointDlpBrowserRestrictions' -and $policy.endpointDlpBrowserRestrictions) {
            Write-LabLog -Message "Note: Endpoint browser URL restrictions for '$policyName' must be configured in the Purview portal (Endpoint DLP settings > Browser restrictions)." -Level Info
        }

        # Check if policy exists
        $existing = $null
        try {
            $existing = Get-DlpCompliancePolicy -Identity $policyName -ErrorAction Stop
        }
        catch {
            $null = $_ # Policy does not exist
        }

        if ($existing) {
            Write-LabLog -Message "DLP policy already exists: $policyName" -Level Info
            # Don't try to re-apply Locations JSON on an existing Entra-scoped policy — the
            # cmdlet path for updating Entra app scope is not idempotent. Skip the Set- path
            # for those; rule creation below still goes through its own idempotency check.
            $attemptPolicyUpdate = -not $isEntraAiAppScope
            if ($attemptPolicyUpdate -and $setPolicyCommand) {
                $setLocationParams = Get-LabDlpLocationParameters -Locations ([string[]]@($policy.locations)) -CommandInfo $setPolicyCommand -PolicyName $policyName -PreferAddParameters
                $setScopeParams = Get-LabPolicyScopeParameters -Policy $policy -CommandInfo $setPolicyCommand -PolicyName $policyName
                $setParams = @{ Identity = $policyName; ErrorAction = 'Stop' }
                if ($useSimulationMode) {
                    $setModeParam = Get-LabSupportedParameterName -CommandInfo $setPolicyCommand -CandidateNames @('Mode')
                    if ($setModeParam) {
                        $setParams[$setModeParam] = 'TestWithNotifications'
                    }
                }
                foreach ($entry in $setLocationParams.GetEnumerator()) {
                    $setParams[$entry.Key] = $entry.Value
                }
                foreach ($entry in $setScopeParams.GetEnumerator()) {
                    $setParams[$entry.Key] = $entry.Value
                }

                if ($setParams.Count -gt 2) {
                    if ($PSCmdlet.ShouldProcess($policyName, 'Update DLP policy')) {
                        try {
                            Set-DlpCompliancePolicy @setParams | Out-Null
                            $modeLabel = if ($useSimulationMode -and $setParams.ContainsKey('Mode')) { ' (simulation)' } else { '' }
                            Write-LabLog -Message "Updated DLP policy: $policyName$modeLabel" -Level Success
                        }
                        catch {
                            if ($setScopeParams.Count -gt 0 -and $setLocationParams.Count -gt 0) {
                                Write-LabLog -Message "Policy update with optional scope parameters failed for $policyName. Retrying with location-only parameters." -Level Warning
                                try {
                                    Set-DlpCompliancePolicy -Identity $policyName @setLocationParams -ErrorAction Stop | Out-Null
                                    Write-LabLog -Message "Updated DLP policy locations (without optional scope parameters): $policyName" -Level Success
                                }
                                catch {
                                    Write-LabLog -Message "Could not update DLP policy for $policyName`: $($_.Exception.Message)" -Level Warning
                                }
                            }
                            else {
                                Write-LabLog -Message "Could not update DLP policy locations for $policyName`: $($_.Exception.Message)" -Level Warning
                            }
                        }
                    }
                }
            }
        }
        elseif ($PSCmdlet.ShouldProcess($policyName, 'Create DLP policy')) {
            $newPolicyParams = @{
                Name        = $policyName
                ErrorAction = 'Stop'
            }
            if ($useSimulationMode -and $simulationModeParam) {
                $newPolicyParams[$simulationModeParam] = 'TestWithNotifications'
            }
            foreach ($entry in $createLocationParams.GetEnumerator()) {
                $newPolicyParams[$entry.Key] = $entry.Value
            }
            foreach ($entry in $createScopeParams.GetEnumerator()) {
                $newPolicyParams[$entry.Key] = $entry.Value
            }

            try {
                New-DlpCompliancePolicy @newPolicyParams | Out-Null
                $modeLabel = if ($useSimulationMode -and $simulationModeParam) { ' (simulation)' } else { '' }
                Write-LabLog -Message "Created DLP policy: $policyName$modeLabel" -Level Success
            }
            catch {
                if ($createScopeParams.Count -gt 0) {
                    Write-LabLog -Message "Policy creation with optional scope parameters failed for $policyName. Retrying with baseline location parameters." -Level Warning
                    $fallbackParams = @{ Name = $policyName; ErrorAction = 'Stop' }
                    if ($useSimulationMode -and $simulationModeParam) {
                        $fallbackParams[$simulationModeParam] = 'TestWithNotifications'
                    }
                    New-DlpCompliancePolicy @fallbackParams @createLocationParams | Out-Null
                    Write-LabLog -Message "Created DLP policy (without optional scope parameters): $policyName" -Level Success
                }
                else {
                    throw
                }
            }
        }

        $createdPolicies.Add($policyName)

        # --- Rules ---
        foreach ($rule in $policy.rules) {
            $ruleName = "$($Config.prefix)-$($rule.name)"

            $existingRule = $null
            try {
                $existingRule = Get-DlpComplianceRule -Identity $ruleName -ErrorAction Stop
            }
            catch {
                $null = $_ # Rule does not exist
            }

            if ($existingRule) {
                Write-LabLog -Message "DLP rule already exists: $ruleName" -Level Info
                $ruleUpdateParams = if ($setRuleCommand) {
                    Get-LabDlpRuleOptionalParameters -Policy $policy -Rule $rule -CommandInfo $setRuleCommand -RuleName $ruleName
                }
                else {
                    @{}
                }

                if ($setRuleCommand -and $ruleUpdateParams.Count -gt 0 -and $PSCmdlet.ShouldProcess($ruleName, 'Update DLP rule optional enforcement settings')) {
                    try {
                        Set-DlpComplianceRule -Identity $ruleName @ruleUpdateParams -Confirm:$false -ErrorAction Stop | Out-Null
                        Write-LabLog -Message "Updated DLP rule optional settings: $ruleName" -Level Success
                    }
                    catch {
                        Write-LabLog -Message "Could not update optional DLP rule settings for $ruleName`: $($_.Exception.Message)" -Level Warning
                    }
                }
                $createdRules.Add($ruleName)
                continue
            }

            if ($PSCmdlet.ShouldProcess($ruleName, 'Create DLP rule')) {
                $baseRuleParams = @{
                    Name        = $ruleName
                    Policy      = $policyName
                    ErrorAction = 'Stop'
                }

                $hasSensitiveInfoTypes = ($rule.PSObject.Properties['sensitiveInfoTypes'] -and @($rule.sensitiveInfoTypes).Count -gt 0)
                if ($hasSensitiveInfoTypes) {
                    $sitArray = @()
                    foreach ($sit in $rule.sensitiveInfoTypes) {
                        $sitArray += @{
                            name     = $sit
                            minCount = [string]$rule.minCount
                        }
                    }
                    $baseRuleParams['ContentContainsSensitiveInformation'] = $sitArray
                }

                # Adaptive Protection: insider risk level condition
                if ($rule.PSObject.Properties['insiderRiskLevel'] -and -not [string]::IsNullOrWhiteSpace([string]$rule.insiderRiskLevel)) {
                    $riskParam = Get-LabSupportedParameterName -CommandInfo $newRuleCommand -CandidateNames @('IncludeUserRiskLevels')
                    if ($riskParam) {
                        $baseRuleParams[$riskParam] = @([string]$rule.insiderRiskLevel)
                        Write-LabLog -Message "Rule '$ruleName' scoped to insider risk level: $($rule.insiderRiskLevel)" -Level Info
                    }
                    else {
                        Write-LabLog -Message "Rule '$ruleName' requested insider risk level '$($rule.insiderRiskLevel)' but IncludeUserRiskLevels parameter is unavailable. Risk scoping will be skipped." -Level Warning
                    }
                }

                $optionalRuleParams = Get-LabDlpRuleOptionalParameters -Policy $policy -Rule $rule -CommandInfo $newRuleCommand -RuleName $ruleName
                $ruleParams = @{}
                foreach ($entry in $baseRuleParams.GetEnumerator()) {
                    $ruleParams[$entry.Key] = $entry.Value
                }
                foreach ($entry in $optionalRuleParams.GetEnumerator()) {
                    $ruleParams[$entry.Key] = $entry.Value
                }

                $createdWithBaseline = $false
                try {
                    New-DlpComplianceRule @ruleParams | Out-Null
                }
                catch {
                    if ($optionalRuleParams.Count -gt 0) {
                        Write-LabLog -Message "Rule creation with optional enforcement settings failed for $ruleName. Retrying with baseline settings only." -Level Warning
                        New-DlpComplianceRule @baseRuleParams | Out-Null
                        $createdWithBaseline = $true
                    }
                    else {
                        throw
                    }
                }

                if ($createdWithBaseline -and $setRuleCommand -and $optionalRuleParams.Count -gt 0) {
                    $setEnforcementParams = Get-LabDlpRuleOptionalParameters -Policy $policy -Rule $rule -CommandInfo $setRuleCommand -RuleName $ruleName
                    if ($setEnforcementParams.Count -gt 0 -and $PSCmdlet.ShouldProcess($ruleName, 'Apply enforcement settings via Set-DlpComplianceRule')) {
                        try {
                            Set-DlpComplianceRule -Identity $ruleName @setEnforcementParams -Confirm:$false -ErrorAction Stop | Out-Null
                            Write-LabLog -Message "Applied enforcement settings to rule: $ruleName" -Level Success
                        }
                        catch {
                            Write-LabLog -Message "Could not apply enforcement settings to $ruleName`: $($_.Exception.Message)" -Level Warning
                        }
                    }
                }

                Write-LabLog -Message "Created DLP rule: $ruleName" -Level Success
            }

            $createdRules.Add($ruleName)
        }
    }

    return @{
        policies = $createdPolicies.ToArray()
        rules    = $createdRules.ToArray()
    }
}

function Remove-DLP {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Config,

        [Parameter()]
        [PSCustomObject]$Manifest  # Reserved for manifest-based removal
    )

    $targetRules = @()
    $targetPolicies = @()

    if ($Manifest) {
        foreach ($ruleName in @($Manifest.rules)) {
            if (-not [string]::IsNullOrWhiteSpace($ruleName)) {
                $targetRules += [string]$ruleName
            }
        }
        foreach ($policyName in @($Manifest.policies)) {
            if (-not [string]::IsNullOrWhiteSpace($policyName)) {
                $targetPolicies += [string]$policyName
            }
        }
    }

    if ($targetRules.Count -eq 0) {
        foreach ($policy in $Config.workloads.dlp.policies) {
            foreach ($rule in $policy.rules) {
                $targetRules += "$($Config.prefix)-$($rule.name)"
            }
        }
    }

    if ($targetPolicies.Count -eq 0) {
        foreach ($policy in $Config.workloads.dlp.policies) {
            $targetPolicies += "$($Config.prefix)-$($policy.name)"
        }
    }

    $targetRules = @($targetRules | Sort-Object -Unique)
    $targetPolicies = @($targetPolicies | Sort-Object -Unique)

    # Remove rules first (rules depend on policies)
    foreach ($ruleName in $targetRules) {
        $existing = $null
        try {
            $existing = Get-DlpComplianceRule -Identity $ruleName -ErrorAction Stop
        }
        catch {
            $null = $_ # Rule does not exist
        }

        if (-not $existing) {
            Write-LabLog -Message "DLP rule not found, skipping: $ruleName" -Level Warning
            continue
        }

        if ($PSCmdlet.ShouldProcess($ruleName, 'Remove DLP rule')) {
            $retryCount = 0
            $maxRetries = 2
            $deleted = $false
            while (-not $deleted -and $retryCount -le $maxRetries) {
                try {
                    Remove-DlpComplianceRule -Identity $ruleName -Confirm:$false -ErrorAction Stop
                    Write-LabLog -Message "Removed DLP rule: $ruleName" -Level Success
                    $deleted = $true
                }
                catch {
                    if (Test-LabDlpNotFoundException -Exception $_.Exception -EntityType Rule) {
                        Write-LabLog -Message "DLP rule not found during delete, skipping: $ruleName" -Level Warning
                        $deleted = $true
                        continue
                    }

                    if ($retryCount -lt $maxRetries -and $_.Exception.Message -match 'server side error|try again after some time|PolicyLockConflict|being deployed') {
                        $retryCount++
                        $waitSeconds = if ($_.Exception.Message -match 'PolicyLockConflict|being deployed') { 60 } else { 10 }
                        Write-LabLog -Message "Transient error removing DLP rule '$ruleName', retry $retryCount of $maxRetries in ${waitSeconds}s..." -Level Warning
                        Start-Sleep -Seconds $waitSeconds
                    }
                    else {
                        Write-LabLog -Message "Failed to remove DLP rule '$ruleName' after retries: $($_.Exception.Message)" -Level Warning
                        $deleted = $true
                    }
                }
            }
        }
    }

    foreach ($policyName in $targetPolicies) {
        $existingPolicy = $null
        try {
            $existingPolicy = Get-DlpCompliancePolicy -Identity $policyName -ErrorAction Stop
        }
        catch {
            $null = $_ # Policy does not exist
        }

        if (-not $existingPolicy) {
            Write-LabLog -Message "DLP policy not found, skipping: $policyName" -Level Warning
            continue
        }

        if ($PSCmdlet.ShouldProcess($policyName, 'Remove DLP policy')) {
            $retryCount = 0
            $maxRetries = 2
            $deleted = $false
            while (-not $deleted -and $retryCount -le $maxRetries) {
                try {
                    Remove-DlpCompliancePolicy -Identity $policyName -Confirm:$false -ErrorAction Stop
                    Write-LabLog -Message "Removed DLP policy: $policyName" -Level Success
                    $deleted = $true
                }
                catch {
                    if (Test-LabDlpNotFoundException -Exception $_.Exception -EntityType Policy) {
                        Write-LabLog -Message "DLP policy not found during delete, skipping: $policyName" -Level Warning
                        $deleted = $true
                        continue
                    }

                    if ($retryCount -lt $maxRetries -and $_.Exception.Message -match 'server side error|try again after some time|PolicyLockConflict|being deployed') {
                        $retryCount++
                        $waitSeconds = if ($_.Exception.Message -match 'PolicyLockConflict|being deployed') { 60 } else { 10 }
                        Write-LabLog -Message "Transient error removing DLP policy '$policyName', retry $retryCount of $maxRetries in ${waitSeconds}s..." -Level Warning
                        Start-Sleep -Seconds $waitSeconds
                    }
                    else {
                        Write-LabLog -Message "Failed to remove DLP policy '$policyName' after retries: $($_.Exception.Message)" -Level Warning
                        $deleted = $true
                    }
                }
            }
        }
    }
}

Export-ModuleMember -Function @(
    'Deploy-DLP'
    'Remove-DLP'
)
