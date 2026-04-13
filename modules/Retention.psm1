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

    foreach ($policy in $retentionConfig.policies) {
        $policyName = "$($Config.prefix)-$($policy.name)"

        $policyExists = $false
        try {
            Get-RetentionCompliancePolicy -Identity $policyName -ErrorAction Stop | Out-Null
            $policyExists = $true
            Write-LabLog "Retention policy already exists: $policyName" -Level Info
        }
        catch {
            Write-LabLog "Retention policy not found, will create: $policyName" -Level Info
        }

        if (-not $policyExists) {
            if ($PSCmdlet.ShouldProcess($policyName, 'Create retention compliance policy')) {
                $policyParams = @{
                    Name = $policyName
                }

                # Resolve location names against the installed New-RetentionCompliancePolicy
                # cmdlet. "EnterpriseAI" / "Enterprise AI apps" is the Purview portal location
                # for Foundry / Copilot interactions per docs/foundry-purview-integration.md §5.3,
                # but the PowerShell cmdlet in this environment doesn't yet expose an
                # EnterpriseAILocation parameter. Since Foundry agent interactions are stored in
                # the user's Exchange mailbox (that's the underlying persistence per MS Learn),
                # fall back to ExchangeLocation scoped to the configured test users — this DOES
                # cover Foundry interactions, it's just broader than the dedicated portal location.
                $newRetentionCmd = Get-Command New-RetentionCompliancePolicy -ErrorAction SilentlyContinue
                foreach ($location in $policy.locations) {
                    switch ($location) {
                        'Exchange'     { $policyParams['ExchangeLocation']     = 'All' }
                        'SharePoint'   { $policyParams['SharePointLocation']   = 'All' }
                        'OneDrive'     { $policyParams['OneDriveLocation']     = 'All' }
                        'ModernGroup'  { $policyParams['ModernGroupLocation']  = 'All' }
                        { $_ -in @('EnterpriseAI','EnterpriseAIApps','Enterprise AI apps') } {
                            $dedicatedParamFound = $false
                            foreach ($candidate in @('EnterpriseAILocation', 'EnterpriseAIAppsLocation')) {
                                if ($newRetentionCmd -and $newRetentionCmd.Parameters.ContainsKey($candidate)) {
                                    $policyParams[$candidate] = 'All'
                                    $dedicatedParamFound = $true
                                    Write-LabLog "Retention policy '$policyName' using $candidate for EnterpriseAI location." -Level Info
                                    break
                                }
                            }
                            if (-not $dedicatedParamFound) {
                                # Fall back to ExchangeLocation scoped to configured test users.
                                # Foundry/Copilot interactions are stored in the user's mailbox, so
                                # a mailbox-scoped retention policy covers them (broader than
                                # Enterprise AI apps but correct). Use all configured test user
                                # identities as the scope.
                                $testUserUpns = [System.Collections.Generic.List[string]]::new()
                                if ($Config.workloads.PSObject.Properties['testUsers'] -and $Config.workloads.testUsers.PSObject.Properties['users']) {
                                    foreach ($u in @($Config.workloads.testUsers.users)) {
                                        $upn = $null
                                        if ($u.PSObject.Properties['upn'] -and -not [string]::IsNullOrWhiteSpace([string]$u.upn)) {
                                            $upn = [string]$u.upn
                                        }
                                        elseif ($u.PSObject.Properties['identity'] -and -not [string]::IsNullOrWhiteSpace([string]$u.identity)) {
                                            $upn = [string]$u.identity
                                        }
                                        if ($upn) { $testUserUpns.Add($upn) }
                                    }
                                }
                                if ($testUserUpns.Count -gt 0) {
                                    $policyParams['ExchangeLocation'] = $testUserUpns.ToArray()
                                    Write-LabLog "Retention policy '$policyName' falling back to ExchangeLocation scoped to test users ($($testUserUpns.Count) mailboxes) — the PowerShell cmdlet does not yet expose a dedicated EnterpriseAI location parameter. Foundry interactions are stored in user mailboxes so this policy still covers them. See docs/foundry-purview-integration.md §5.3." -Level Info
                                }
                                else {
                                    Write-LabLog "Retention policy '$policyName' requests EnterpriseAI location and falls back to ExchangeLocation, but no test users are configured to scope the mailbox location. Skipping policy." -Level Warning
                                }
                            }
                        }
                        default {
                            Write-LabLog "Retention policy '$policyName' has unknown location '$location' — skipping." -Level Warning
                        }
                    }
                }

                if ($policyParams.Count -le 1) {
                    Write-LabLog "Retention policy '$policyName' has no resolved locations. Skipping policy creation." -Level Warning
                    continue
                }

                try {
                    New-RetentionCompliancePolicy @policyParams -ErrorAction Stop | Out-Null
                    Write-LabLog "Created retention policy: $policyName" -Level Success
                }
                catch {
                    Write-LabLog "Failed to create retention policy '$policyName': $($_.Exception.Message)" -Level Error
                    continue
                }

                # Map config action to compliance action
                $complianceAction = switch ($policy.retentionAction) {
                    'retainAndDelete' { 'KeepAndDelete' }
                    'retainOnly'      { 'Keep' }
                    default           { 'KeepAndDelete' }
                }

                $ruleName = "$policyName-rule"
                try {
                    New-RetentionComplianceRule `
                        -Policy $policyName `
                        -Name $ruleName `
                        -RetentionDuration $policy.retentionDays `
                        -RetentionComplianceAction $complianceAction `
                        -ErrorAction Stop | Out-Null
                    Write-LabLog "Created retention rule: $ruleName (${complianceAction}, $($policy.retentionDays) days)" -Level Success
                }
                catch {
                    Write-LabLog "Failed to create retention rule '$ruleName': $($_.Exception.Message)" -Level Warning
                }
            }
        }

        $manifest.policies += [ordered]@{
            name     = $policyName
            ruleName = "$policyName-rule"
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
                }
            }
            elseif ($manifestPolicy.name) {
                $targetPolicies += [PSCustomObject]@{
                    name     = [string]$manifestPolicy.name
                    ruleName = [string]$manifestPolicy.ruleName
                }
            }
        }
    }

    if ($targetPolicies.Count -eq 0) {
        foreach ($policy in $Config.workloads.retention.policies) {
            $policyName = "$($Config.prefix)-$($policy.name)"
            $targetPolicies += [PSCustomObject]@{
                name     = $policyName
                ruleName = "$policyName-rule"
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

    # Remove retention policies
    foreach ($policy in $targetPolicies) {
        $policyName = $policy.name
        $ruleName = $policy.ruleName

        # Remove rules first
        if (-not [string]::IsNullOrWhiteSpace($ruleName)) {
            try {
                Get-RetentionComplianceRule -Identity $ruleName -ErrorAction Stop | Out-Null
                if ($PSCmdlet.ShouldProcess($ruleName, 'Remove retention compliance rule')) {
                    Remove-RetentionComplianceRule -Identity $ruleName -Confirm:$false -ErrorAction Stop
                    Write-LabLog "Removed retention rule: $ruleName" -Level Success
                }
            }
            catch {
                Write-LabLog "Retention rule not found or already removed: $ruleName" -Level Info
            }
        }
        else {
            try {
                $rules = Get-RetentionComplianceRule -Policy $policyName -ErrorAction Stop
                foreach ($rule in $rules) {
                    if ($PSCmdlet.ShouldProcess($rule.Name, 'Remove retention compliance rule')) {
                        Remove-RetentionComplianceRule -Identity $rule.Name -Confirm:$false -ErrorAction Stop
                        Write-LabLog "Removed retention rule: $($rule.Name)" -Level Success
                    }
                }
            }
            catch {
                Write-LabLog "Retention rules not found or already removed for policy: $policyName" -Level Info
            }
        }

        # Remove policy
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
                Write-LabLog "Retention policy not found or already removed: $policyName" -Level Info
            } else {
                Write-LabLog "Failed to remove retention policy '$policyName': $($_.Exception.Message)" -Level Warning
            }
        }
    }
}

Export-ModuleMember -Function @(
    'Deploy-Retention'
    'Remove-Retention'
)
