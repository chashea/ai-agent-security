#Requires -Version 7.0

<#
.SYNOPSIS
    Shared interactive prompting functions for ai-agent-security.
#>

function Request-LabCloud {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()]
        [string]$DefaultCloud
    )

    if ([string]::IsNullOrWhiteSpace($DefaultCloud)) {
        $DefaultCloud = if ([string]::IsNullOrWhiteSpace($env:PURVIEW_CLOUD)) { 'commercial' } else { $env:PURVIEW_CLOUD.ToLowerInvariant() }
    }

    $allowedClouds = @('commercial', 'gcc')

    do {
        $cloudInput = Read-Host "Purview cloud [commercial/gcc] (default: $DefaultCloud)"
        if ([string]::IsNullOrWhiteSpace($cloudInput)) {
            $cloud = $DefaultCloud
        }
        else {
            $cloud = $cloudInput.Trim().ToLowerInvariant()
        }

        if ($allowedClouds -notcontains $cloud) {
            Write-Warning "Invalid cloud '$cloud'. Enter 'commercial' or 'gcc'."
            $cloud = $null
        }
    } while (-not $cloud)

    return $cloud
}

function Request-LabTenantId {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $tenantId = $null
    do {
        $defaultTenant = $env:PURVIEW_TENANT_ID
        $tenantPrompt = if ([string]::IsNullOrWhiteSpace($defaultTenant)) {
            'Tenant ID (GUID)'
        }
        else {
            "Tenant ID (GUID) (default: $defaultTenant)"
        }

        $tenantInput = Read-Host $tenantPrompt
        if ([string]::IsNullOrWhiteSpace($tenantInput)) {
            $tenantId = $defaultTenant
        }
        else {
            $tenantId = $tenantInput.Trim()
        }

        if ([string]::IsNullOrWhiteSpace($tenantId)) {
            Write-Warning 'Tenant ID is required unless -SkipAuth is used.'
        }
    } while ([string]::IsNullOrWhiteSpace($tenantId))

    return $tenantId
}

function Request-DeploymentMode {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $modes = @(
        @{ Number = 1; Name = 'full';          Description = 'Full (Foundry + Security controls)' }
        @{ Number = 2; Name = 'security-only'; Description = 'Security only (skip Foundry deployment)' }
        @{ Number = 3; Name = 'foundry-only';  Description = 'Foundry only (skip Purview security workloads)' }
    )

    Write-Host ''
    Write-Host 'Deployment mode:'
    foreach ($m in $modes) {
        Write-Host "  [$($m.Number)] $($m.Description)"
    }
    Write-Host ''

    $selectedMode = $null
    do {
        $modeInput = Read-Host 'Select mode [1/2/3] (default: 1)'
        if ([string]::IsNullOrWhiteSpace($modeInput)) {
            $selectedMode = 'full'
        }
        else {
            $match = $modes | Where-Object { $_.Number -eq [int]$modeInput -or $_.Name -eq $modeInput.Trim() }
            if ($match) {
                $selectedMode = $match.Name
            }
            else {
                Write-Warning "Invalid selection '$modeInput'. Enter 1, 2, or 3."
                $selectedMode = $null
            }
        }
    } while (-not $selectedMode)

    return $selectedMode
}

Export-ModuleMember -Function @(
    'Request-LabCloud'
    'Request-LabTenantId'
    'Request-DeploymentMode'
)
