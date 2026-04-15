<#
.SYNOPSIS
    Connects to Microsoft Graph using an Azure Managed Identity.

.DESCRIPTION
    Authenticates to Microsoft Graph via the Managed Identity available on the Azure compute
    resource (VM, Function App, Container App, App Service, etc.). Returns the Graph context
    object on success.

    Can be dot-sourced to make the connection available in the calling scope, or executed
    directly as a validation step.

.PARAMETER Scopes
    Optional scopes to request. Managed Identity authentication typically ignores scopes
    (permissions are granted via app role assignments), but this parameter is accepted for
    compatibility with interactive workflows.

.PARAMETER ClientId
    Optional client ID of a user-assigned Managed Identity. Omit for system-assigned identity.

.EXAMPLE
    .\Connect-GraphWithManagedIdentity.ps1

.EXAMPLE
    . .\Connect-GraphWithManagedIdentity.ps1 -ClientId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"

.EXAMPLE
    $ctx = .\Connect-GraphWithManagedIdentity.ps1
    $ctx.Account

.NOTES
    This script must run on an Azure resource with an assigned Managed Identity.
    For local development, use Connect-MgGraph -Scopes ... interactively instead.
#>

#Requires -Modules Microsoft.Graph.Authentication

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string[]]$Scopes,

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$ClientId
)

$ErrorActionPreference = 'Stop'

$connectParams = @{ Identity = $true }

if ($ClientId) {
    $connectParams['ClientId'] = $ClientId
}

if ($Scopes) {
    $connectParams['Scopes'] = $Scopes
}

try {
    Write-Host "Connecting to Microsoft Graph via Managed Identity..." -ForegroundColor Cyan
    Connect-MgGraph @connectParams
}
catch {
    throw "Failed to connect to Microsoft Graph with Managed Identity. Ensure this script is running on an Azure resource with an assigned identity. Error: $_"
}

$context = Get-MgContext
if (-not $context) {
    throw "Connect-MgGraph succeeded but Get-MgContext returned null. This is unexpected — check module versions."
}

Write-Host "Connected to Microsoft Graph" -ForegroundColor Green
Write-Host "  Account:     $($context.Account)" -ForegroundColor Gray
Write-Host "  Tenant:      $($context.TenantId)" -ForegroundColor Gray
Write-Host "  Auth Type:   $($context.AuthType)" -ForegroundColor Gray
Write-Host "  Environment: $($context.Environment)" -ForegroundColor Gray

return $context
