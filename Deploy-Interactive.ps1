#!/usr/bin/env pwsh
#Requires -Version 7.0

<#
.SYNOPSIS
    Interactive deployment entrypoint for ai-agent-security.

.DESCRIPTION
    Prompts for deployment mode, cloud environment, and tenant ID, then invokes Deploy.ps1.

.PARAMETER WhatIf
    Passes WhatIf to Deploy.ps1.

.PARAMETER SkipAuth
    Passes SkipAuth to Deploy.ps1.
#>

[CmdletBinding()]
param(
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

$deployScriptPath = Join-Path $PSScriptRoot 'Deploy.ps1'
$deployParams = @{
    Cloud = $cloud
}

switch ($mode) {
    'security-only' { $deployParams['SkipFoundry'] = $true }
    'foundry-only'  { $deployParams['FoundryOnly'] = $true }
    default         { } # 'full' — no extra flags
}

if ($WhatIf) {
    $deployParams['WhatIf'] = $true
}

if ($SkipAuth) {
    $deployParams['SkipAuth'] = $true
}
else {
    $deployParams['TenantId'] = $tenantId
}

# Test users are auto-created by default
$deployParams['TestUsersMode'] = 'create'

Write-Host "Starting deploy with cloud='$cloud' mode='$mode'..."

& $deployScriptPath @deployParams
