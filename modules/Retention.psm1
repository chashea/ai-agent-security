#Requires -Version 7.0

<#
.SYNOPSIS
    Retention policies and labels module for purview-lab-deployer.
.DESCRIPTION
    Deploys retention policies (org-wide, location-scoped) and retention labels
    (item-level, user-applicable) with publish policies.
#>

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

                foreach ($location in $policy.locations) {
                    switch ($location) {
                        'Exchange'   { $policyParams['ExchangeLocation'] = 'All' }
                        'SharePoint' { $policyParams['SharePointLocation'] = 'All' }
                        'OneDrive'   { $policyParams['OneDriveLocation'] = 'All' }
                    }
                }

                New-RetentionCompliancePolicy @policyParams | Out-Null
                Write-LabLog "Created retention policy: $policyName" -Level Success

                # Map config action to compliance action
                $complianceAction = switch ($policy.retentionAction) {
                    'retainAndDelete' { 'KeepAndDelete' }
                    'retainOnly'      { 'Keep' }
                    default           { 'KeepAndDelete' }
                }

                $ruleName = "$policyName-rule"
                New-RetentionComplianceRule `
                    -Policy $policyName `
                    -Name $ruleName `
                    -RetentionDuration $policy.retentionDays `
                    -RetentionComplianceAction $complianceAction | Out-Null

                Write-LabLog "Created retention rule: $ruleName (${complianceAction}, $($policy.retentionDays) days)" -Level Success
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
                Remove-RetentionCompliancePolicy -Identity $labelInfo.publishPolicyName -Confirm:$false -ErrorAction Stop
                Write-LabLog "Removed label publish policy: $($labelInfo.publishPolicyName)" -Level Success
            }
        }
        catch {
            Write-LabLog "Label publish policy not found or already removed: $($labelInfo.publishPolicyName)" -Level Info
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
                Remove-RetentionCompliancePolicy -Identity $policyName -Confirm:$false -ErrorAction Stop
                Write-LabLog "Removed retention policy: $policyName" -Level Success
            }
        }
        catch {
            Write-LabLog "Retention policy not found or already removed: $policyName" -Level Info
        }
    }
}

Export-ModuleMember -Function @(
    'Deploy-Retention'
    'Remove-Retention'
)
