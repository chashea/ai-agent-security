#Requires -Version 7.0

<#
.SYNOPSIS
    Conditional Access workload module for purview-lab-deployer.
    Uses Microsoft Graph cmdlets (New/Get/Remove-MgIdentityConditionalAccessPolicy)
    from the Microsoft.Graph.Identity.SignIns module.
#>

function Deploy-ConditionalAccess {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Config
    )

    $createdPolicies = [System.Collections.Generic.List[hashtable]]::new()

    # Validate Graph scopes before attempting CA policy operations
    $context = Get-MgContext -ErrorAction SilentlyContinue
    $grantedScopes = @($context.Scopes)
    $requiredScopes = @('Policy.ReadWrite.ConditionalAccess', 'Policy.Read.All')
    $missingScopes = @($requiredScopes | Where-Object { $_ -notin $grantedScopes })
    if ($missingScopes.Count -gt 0) {
        Write-LabLog -Message "Conditional Access requires Graph scopes not in current token: $($missingScopes -join ', '). Disconnect and reconnect with: Connect-MgGraph -Scopes 'Policy.ReadWrite.ConditionalAccess','Policy.Read.All','Application.Read.All'" -Level Warning
        Write-LabLog -Message "Skipping all Conditional Access policies due to missing scopes." -Level Warning
        return [PSCustomObject]@{ policies = @() }
    }

    foreach ($policy in $Config.workloads.conditionalAccess.policies) {
        $name = "$($Config.prefix)-$($policy.name)"

        try {
            $existing = Get-MgIdentityConditionalAccessPolicy -Filter "displayName eq '$name'" -ErrorAction SilentlyContinue |
                Select-Object -First 1

            if ($existing) {
                Write-LabLog -Message "Conditional Access policy already exists: $name" -Level Info
                $createdPolicies.Add(@{
                    name   = $name
                    id     = $existing.Id
                    status = 'existing'
                })
                continue
            }

            # Build conditions
            $conditions = @{
                Applications = @{ IncludeApplications = @($policy.targetAppIds) }
                Users        = @{ IncludeUsers = @('All') }
            }

            # Support excludeAppIds
            if ($policy.PSObject.Properties['excludeAppIds'] -and $policy.excludeAppIds) {
                $conditions.Applications['ExcludeApplications'] = @($policy.excludeAppIds)
            }

            if ($policy.PSObject.Properties['signInRiskLevels'] -and $policy.signInRiskLevels) {
                $conditions['SignInRiskLevels'] = @($policy.signInRiskLevels)
            }

            # Build grant controls
            $grantControls = @{
                Operator = 'OR'
            }

            if ($policy.action -eq 'block') {
                $grantControls['BuiltInControls'] = @('block')
            }
            elseif ($policy.action -eq 'mfa') {
                $grantControls['BuiltInControls'] = @('mfa')
            }
            elseif ($policy.action -eq 'compliantDevice') {
                $grantControls['BuiltInControls'] = @('compliantDevice')
            }

            # Use report-only mode for lab safety
            $state = if ($policy.PSObject.Properties['state'] -and $policy.state) {
                $policy.state
            } else {
                'enabledForReportingButNotEnforced'
            }

            $bodyParams = @{
                DisplayName   = $name
                State         = $state
                Conditions    = $conditions
                GrantControls = $grantControls
            }

            if ($PSCmdlet.ShouldProcess($name, "Create Conditional Access policy (action: $($policy.action))")) {
                $created = New-MgIdentityConditionalAccessPolicy -BodyParameter $bodyParams -ErrorAction Stop

                Write-LabLog -Message "Created Conditional Access policy: $name (state: $state)" -Level Success
                $createdPolicies.Add(@{
                    name   = $name
                    id     = $created.Id
                    action = $policy.action
                    state  = $state
                    status = 'created'
                })
            }
        }
        catch {
            Write-LabLog -Message "Error creating Conditional Access policy ${name}: $($_.Exception.Message)" -Level Warning
        }
    }

    return [PSCustomObject]@{
        policies = $createdPolicies.ToArray()
    }
}

function Remove-ConditionalAccess {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Config,

        [Parameter()]
        [PSCustomObject]$Manifest
    )

    $targetPolicies = @()

    # Prefer manifest-based removal
    if ($Manifest) {
        foreach ($manifestPolicy in @($Manifest.policies)) {
            if ($manifestPolicy.id) {
                $targetPolicies += @{ name = [string]$manifestPolicy.name; id = [string]$manifestPolicy.id }
            }
            elseif ($manifestPolicy.name) {
                $targetPolicies += @{ name = [string]$manifestPolicy.name; id = $null }
            }
        }
    }

    # Fallback to config-based removal
    if ($targetPolicies.Count -eq 0) {
        foreach ($policy in $Config.workloads.conditionalAccess.policies) {
            $targetPolicies += @{ name = "$($Config.prefix)-$($policy.name)"; id = $null }
        }
    }

    foreach ($target in $targetPolicies) {
        $name = $target.name

        try {
            # Find by ID first, then by name
            $existing = $null
            if ($target.id) {
                $existing = Get-MgIdentityConditionalAccessPolicy -ConditionalAccessPolicyId $target.id -ErrorAction SilentlyContinue
            }
            if (-not $existing) {
                $existing = Get-MgIdentityConditionalAccessPolicy -Filter "displayName eq '$name'" -ErrorAction SilentlyContinue |
                    Select-Object -First 1
            }

            if (-not $existing) {
                Write-LabLog -Message "Conditional Access policy not found, skipping: $name" -Level Warning
                continue
            }

            if ($PSCmdlet.ShouldProcess($name, 'Remove Conditional Access policy')) {
                Remove-MgIdentityConditionalAccessPolicy -ConditionalAccessPolicyId $existing.Id -ErrorAction Stop
                Write-LabLog -Message "Removed Conditional Access policy: $name" -Level Success
            }
        }
        catch {
            Write-LabLog -Message "Error removing Conditional Access policy ${name}: $($_.Exception.Message)" -Level Warning
        }
    }
}

Export-ModuleMember -Function @(
    'Deploy-ConditionalAccess'
    'Remove-ConditionalAccess'
)
