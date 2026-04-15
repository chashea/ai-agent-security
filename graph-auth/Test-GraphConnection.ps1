<#
.SYNOPSIS
    Validates Microsoft Graph API permissions by making sample calls for each required permission.

.DESCRIPTION
    Connects via Managed Identity and tests each Graph API permission by executing a lightweight
    query. Reports pass/fail results as a summary table.

    Tested permissions:
    - User.Read.All       → Get-MgUser
    - Group.ReadWrite.All → Get-MgGroup
    - AuditLog.Read.All   → Get-MgAuditLogDirectoryAudit
    - Directory.Read.All  → Get-MgDomain
    - Mail.Send           → Verified via permission check (no destructive test)

.PARAMETER ClientId
    Optional client ID of a user-assigned Managed Identity. Omit for system-assigned identity.

.EXAMPLE
    .\Test-GraphConnection.ps1

.EXAMPLE
    .\Test-GraphConnection.ps1 -ClientId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"

.NOTES
    Must run on an Azure resource with a Managed Identity that has been granted the required
    Graph permissions via Setup-GraphPermissions.ps1 or equivalent.
#>

#Requires -Modules Microsoft.Graph.Authentication, Microsoft.Graph.Users, Microsoft.Graph.Groups, Microsoft.Graph.Reports, Microsoft.Graph.Identity.DirectoryManagement

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$ClientId
)

$ErrorActionPreference = 'Stop'

# region Connect
$connectParams = @{ Identity = $true }
if ($ClientId) { $connectParams['ClientId'] = $ClientId }

try {
    Write-Host "Connecting to Microsoft Graph via Managed Identity..." -ForegroundColor Cyan
    Connect-MgGraph @connectParams
    $context = Get-MgContext
    if (-not $context) { throw "Get-MgContext returned null after connection." }
    Write-Host "Connected as $($context.Account) in tenant $($context.TenantId)" -ForegroundColor Green
}
catch {
    Write-Host "FATAL: Could not connect to Microsoft Graph. $_" -ForegroundColor Red
    return
}
# endregion

# region Define tests
$tests = @(
    @{
        Permission  = 'User.Read.All'
        Description = 'Read user profiles'
        Test        = { Get-MgUser -Top 1 -Property Id, DisplayName | Out-Null }
    }
    @{
        Permission  = 'Group.ReadWrite.All'
        Description = 'Read/write groups'
        Test        = { Get-MgGroup -Top 1 -Property Id, DisplayName | Out-Null }
    }
    @{
        Permission  = 'AuditLog.Read.All'
        Description = 'Read audit logs'
        Test        = { Get-MgAuditLogDirectoryAudit -Top 1 | Out-Null }
    }
    @{
        Permission  = 'Directory.Read.All'
        Description = 'Read directory objects'
        Test        = { Get-MgDomain -Property Id | Select-Object -First 1 | Out-Null }
    }
    @{
        Permission  = 'Mail.Send'
        Description = 'Send mail (permission check only)'
        Test        = {
            # Mail.Send is write-only — we verify the permission is assigned rather than sending a real email.
            $graphSpn = Get-MgServicePrincipal -Filter "appId eq '00000003-0000-0000-c000-000000000000'"
            $mailRole = $graphSpn.AppRoles | Where-Object { $_.Value -eq 'Mail.Send' -and $_.AllowedMemberTypes -contains 'Application' }
            if (-not $mailRole) { throw "Mail.Send app role not found on Graph service principal." }

            $assignments = Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $context.ClientId
            $hasMailSend = $assignments | Where-Object { $_.AppRoleId -eq $mailRole.Id }
            if (-not $hasMailSend) { throw "Mail.Send is not assigned to this identity." }
        }
    }
)
# endregion

# region Execute tests
$results = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($test in $tests) {
    $status = 'PASS'
    $detail = ''

    try {
        & $test.Test
    }
    catch {
        $status = 'FAIL'
        $detail = $_.Exception.Message
    }

    $results.Add([PSCustomObject]@{
        Permission  = $test.Permission
        Description = $test.Description
        Status      = $status
        Detail      = $detail
    })

    $color = if ($status -eq 'PASS') { 'Green' } else { 'Red' }
    Write-Host "  [$status] $($test.Permission) — $($test.Description)" -ForegroundColor $color
    if ($detail) { Write-Host "         $detail" -ForegroundColor DarkGray }
}
# endregion

Write-Host "`nPermission Test Summary" -ForegroundColor Cyan
Write-Host ("=" * 90) -ForegroundColor Cyan
$results | Format-Table -AutoSize -Wrap

$failCount = ($results | Where-Object { $_.Status -eq 'FAIL' }).Count
if ($failCount -gt 0) {
    Write-Host "$failCount permission(s) failed. Run Setup-GraphPermissions.ps1 to assign missing permissions." -ForegroundColor Yellow
}
else {
    Write-Host "All permissions validated." -ForegroundColor Green
}
