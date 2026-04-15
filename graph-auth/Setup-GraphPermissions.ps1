<#
.SYNOPSIS
    Assigns Microsoft Graph API application permissions to an Azure Managed Identity.

.DESCRIPTION
    Connects to Microsoft Graph as an admin and grants the specified application permissions
    to a Managed Identity (system-assigned or user-assigned). This is required before the
    identity can call Graph API endpoints.

    Permissions assigned:
    - User.Read.All
    - Mail.Send
    - Group.ReadWrite.All
    - AuditLog.Read.All
    - Directory.Read.All

.PARAMETER ManagedIdentityObjectId
    The Object (principal) ID of the Managed Identity in Entra ID.

.PARAMETER TenantId
    The Entra ID tenant ID. Defaults to the tenant from the current Azure context.

.EXAMPLE
    .\Setup-GraphPermissions.ps1 -ManagedIdentityObjectId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"

.EXAMPLE
    .\Setup-GraphPermissions.ps1 -ManagedIdentityObjectId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" -TenantId "yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy" -WhatIf

.NOTES
    Requires Global Administrator or Privileged Role Administrator to grant application permissions.
    Run Connect-MgGraph -Scopes "AppRoleAssignment.ReadWrite.All","Application.Read.All" before executing,
    or this script will attempt the connection for you.
#>

#Requires -Modules Microsoft.Graph.Authentication, Microsoft.Graph.Applications

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$ManagedIdentityObjectId,

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$TenantId
)

$ErrorActionPreference = 'Stop'

$requiredPermissions = @(
    'User.Read.All'
    'Mail.Send'
    'Group.ReadWrite.All'
    'AuditLog.Read.All'
    'Directory.Read.All'
)

$requiredScopes = @('AppRoleAssignment.ReadWrite.All', 'Application.Read.All')

# region Connection
$context = Get-MgContext
if (-not $context) {
    Write-Host "No active Microsoft Graph session. Connecting..." -ForegroundColor Yellow
    $connectParams = @{ Scopes = $requiredScopes }
    if ($TenantId) { $connectParams['TenantId'] = $TenantId }
    Connect-MgGraph @connectParams
    $context = Get-MgContext
}

$missingScopes = $requiredScopes | Where-Object { $_ -notin $context.Scopes }
if ($missingScopes) {
    Write-Host "Current session is missing scopes: $($missingScopes -join ', '). Reconnecting..." -ForegroundColor Yellow
    $connectParams = @{ Scopes = $requiredScopes }
    if ($TenantId) { $connectParams['TenantId'] = $TenantId }
    Connect-MgGraph @connectParams
}
# endregion

# region Resolve Microsoft Graph service principal
Write-Host "Resolving Microsoft Graph service principal..." -ForegroundColor Cyan
$graphSpn = Get-MgServicePrincipal -Filter "appId eq '00000003-0000-0000-c000-000000000000'"
if (-not $graphSpn) {
    throw "Could not find the Microsoft Graph service principal in tenant. Ensure Microsoft Graph is provisioned."
}
Write-Host "  Graph Service Principal ID: $($graphSpn.Id)" -ForegroundColor Gray
# endregion

# region Resolve target Managed Identity
Write-Host "Resolving Managed Identity $ManagedIdentityObjectId..." -ForegroundColor Cyan
try {
    $managedIdentitySpn = Get-MgServicePrincipal -ServicePrincipalId $ManagedIdentityObjectId
}
catch {
    throw "Could not find service principal with Object ID '$ManagedIdentityObjectId'. Verify the ID is the Enterprise Application (service principal) Object ID, not the application registration ID. Error: $_"
}
Write-Host "  Managed Identity: $($managedIdentitySpn.DisplayName) ($($managedIdentitySpn.Id))" -ForegroundColor Gray
# endregion

# region Get existing assignments
$existingAssignments = Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $ManagedIdentityObjectId
$existingRoleIds = $existingAssignments | Select-Object -ExpandProperty AppRoleId
# endregion

# region Assign permissions
$results = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($permissionName in $requiredPermissions) {
    $appRole = $graphSpn.AppRoles | Where-Object { $_.Value -eq $permissionName -and $_.AllowedMemberTypes -contains 'Application' }

    if (-not $appRole) {
        $results.Add([PSCustomObject]@{
            Permission = $permissionName
            RoleId     = 'N/A'
            Status     = 'NOT FOUND'
        })
        Write-Host "  WARNING: App role '$permissionName' not found on Microsoft Graph." -ForegroundColor Red
        continue
    }

    if ($appRole.Id -in $existingRoleIds) {
        $results.Add([PSCustomObject]@{
            Permission = $permissionName
            RoleId     = $appRole.Id
            Status     = 'ALREADY ASSIGNED'
        })
        Write-Host "  $permissionName — already assigned" -ForegroundColor Gray
        continue
    }

    if ($PSCmdlet.ShouldProcess("$($managedIdentitySpn.DisplayName)", "Assign Graph permission '$permissionName'")) {
        try {
            $body = @{
                principalId = $ManagedIdentityObjectId
                resourceId  = $graphSpn.Id
                appRoleId   = $appRole.Id
            }
            New-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $ManagedIdentityObjectId -BodyParameter $body | Out-Null

            $results.Add([PSCustomObject]@{
                Permission = $permissionName
                RoleId     = $appRole.Id
                Status     = 'ASSIGNED'
            })
            Write-Host "  $permissionName — assigned" -ForegroundColor Green
        }
        catch {
            $results.Add([PSCustomObject]@{
                Permission = $permissionName
                RoleId     = $appRole.Id
                Status     = "FAILED: $_"
            })
            Write-Host "  $permissionName — FAILED: $_" -ForegroundColor Red
        }
    }
    else {
        $results.Add([PSCustomObject]@{
            Permission = $permissionName
            RoleId     = $appRole.Id
            Status     = 'WHAT-IF'
        })
    }
}
# endregion

Write-Host "`nPermission Assignment Summary" -ForegroundColor Cyan
Write-Host ("=" * 70) -ForegroundColor Cyan
$results | Format-Table -AutoSize
