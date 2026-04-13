#Requires -Version 7.0

<#
.SYNOPSIS
    DSPM-for-AI collection policies workload module for ai-agent-security.

.DESCRIPTION
    Creates the DSPM-for-AI "Know Your Data" collection policies via the
    Security & Compliance PowerShell FeatureConfiguration cmdlets. These
    policies are a prerequisite for DLP, Insider Risk, Communication
    Compliance, eDiscovery, and Data Lifecycle Management to receive
    Microsoft Foundry prompts and responses. See
    docs/foundry-purview-integration.md §5.1.
#>

function Deploy-CollectionPolicies {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Config
    )

    Write-LabStep -StepName 'CollectionPolicies' -Description 'Deploying DSPM-for-AI collection policies (prerequisite for DLP/IRM/CC/eDiscovery/Retention)'

    $createdPolicies = [System.Collections.Generic.List[string]]::new()
    $skippedPolicies = [System.Collections.Generic.List[string]]::new()
    $manualRequired  = [System.Collections.Generic.List[string]]::new()

    $workload = $Config.workloads.collectionPolicies
    if (-not $workload -or -not $workload.PSObject.Properties['policies']) {
        Write-LabLog -Message 'No collection policies defined in config.' -Level Warning
        return @{ policies = @(); skipped = @(); manualRequired = @() }
    }

    $setCommand = Get-Command -Name Set-FeatureConfiguration -ErrorAction SilentlyContinue
    $getCommand = Get-Command -Name Get-FeatureConfiguration -ErrorAction SilentlyContinue
    if (-not $setCommand -or -not $getCommand) {
        Write-LabLog -Message 'Set-FeatureConfiguration / Get-FeatureConfiguration cmdlets are not available in this Security & Compliance PowerShell session. Collection policies must be created manually via the Purview portal Recommendations page (see docs/foundry-purview-integration.md §5.1).' -Level Warning
        foreach ($policy in @($workload.policies)) {
            $manualRequired.Add([string]$policy.name)
        }
        return @{
            policies       = @()
            skipped        = @()
            manualRequired = $manualRequired.ToArray()
        }
    }

    foreach ($policy in @($workload.policies)) {
        $policyName = [string]$policy.name
        if ([string]::IsNullOrWhiteSpace($policyName)) {
            continue
        }

        $existing = $null
        try {
            $existing = Get-FeatureConfiguration -Identity $policyName -ErrorAction SilentlyContinue
        }
        catch {
            $existing = $null
        }

        if ($existing) {
            Write-LabLog -Message "Collection policy already exists: $policyName" -Level Info
            $skippedPolicies.Add($policyName)
            continue
        }

        $scenarioConfig = [ordered]@{
            Activities          = @('UploadText', 'DownloadText')
            EnforcementPlanes   = @('Entra')
            SensitiveTypeIds    = @('All')
            IsIngestionEnabled  = $false
        }
        $scenarioJson = $scenarioConfig | ConvertTo-Json -Compress

        if ($PSCmdlet.ShouldProcess($policyName, 'Create collection policy (Set-FeatureConfiguration)')) {
            try {
                Invoke-LabRetry -MaxAttempts 3 -DelaySeconds 5 -OperationName "create collection policy '$policyName'" -ScriptBlock {
                    Set-FeatureConfiguration -Identity $policyName -ScenarioConfig $scenarioJson -ErrorAction Stop | Out-Null
                }
                Write-LabLog -Message "Created collection policy: $policyName" -Level Success
                $createdPolicies.Add($policyName)
            }
            catch {
                Write-LabLog -Message "Failed to create collection policy '$policyName': $($_.Exception.Message). This policy can be enabled manually from the Purview DSPM for AI Recommendations page." -Level Warning
                $manualRequired.Add($policyName)
            }
        }
    }

    return @{
        policies       = $createdPolicies.ToArray()
        skipped        = $skippedPolicies.ToArray()
        manualRequired = $manualRequired.ToArray()
    }
}

function Remove-CollectionPolicies {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Config,

        [Parameter()]
        [PSCustomObject]$Manifest
    )

    Write-LabStep -StepName 'CollectionPolicies' -Description 'Removing DSPM-for-AI collection policies'

    $targets = [System.Collections.Generic.List[string]]::new()

    if ($Manifest) {
        foreach ($name in @($Manifest.policies)) {
            if (-not [string]::IsNullOrWhiteSpace([string]$name)) {
                $targets.Add([string]$name)
            }
        }
    }

    if ($targets.Count -eq 0 -and $Config.workloads.PSObject.Properties['collectionPolicies']) {
        foreach ($policy in @($Config.workloads.collectionPolicies.policies)) {
            if ($policy -and -not [string]::IsNullOrWhiteSpace([string]$policy.name)) {
                $targets.Add([string]$policy.name)
            }
        }
    }

    $removeCommand = Get-Command -Name Remove-FeatureConfiguration -ErrorAction SilentlyContinue
    if (-not $removeCommand) {
        Write-LabLog -Message 'Remove-FeatureConfiguration cmdlet is not available. Collection policies must be removed manually via the Purview portal.' -Level Warning
        return
    }

    foreach ($policyName in ($targets | Sort-Object -Unique)) {
        if ($PSCmdlet.ShouldProcess($policyName, 'Remove collection policy')) {
            try {
                Remove-FeatureConfiguration -Identity $policyName -Confirm:$false -ErrorAction Stop | Out-Null
                Write-LabLog -Message "Removed collection policy: $policyName" -Level Success
            }
            catch {
                Write-LabLog -Message "Collection policy '$policyName' not found or already removed: $($_.Exception.Message)" -Level Warning
            }
        }
    }
}

Export-ModuleMember -Function @(
    'Deploy-CollectionPolicies'
    'Remove-CollectionPolicies'
)
