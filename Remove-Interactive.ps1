#Requires -Version 7.0

<#
.SYNOPSIS
    Interactive teardown entrypoint for ai-agent-security.

.DESCRIPTION
    Prompts for removal mode, cloud environment, tenant ID, and optional manifest path,
    then invokes Remove.ps1.

.PARAMETER ManifestPath
    Optional manifest path. If omitted, prompts interactively. Remove.ps1 falls back to
    config/prefix-based removal when no manifest is provided.

.PARAMETER WhatIf
    Passes WhatIf to Remove.ps1.

.PARAMETER SkipAuth
    Passes SkipAuth to Remove.ps1.
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string]$ManifestPath,

    [Parameter()]
    [switch]$WhatIf,

    [Parameter()]
    [switch]$SkipAuth
)

$ErrorActionPreference = 'Stop'

# Import interactive prompting module
Import-Module (Join-Path $PSScriptRoot 'modules' 'Interactive.psm1') -Force

# Deployment mode selection
$mode = Request-DeploymentMode

# Cloud selection
$cloud = Request-LabCloud

# Tenant ID
$tenantId = $null
if (-not $SkipAuth) {
    $tenantId = Request-LabTenantId
}

# Manifest (optional)
if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $defaultManifestDir = Join-Path $PSScriptRoot 'manifests'
    $manifestInput = Read-Host "Manifest path (optional, blank uses config/prefix fallback) [suggested dir: $defaultManifestDir]"
    if (-not [string]::IsNullOrWhiteSpace($manifestInput)) {
        $ManifestPath = $manifestInput.Trim()
    }
}

if (-not [string]::IsNullOrWhiteSpace($ManifestPath) -and -not (Test-Path -Path $ManifestPath -PathType Leaf)) {
    throw "Manifest file not found: $ManifestPath"
}

$removeScriptPath = Join-Path $PSScriptRoot 'Remove.ps1'
$removeParams = @{
    Cloud = $cloud
}

switch ($mode) {
    'security-only' { $removeParams['SkipFoundry'] = $true }
    'foundry-only'  { $removeParams['FoundryOnly'] = $true }
    default         { } # 'full' — no extra flags
}

if ($WhatIf) {
    $removeParams['WhatIf'] = $true
}

if ($SkipAuth) {
    $removeParams['SkipAuth'] = $true
}
else {
    $removeParams['TenantId'] = $tenantId
}

if (-not [string]::IsNullOrWhiteSpace($ManifestPath)) {
    $removeParams['ManifestPath'] = $ManifestPath
}

Write-Host "Starting remove with cloud='$cloud' mode='$mode'..."

& $removeScriptPath @removeParams
