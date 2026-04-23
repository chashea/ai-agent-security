#!/usr/bin/env pwsh
<#
.SYNOPSIS Pull recent Defender XDR alerts + incidents via Microsoft Graph.
.PARAMETER SinceMinutes  Lookback window (default 120).
.PARAMETER Top           Max per resource (default 50).
.PARAMETER Output        Optional JSON output path.
.PARAMETER TenantId      Target Entra tenant. Defaults to $env:AZURE_TENANT_ID;
                         if neither is set, falls back to the current Graph
                         context or prompts interactively.
#>
param(
    [int]$SinceMinutes = 120,
    [int]$Top = 50,
    [string]$Output,
    [string]$TenantId = $env:AZURE_TENANT_ID
)

$ErrorActionPreference = 'Stop'
Import-Module Microsoft.Graph.Security -ErrorAction Stop

$scopes = @('SecurityAlert.Read.All', 'SecurityIncident.Read.All')
$ctx = Get-MgContext -ErrorAction SilentlyContinue
$missing = $scopes | Where-Object { -not $ctx -or $_ -notin $ctx.Scopes }
if ($missing) {
    Write-Host "Connecting to Graph (device code)..." -ForegroundColor Cyan
    $connectArgs = @{ Scopes = $scopes; NoWelcome = $true }
    if ($TenantId) { $connectArgs.TenantId = $TenantId }
    Connect-MgGraph @connectArgs
}

$since = (Get-Date).ToUniversalTime().AddMinutes(-$SinceMinutes).ToString('yyyy-MM-ddTHH:mm:ssZ')
Write-Host "Window: since $since ($SinceMinutes minutes)`n" -ForegroundColor Cyan

$filter = "createdDateTime ge $since"

$alerts = Get-MgSecurityAlertV2 -Filter $filter -Top $Top -ErrorAction Continue
$incidents = Get-MgSecurityIncident -Filter $filter -Top $Top -ErrorAction Continue

Write-Host ("alerts:    {0}" -f ($alerts | Measure-Object).Count) -ForegroundColor Green
Write-Host ("incidents: {0}`n" -f ($incidents | Measure-Object).Count) -ForegroundColor Green

Write-Host "alerts by serviceSource:" -ForegroundColor Yellow
$alerts | Group-Object ServiceSource | Sort-Object Count -Descending |
    ForEach-Object { "  {0,-30} {1}" -f $_.Name, $_.Count } | Write-Host

Write-Host "`nalerts by severity:" -ForegroundColor Yellow
$alerts | Group-Object Severity |
    ForEach-Object { "  {0,-12} {1}" -f $_.Name, $_.Count } | Write-Host

Write-Host "`nTop 20 alerts (most recent):" -ForegroundColor Yellow
$alerts | Sort-Object CreatedDateTime -Descending | Select-Object -First 20 |
    ForEach-Object { "  [{0,-8}] {1,-28} {2}  {3}" -f $_.Severity, $_.ServiceSource, $_.CreatedDateTime, ($_.Title -replace "`n", ' ') } |
    Write-Host

Write-Host "`nTop 10 incidents:" -ForegroundColor Yellow
$incidents | Sort-Object CreatedDateTime -Descending | Select-Object -First 10 |
    ForEach-Object { "  [{0,-8}] {1,-12} {2}  {3}" -f $_.Severity, $_.Status, $_.CreatedDateTime, ($_.DisplayName -replace "`n", ' ') } |
    Write-Host

if ($Output) {
    @{
        generatedAt = (Get-Date).ToUniversalTime().ToString('o')
        since       = $since
        alerts      = $alerts
        incidents   = $incidents
    } | ConvertTo-Json -Depth 20 | Set-Content -Path $Output
    Write-Host "`nfull dump -> $Output" -ForegroundColor Cyan
}
