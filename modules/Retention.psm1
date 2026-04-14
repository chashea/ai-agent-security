#Requires -Version 7.0

<#
.SYNOPSIS
    Retention policies and labels module for purview-lab-deployer.
.DESCRIPTION
    Deploys retention policies (org-wide, location-scoped) and retention labels
    (item-level, user-applicable) with publish policies.
#>

function Invoke-RetentionRemovalWithRetry {
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [int]$MaxAttempts = 4,
        [int]$LockWaitSeconds = 60
    )

    $attempt = 0
    while ($true) {
        $attempt++
        try {
            & $ScriptBlock
            return
        }
        catch {
            $msg = $_.Exception.Message
            if ($attempt -lt $MaxAttempts -and $msg -match 'PolicyLockConflict|being deployed|try again after some time') {
                Write-LabLog "Policy '$Label' is locked by a pending deployment — waiting ${LockWaitSeconds}s (attempt $attempt/$MaxAttempts)..." -Level Warning
                Start-Sleep -Seconds $LockWaitSeconds
                continue
            }
            throw
        }
    }
}

function Deploy-Retention {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Config
    )

    $manifest = [ordered]@{
        policies = @()
        labels   = @()
    }

    $retentionConfig = $Config.workloads.retention

    # Enterprise AI apps retention lives on a different cmdlet family than the
    # classic mailbox/SPO/OneDrive locations. The App* retention cmdlets
    # (New-AppRetentionCompliancePolicy / New-AppRetentionComplianceRule) are
    # the only documented path for "Enterprise AI apps" — the Foundry
    # interactions item class `IPM.SkypeTeams.Message.ConnectedAIApp.AzureAI.*`
    # is NOT captured by a classic ExchangeLocation policy. See:
    # - https://learn.microsoft.com/powershell/module/exchangepowershell/new-appretentioncompliancepolicy
    # - https://learn.microsoft.com/purview/retention-cmdlets#retention-cmdlets-for-newer-locations
    # - https://learn.microsoft.com/purview/ai-azure-foundry#capabilities-supported
    #
    # The preview requires all three app tokens bundled in a single
    # comma-delimited string passed to -Applications.
    $enterpriseAiLocationAliases = @('EnterpriseAI','EnterpriseAIApps','Enterprise AI apps')
    $enterpriseAiAppIdentifier   = 'User:Entrabased3PAIApps,ChatGPTEnterprise,AzureAIServices'

    foreach ($policy in $retentionConfig.policies) {
        $basePolicyName = "$($Config.prefix)-$($policy.name)"
        $locations = @($policy.locations)

        $enterpriseAiRequested = @($locations | Where-Object { $_ -in $enterpriseAiLocationAliases }).Count -gt 0
        $classicLocations      = @($locations | Where-Object { $_ -notin $enterpriseAiLocationAliases })

        $complianceAction = switch ($policy.retentionAction) {
            'retainAndDelete' { 'KeepAndDelete' }
            'retainOnly'      { 'Keep' }
            default           { 'KeepAndDelete' }
        }

        # ─── Enterprise AI apps path (New-AppRetentionCompliancePolicy) ────
        if ($enterpriseAiRequested) {
            $appPolicyName = if ($classicLocations.Count -gt 0) { "$basePolicyName-ai" } else { $basePolicyName }
            $appRuleName   = "$appPolicyName-rule"

            $newAppCmd = Get-Command New-AppRetentionCompliancePolicy -ErrorAction SilentlyContinue
            if (-not $newAppCmd) {
                Write-LabLog "Retention policy '$appPolicyName' requests Enterprise AI apps but New-AppRetentionCompliancePolicy is not available in this Security & Compliance PowerShell session. The App* retention cmdlet family is required for Foundry interactions. Skipping." -Level Warning
            }
            else {
                $appPolicyExists = $false
                try {
                    Get-AppRetentionCompliancePolicy -Identity $appPolicyName -ErrorAction Stop | Out-Null
                    $appPolicyExists = $true
                    Write-LabLog "App retention policy already exists: $appPolicyName" -Level Info
                }
                catch {
                    Write-LabLog "App retention policy not found, will create: $appPolicyName" -Level Info
                }

                if (-not $appPolicyExists) {
                    if ($PSCmdlet.ShouldProcess($appPolicyName, 'Create App retention compliance policy (Enterprise AI apps)')) {
                        $appPolicyParams = @{
                            Name         = $appPolicyName
                            Applications = @($enterpriseAiAppIdentifier)
                            Enabled      = $true
                        }

                        try {
                            New-AppRetentionCompliancePolicy @appPolicyParams -ErrorAction Stop | Out-Null
                            Write-LabLog "Created App retention policy: $appPolicyName (Enterprise AI apps)" -Level Success
                        }
                        catch {
                            Write-LabLog "Failed to create App retention policy '$appPolicyName': $($_.Exception.Message)" -Level Error
                            $appPolicyName = $null
                        }

                        if ($appPolicyName) {
                            try {
                                New-AppRetentionComplianceRule `
                                    -Policy $appPolicyName `
                                    -Name $appRuleName `
                                    -RetentionDuration $policy.retentionDays `
                                    -RetentionComplianceAction $complianceAction `
                                    -ErrorAction Stop | Out-Null
                                Write-LabLog "Created App retention rule: $appRuleName (${complianceAction}, $($policy.retentionDays) days)" -Level Success
                            }
                            catch {
                                Write-LabLog "Failed to create App retention rule '$appRuleName': $($_.Exception.Message)" -Level Warning
                            }
                        }
                    }
                }

                if ($appPolicyName) {
                    $manifest.policies += [ordered]@{
                        name     = $appPolicyName
                        ruleName = $appRuleName
                        family   = 'app'
                    }
                }
            }
        }

        # ─── Classic locations path (New-RetentionCompliancePolicy) ────────
        if ($classicLocations.Count -eq 0) {
            continue
        }

        $classicPolicyName = if ($enterpriseAiRequested) { "$basePolicyName-classic" } else { $basePolicyName }
        $classicRuleName   = "$classicPolicyName-rule"

        $policyExists = $false
        try {
            Get-RetentionCompliancePolicy -Identity $classicPolicyName -ErrorAction Stop | Out-Null
            $policyExists = $true
            Write-LabLog "Retention policy already exists: $classicPolicyName" -Level Info
        }
        catch {
            Write-LabLog "Retention policy not found, will create: $classicPolicyName" -Level Info
        }

        if (-not $policyExists) {
            if ($PSCmdlet.ShouldProcess($classicPolicyName, 'Create retention compliance policy')) {
                $policyParams = @{ Name = $classicPolicyName }

                foreach ($location in $classicLocations) {
                    switch ($location) {
                        'Exchange'     { $policyParams['ExchangeLocation']     = 'All' }
                        'SharePoint'   { $policyParams['SharePointLocation']   = 'All' }
                        'OneDrive'     { $policyParams['OneDriveLocation']     = 'All' }
                        'ModernGroup'  { $policyParams['ModernGroupLocation']  = 'All' }
                        default        {
                            Write-LabLog "Retention policy '$classicPolicyName' has unknown location '$location' — skipping that location." -Level Warning
                        }
                    }
                }

                if ($policyParams.Count -le 1) {
                    Write-LabLog "Retention policy '$classicPolicyName' has no resolved classic locations. Skipping policy creation." -Level Warning
                    continue
                }

                try {
                    New-RetentionCompliancePolicy @policyParams -ErrorAction Stop | Out-Null
                    Write-LabLog "Created retention policy: $classicPolicyName" -Level Success
                }
                catch {
                    Write-LabLog "Failed to create retention policy '$classicPolicyName': $($_.Exception.Message)" -Level Error
                    continue
                }

                try {
                    New-RetentionComplianceRule `
                        -Policy $classicPolicyName `
                        -Name $classicRuleName `
                        -RetentionDuration $policy.retentionDays `
                        -RetentionComplianceAction $complianceAction `
                        -ErrorAction Stop | Out-Null
                    Write-LabLog "Created retention rule: $classicRuleName (${complianceAction}, $($policy.retentionDays) days)" -Level Success
                }
                catch {
                    Write-LabLog "Failed to create retention rule '$classicRuleName': $($_.Exception.Message)" -Level Warning
                }
            }
        }

        $manifest.policies += [ordered]@{
            name     = $classicPolicyName
            ruleName = $classicRuleName
            family   = 'classic'
        }
    }

    # Retention labels
    if ($retentionConfig.PSObject.Properties['labels'] -and @($retentionConfig.labels).Count -gt 0) {
        foreach ($label in $retentionConfig.labels) {
            $labelName = "$($Config.prefix)-$($label.name)"

            $tagExists = $false
            try {
                Get-ComplianceTag -Identity $labelName -ErrorAction Stop | Out-Null
                $tagExists = $true
                Write-LabLog "Retention label already exists: $labelName" -Level Info
            }
            catch {
                Write-LabLog "Retention label not found, will create: $labelName" -Level Info
            }

            if (-not $tagExists) {
                if ($PSCmdlet.ShouldProcess($labelName, 'Create retention label (ComplianceTag)')) {
                    $complianceAction = switch ($label.retentionAction) {
                        'retainAndDelete' { 'KeepAndDelete' }
                        'retainOnly'      { 'Keep' }
                        default           { 'KeepAndDelete' }
                    }

                    New-ComplianceTag `
                        -Name $labelName `
                        -RetentionAction $complianceAction `
                        -RetentionDuration $label.retentionDays `
                        -RetentionType CreationAgeInDays `
                        -ErrorAction Stop | Out-Null

                    Write-LabLog "Created retention label: $labelName ($complianceAction, $($label.retentionDays) days)" -Level Success

                    # Publish the label via a label policy
                    $publishPolicyName = "$labelName-publish"
                    $publishParams = @{
                        Name = $publishPolicyName
                    }

                    # Use PublishComplianceTag if available, otherwise create policy without it
                    $policyCmdInfo = Get-Command New-RetentionCompliancePolicy -ErrorAction SilentlyContinue
                    if ($policyCmdInfo -and $policyCmdInfo.Parameters.ContainsKey('PublishComplianceTag')) {
                        $publishParams['PublishComplianceTag'] = $labelName
                    }

                    foreach ($location in $label.locations) {
                        switch ($location) {
                            'Exchange'   { $publishParams['ExchangeLocation'] = 'All' }
                            'SharePoint' { $publishParams['SharePointLocation'] = 'All' }
                            'OneDrive'   { $publishParams['OneDriveLocation'] = 'All' }
                        }
                    }

                    New-RetentionCompliancePolicy @publishParams | Out-Null
                    Write-LabLog "Created label publish policy: $publishPolicyName" -Level Success

                    $publishRuleName = "$labelName-publish-rule"
                    $ruleCmdInfo = Get-Command New-RetentionComplianceRule -ErrorAction SilentlyContinue
                    $ruleParams = @{
                        Policy = $publishPolicyName
                        Name   = $publishRuleName
                    }
                    if ($ruleCmdInfo -and $ruleCmdInfo.Parameters.ContainsKey('PublishComplianceTag')) {
                        $ruleParams['PublishComplianceTag'] = $labelName
                    }
                    New-RetentionComplianceRule @ruleParams -ErrorAction Stop | Out-Null

                    Write-LabLog "Created label publish rule: $publishRuleName" -Level Success
                }
            }

            $manifest.labels += [ordered]@{
                tagName           = $labelName
                publishPolicyName = "$labelName-publish"
                publishRuleName   = "$labelName-publish-rule"
            }
        }
    }

    return [PSCustomObject]$manifest
}

function Remove-Retention {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Config,

        [Parameter()]
        [PSCustomObject]$Manifest  # Reserved for manifest-based removal
    )

    $targetPolicies = @()

    if ($Manifest) {
        foreach ($manifestPolicy in @($Manifest.policies)) {
            if ($manifestPolicy -is [string]) {
                $targetPolicies += [PSCustomObject]@{
                    name     = [string]$manifestPolicy
                    ruleName = "$manifestPolicy-rule"
                    family   = 'auto'
                }
            }
            elseif ($manifestPolicy.name) {
                $family = if ($manifestPolicy.PSObject.Properties['family']) { [string]$manifestPolicy.family } else { 'auto' }
                $targetPolicies += [PSCustomObject]@{
                    name     = [string]$manifestPolicy.name
                    ruleName = [string]$manifestPolicy.ruleName
                    family   = $family
                }
            }
        }
    }

    if ($targetPolicies.Count -eq 0) {
        # Best-effort config-based fallback — we don't know which family was used
        # at create time, so try both. Naming varies: if the config policy had
        # Enterprise AI apps + classic locations, Deploy-Retention split it into
        # $name-ai (App*) and $name-classic (classic). Cover every possibility.
        $enterpriseAiAliases = @('EnterpriseAI','EnterpriseAIApps','Enterprise AI apps')
        foreach ($policy in $Config.workloads.retention.policies) {
            $basePolicyName = "$($Config.prefix)-$($policy.name)"
            $locations = @($policy.locations)
            $hasAi      = @($locations | Where-Object { $_ -in $enterpriseAiAliases }).Count -gt 0
            $hasClassic = @($locations | Where-Object { $_ -notin $enterpriseAiAliases }).Count -gt 0

            if ($hasAi -and -not $hasClassic) {
                $targetPolicies += [PSCustomObject]@{ name = $basePolicyName; ruleName = "$basePolicyName-rule"; family = 'app' }
            }
            elseif ($hasClassic -and -not $hasAi) {
                $targetPolicies += [PSCustomObject]@{ name = $basePolicyName; ruleName = "$basePolicyName-rule"; family = 'classic' }
            }
            else {
                $targetPolicies += [PSCustomObject]@{ name = "$basePolicyName-ai"; ruleName = "$basePolicyName-ai-rule"; family = 'app' }
                $targetPolicies += [PSCustomObject]@{ name = "$basePolicyName-classic"; ruleName = "$basePolicyName-classic-rule"; family = 'classic' }
            }
        }
    }

    # Remove retention labels first (reverse of deploy order)
    $targetLabels = @()

    if ($Manifest -and $Manifest.PSObject.Properties['labels']) {
        foreach ($manifestLabel in @($Manifest.labels)) {
            if ($manifestLabel.tagName) {
                $targetLabels += [PSCustomObject]@{
                    tagName           = [string]$manifestLabel.tagName
                    publishPolicyName = [string]$manifestLabel.publishPolicyName
                    publishRuleName   = [string]$manifestLabel.publishRuleName
                }
            }
        }
    }

    if ($targetLabels.Count -eq 0 -and $Config.workloads.retention.PSObject.Properties['labels']) {
        foreach ($label in $Config.workloads.retention.labels) {
            $labelName = "$($Config.prefix)-$($label.name)"
            $targetLabels += [PSCustomObject]@{
                tagName           = $labelName
                publishPolicyName = "$labelName-publish"
                publishRuleName   = "$labelName-publish-rule"
            }
        }
    }

    foreach ($labelInfo in $targetLabels) {
        # Remove publish rule
        try {
            Get-RetentionComplianceRule -Identity $labelInfo.publishRuleName -ErrorAction Stop | Out-Null
            if ($PSCmdlet.ShouldProcess($labelInfo.publishRuleName, 'Remove label publish rule')) {
                Remove-RetentionComplianceRule -Identity $labelInfo.publishRuleName -Confirm:$false -ErrorAction Stop
                Write-LabLog "Removed label publish rule: $($labelInfo.publishRuleName)" -Level Success
            }
        }
        catch {
            Write-LabLog "Label publish rule not found or already removed: $($labelInfo.publishRuleName)" -Level Info
        }

        # Remove publish policy
        try {
            Get-RetentionCompliancePolicy -Identity $labelInfo.publishPolicyName -ErrorAction Stop | Out-Null
            if ($PSCmdlet.ShouldProcess($labelInfo.publishPolicyName, 'Remove label publish policy')) {
                Invoke-RetentionRemovalWithRetry -Label $labelInfo.publishPolicyName -ScriptBlock {
                    Remove-RetentionCompliancePolicy -Identity $labelInfo.publishPolicyName -Confirm:$false -ErrorAction Stop
                }
                Write-LabLog "Removed label publish policy: $($labelInfo.publishPolicyName)" -Level Success
            }
        }
        catch {
            if ($_.Exception.Message -match 'not found|ManagementObjectNotFoundException|ObjectNotFoundException') {
                Write-LabLog "Label publish policy not found or already removed: $($labelInfo.publishPolicyName)" -Level Info
            } else {
                Write-LabLog "Failed to remove label publish policy '$($labelInfo.publishPolicyName)': $($_.Exception.Message)" -Level Warning
            }
        }

        # Remove compliance tag
        try {
            Get-ComplianceTag -Identity $labelInfo.tagName -ErrorAction Stop | Out-Null
            if ($PSCmdlet.ShouldProcess($labelInfo.tagName, 'Remove retention label (ComplianceTag)')) {
                Remove-ComplianceTag -Identity $labelInfo.tagName -Confirm:$false -ErrorAction Stop
                Write-LabLog "Removed retention label: $($labelInfo.tagName)" -Level Success
            }
        }
        catch {
            Write-LabLog "Retention label not found or already removed: $($labelInfo.tagName)" -Level Info
        }
    }

    # Remove retention policies. The App* cmdlet family (for Enterprise AI apps)
    # is separate from the classic family — they don't see each other's policies,
    # so we route removal by the manifest's `family` field. `auto` means we
    # don't know and should try classic first, then App*.
    foreach ($policy in $targetPolicies) {
        $policyName = $policy.name
        $ruleName   = $policy.ruleName
        $family     = if ($policy.PSObject.Properties['family']) { [string]$policy.family } else { 'auto' }

        $tryClassic = $family -in @('classic','auto')
        $tryApp     = $family -in @('app','auto')

        # Remove rules first (classic)
        if ($tryClassic -and -not [string]::IsNullOrWhiteSpace($ruleName)) {
            try {
                Get-RetentionComplianceRule -Identity $ruleName -ErrorAction Stop | Out-Null
                if ($PSCmdlet.ShouldProcess($ruleName, 'Remove retention compliance rule')) {
                    Remove-RetentionComplianceRule -Identity $ruleName -Confirm:$false -ErrorAction Stop
                    Write-LabLog "Removed retention rule: $ruleName" -Level Success
                }
            }
            catch {
                Write-LabLog "Classic retention rule not found or already removed: $ruleName" -Level Info
            }
        }

        # Remove rules first (App*)
        if ($tryApp -and -not [string]::IsNullOrWhiteSpace($ruleName) -and (Get-Command Remove-AppRetentionComplianceRule -ErrorAction SilentlyContinue)) {
            try {
                Get-AppRetentionComplianceRule -Identity $ruleName -ErrorAction Stop | Out-Null
                if ($PSCmdlet.ShouldProcess($ruleName, 'Remove App retention compliance rule')) {
                    Remove-AppRetentionComplianceRule -Identity $ruleName -Confirm:$false -ErrorAction Stop
                    Write-LabLog "Removed App retention rule: $ruleName" -Level Success
                }
            }
            catch {
                Write-LabLog "App retention rule not found or already removed: $ruleName" -Level Info
            }
        }

        # Remove policy (classic)
        if ($tryClassic) {
            try {
                Get-RetentionCompliancePolicy -Identity $policyName -ErrorAction Stop | Out-Null
                if ($PSCmdlet.ShouldProcess($policyName, 'Remove retention compliance policy')) {
                    Invoke-RetentionRemovalWithRetry -Label $policyName -ScriptBlock {
                        Remove-RetentionCompliancePolicy -Identity $policyName -Confirm:$false -ErrorAction Stop
                    }
                    Write-LabLog "Removed retention policy: $policyName" -Level Success
                }
            }
            catch {
                if ($_.Exception.Message -match 'not found|ManagementObjectNotFoundException|ObjectNotFoundException') {
                    Write-LabLog "Classic retention policy not found or already removed: $policyName" -Level Info
                } else {
                    Write-LabLog "Failed to remove classic retention policy '$policyName': $($_.Exception.Message)" -Level Warning
                }
            }
        }

        # Remove policy (App*)
        if ($tryApp -and (Get-Command Remove-AppRetentionCompliancePolicy -ErrorAction SilentlyContinue)) {
            try {
                Get-AppRetentionCompliancePolicy -Identity $policyName -ErrorAction Stop | Out-Null
                if ($PSCmdlet.ShouldProcess($policyName, 'Remove App retention compliance policy')) {
                    Invoke-RetentionRemovalWithRetry -Label $policyName -ScriptBlock {
                        Remove-AppRetentionCompliancePolicy -Identity $policyName -Confirm:$false -ErrorAction Stop
                    }
                    Write-LabLog "Removed App retention policy: $policyName" -Level Success
                }
            }
            catch {
                if ($_.Exception.Message -match 'not found|ManagementObjectNotFoundException|ObjectNotFoundException') {
                    Write-LabLog "App retention policy not found or already removed: $policyName" -Level Info
                } else {
                    Write-LabLog "Failed to remove App retention policy '$policyName': $($_.Exception.Message)" -Level Warning
                }
            }
        }
    }
}

Export-ModuleMember -Function @(
    'Deploy-Retention'
    'Remove-Retention'
)
