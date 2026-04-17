#Requires -Version 7.0

<#
.SYNOPSIS
    Removes ONLY the TestUsers (groups) and SensitivityLabels workloads created by this lab.
    Leaves MDCA, ConditionalAccess, AgentIdentity, and Foundry resources untouched.

.DESCRIPTION
    Invokes Remove-TestUsers and Remove-SensitivityLabels directly against the latest
    deployment manifest. In testUsers mode=existing, Remove-TestUsers only deletes the
    three AISec-* groups (not the real user account).
#>

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter()]
    [string]$ConfigPath = (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'config.json'),

    [Parameter()]
    [string]$ManifestPath,

    [Parameter()]
    [string]$TenantId = $env:PURVIEW_TENANT_ID,

    [Parameter()]
    [ValidateSet('commercial', 'gcc')]
    [string]$Cloud = 'commercial'
)

$ErrorActionPreference = 'Stop'
$repoRoot = Resolve-Path -Path (Join-Path -Path $PSScriptRoot -ChildPath '..')

Import-Module (Join-Path $repoRoot 'modules' 'Prerequisites.psm1') -Force
foreach ($mod in (Get-ChildItem -Path (Join-Path $repoRoot 'modules') -Filter '*.psm1')) {
    Import-Module $mod.FullName -Force
}

try {
    Initialize-LabLogging -Prefix 'AIAgentSec-Partial'
    Write-LabLog -Message 'Targeted removal started: TestUsers + SensitivityLabels only.' -Level Info

    $Config = Import-LabConfig -ConfigPath $ConfigPath
    $null = Resolve-LabCloud -Cloud $Cloud -Config $Config
    Write-LabLog -Message "Lab: $($Config.labName) | Prefix: $($Config.prefix) | Domain: $($Config.domain)" -Level Info

    if (-not $ManifestPath) {
        $manifestDir = Join-Path $repoRoot 'manifests'
        $latest = Get-ChildItem -Path $manifestDir -Filter '*.json' | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if (-not $latest) { throw "No manifest found in $manifestDir" }
        $ManifestPath = $latest.FullName
    }
    Write-LabLog -Message "Using manifest: $ManifestPath" -Level Info
    $Manifest = Import-LabManifest -ManifestPath $ManifestPath

    if ([string]::IsNullOrWhiteSpace($TenantId)) {
        throw 'TenantId is required. Use -TenantId or set PURVIEW_TENANT_ID.'
    }

    Write-LabStep -StepName 'Auth' -Description 'Connecting to Exchange Online + Microsoft Graph'
    Connect-LabServices -TenantId $TenantId -SkipExchange:$false -SkipGraph:$false -ConnectAzure:$false
    Write-LabLog -Message 'Connected to Exchange Online + Microsoft Graph.' -Level Success

    $resolvedDomain = Resolve-LabTenantDomain -ConfiguredDomain $Config.domain
    if (-not [string]::Equals($resolvedDomain, [string]$Config.domain, [System.StringComparison]::OrdinalIgnoreCase)) {
        Write-LabLog -Message "Using resolved domain '$resolvedDomain' for lookups." -Level Warning
        $Config.domain = $resolvedDomain
    }

    $labelsManifest = $null
    if ($Manifest -and $Manifest.data -and $Manifest.data.PSObject.Properties['sensitivityLabels']) {
        $labelsManifest = $Manifest.data.sensitivityLabels
    }
    if ($labelsManifest -and (($labelsManifest.labels | Measure-Object).Count -gt 0)) {
        Write-LabStep -StepName 'SensitivityLabels' -Description 'Removing sensitivity labels + publication policy'
        try {
            Remove-SensitivityLabels -Config $Config -Manifest $labelsManifest -WhatIf:$WhatIfPreference
            Write-LabLog -Message 'Sensitivity Labels removal complete.' -Level Success
        }
        catch {
            Write-LabLog -Message "SensitivityLabels removal FAILED: $($_.Exception.Message)" -Level Error
        }
    }
    else {
        Write-LabLog -Message 'No sensitivity labels found in manifest, skipping.' -Level Info
    }

    $usersManifest = $null
    if ($Manifest -and $Manifest.data -and $Manifest.data.PSObject.Properties['testUsers']) {
        $usersManifest = $Manifest.data.testUsers
    }
    Write-LabStep -StepName 'TestUsers' -Description 'Removing test user groups (existing mode preserves real accounts)'
    try {
        Remove-TestUsers -Config $Config -Manifest $usersManifest -WhatIf:$WhatIfPreference
        Write-LabLog -Message 'Test Users removal complete.' -Level Success
    }
    catch {
        Write-LabLog -Message "TestUsers removal FAILED: $($_.Exception.Message)" -Level Error
    }

    Write-LabStep -StepName 'Summary' -Description 'Targeted teardown complete'
    Write-LabLog -Message 'Targeted removal finished.' -Level Success
}
catch {
    Write-LabLog -Message "Targeted removal failed: $_" -Level Error
    Write-LabLog -Message $_.ScriptStackTrace -Level Error
    throw
}
finally {
    try { Disconnect-LabServices } catch { Write-Verbose "Disconnect error: $_" }
    Complete-LabLogging
}
