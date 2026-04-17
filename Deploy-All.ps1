#Requires -Version 7.0

<#
.SYNOPSIS
    One-shot orchestrator that deploys the full ai-agent-security lab and the
    subscription-scope Foundry guardrail policy initiative in a single run.

.DESCRIPTION
    Wraps two deployments so a consolidated eastus2 rebuild can be kicked off
    with a single command:

      1. Deploy.ps1  - Foundry account/project, 7 agents, AI Search, bot
         services, Defender posture, Conditional Access, test users, Teams
         apps (standard main-lab flow).

      2. infra/foundry-guardrail-policies.bicep - 8 Foundry Control Plane
         guardrail policy definitions + initiative + subscription-scope
         assignment (Audit mode by default).

    The guardrail initiative is region-agnostic and subscription-scoped, so it
    is (re)applied idempotently; re-running against an existing assignment
    updates it in place.

    Execution order:
      - Guardrails first when -GuardrailsFirst is passed (useful if you want
        Audit findings to fire immediately as agent resources are created).
      - Otherwise lab first, guardrails second (default).

.PARAMETER ConfigPath
    Path to the lab config JSON. Defaults to config.json in the repo root.

.PARAMETER TenantId
    Microsoft Entra tenant ID. Required unless -SkipAuth is passed.

.PARAMETER SubscriptionId
    Azure subscription for the guardrail assignment. Defaults to the
    subscriptionId value from ConfigPath.

.PARAMETER GuardrailEffect
    Effect parameter passed to the initiative assignment. Audit (default),
    Deny, or Disabled.

.PARAMETER SkipLab
    Skip Deploy.ps1. Only deploy guardrails.

.PARAMETER SkipGuardrails
    Skip the guardrail Bicep deploy. Only deploy the lab.

.PARAMETER GuardrailsFirst
    Run the guardrail initiative deployment before Deploy.ps1.

.PARAMETER Cloud
    Passed through to Deploy.ps1 ('commercial' or 'gcc').

.PARAMETER SkipAuth
    Passed through to Deploy.ps1. Skips Graph/Exchange/Az connect.

.PARAMETER TestUsersMode
    Passed through to Deploy.ps1 ('create' or 'existing').

.PARAMETER WhatIf
    Dry-run both phases. Deploy.ps1 gets -WhatIf; the Bicep deploy uses
    'az deployment sub what-if'.

.EXAMPLE
    ./Deploy-All.ps1 -TenantId 'f1b92d41-6d54-4102-9dd9-4208451314df'

.EXAMPLE
    ./Deploy-All.ps1 -TenantId '<tid>' -GuardrailEffect Deny -GuardrailsFirst

.EXAMPLE
    ./Deploy-All.ps1 -TenantId '<tid>' -WhatIf

.EXAMPLE
    ./Deploy-All.ps1 -SkipLab   # refresh just the policy initiative

.NOTES
    Requires: pwsh 7+, az CLI logged in (az login), bicep CLI
    (auto-installed by az on first run). Connect-MgGraph / Connect-ExchangeOnline
    prompts are driven by Deploy.ps1 when -SkipAuth is not set.
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter()]
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config.json'),

    [Parameter()]
    [string]$TenantId = $env:PURVIEW_TENANT_ID,

    [Parameter()]
    [string]$SubscriptionId,

    [Parameter()]
    [ValidateSet('Audit', 'Deny', 'Disabled')]
    [string]$GuardrailEffect = 'Audit',

    [Parameter()]
    [switch]$SkipLab,

    [Parameter()]
    [switch]$SkipGuardrails,

    [Parameter()]
    [switch]$GuardrailsFirst,

    [Parameter()]
    [ValidateSet('commercial', 'gcc')]
    [string]$Cloud,

    [Parameter()]
    [switch]$SkipAuth,

    [Parameter()]
    [ValidateSet('create', 'existing')]
    [string]$TestUsersMode
)

$ErrorActionPreference = 'Stop'

function Write-Phase {
    param([string]$Message)
    Write-Host ''
    Write-Host ('=' * 72) -ForegroundColor Cyan
    Write-Host "  $Message" -ForegroundColor Cyan
    Write-Host ('=' * 72) -ForegroundColor Cyan
}

function Invoke-LabDeploy {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [string]$ConfigPath,
        [string]$TenantId,
        [string]$Cloud,
        [switch]$SkipAuth,
        [string]$TestUsersMode,
        [bool]$WhatIfRequested
    )

    Write-Phase 'Phase: Main lab (Deploy.ps1)'

    $deployScript = Join-Path -Path $PSScriptRoot -ChildPath 'Deploy.ps1'
    if (-not (Test-Path $deployScript)) {
        throw "Deploy.ps1 not found at $deployScript"
    }

    $params = @{
        ConfigPath = $ConfigPath
    }
    if ($TestUsersMode)   { $params['TestUsersMode'] = $TestUsersMode }
    if ($Cloud)           { $params['Cloud']    = $Cloud }
    if ($SkipAuth)        { $params['SkipAuth'] = $true }
    else                  { $params['TenantId'] = $TenantId }
    if ($WhatIfRequested) { $params['WhatIf']   = $true }

    if ($PSCmdlet.ShouldProcess('Deploy.ps1', 'Invoke main lab deployment')) {
        & $deployScript @params
        if ($LASTEXITCODE -ne 0 -and $null -ne $LASTEXITCODE) {
            throw "Deploy.ps1 exited with code $LASTEXITCODE"
        }
    }
}

function Invoke-GuardrailDeploy {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [string]$ConfigPath,
        [string]$SubscriptionId,
        [string]$GuardrailEffect,
        [bool]$WhatIfRequested
    )

    Write-Phase 'Phase: Foundry guardrail initiative (subscription scope)'

    $bicepPath = Join-Path -Path $PSScriptRoot -ChildPath 'infra' -AdditionalChildPath 'foundry-guardrail-policies.bicep'
    if (-not (Test-Path $bicepPath)) {
        throw "Guardrail Bicep not found at $bicepPath"
    }

    if (-not $SubscriptionId) {
        if (-not (Test-Path $ConfigPath)) {
            throw "ConfigPath not found and SubscriptionId not supplied: $ConfigPath"
        }
        $cfg = Get-Content -Raw -Path $ConfigPath | ConvertFrom-Json
        $SubscriptionId = $cfg.workloads.foundry.subscriptionId
        if (-not $SubscriptionId -and $cfg.core) {
            $SubscriptionId = $cfg.core.subscriptionId
        }
        if (-not $SubscriptionId) {
            throw 'Could not derive SubscriptionId from config.json (workloads.foundry.subscriptionId missing). Pass -SubscriptionId explicitly.'
        }
    }

    Write-Host "Subscription : $SubscriptionId"
    Write-Host "Effect       : $GuardrailEffect"
    Write-Host "Bicep        : $bicepPath"

    $location = 'eastus2'
    if (Test-Path $ConfigPath) {
        try {
            $cfgLoc = (Get-Content -Raw -Path $ConfigPath | ConvertFrom-Json).workloads.foundry.location
            if ($cfgLoc) { $location = $cfgLoc }
        } catch {
            Write-Verbose "Could not read location from config; defaulting to $location. $_"
        }
    }

    $deploymentName = "aisec-guardrails-$(Get-Date -Format 'yyyyMMddHHmmss')"

    $azArgs = @('deployment', 'sub')
    if ($WhatIfRequested) {
        $azArgs += 'what-if'
    } else {
        $azArgs += 'create'
        $azArgs += @('--name', $deploymentName)
    }
    $azArgs += @(
        '--location',      $location
        '--subscription',  $SubscriptionId
        '--template-file', $bicepPath
        '--parameters',    "defaultEffect=$GuardrailEffect"
    )

    if ($PSCmdlet.ShouldProcess("subscription $SubscriptionId", 'Deploy guardrail initiative')) {
        Write-Host "Running: az $($azArgs -join ' ')"
        & az @azArgs
        if ($LASTEXITCODE -ne 0) {
            throw "az deployment sub exited with code $LASTEXITCODE"
        }
    }
}

if (-not $SkipAuth -and -not $SkipLab -and -not $TenantId) {
    throw 'TenantId is required unless -SkipAuth or -SkipLab is specified. Set $env:PURVIEW_TENANT_ID or pass -TenantId.'
}

Write-Phase 'Deploy-All starting'
Write-Host "ConfigPath     : $ConfigPath"
Write-Host "SkipLab        : $SkipLab"
Write-Host "SkipGuardrails : $SkipGuardrails"
Write-Host "GuardrailsFirst: $GuardrailsFirst"
Write-Host "WhatIf         : $([bool]$WhatIfPreference)"

$phases = @()
if ($GuardrailsFirst) {
    if (-not $SkipGuardrails) { $phases += 'guardrails' }
    if (-not $SkipLab)        { $phases += 'lab' }
} else {
    if (-not $SkipLab)        { $phases += 'lab' }
    if (-not $SkipGuardrails) { $phases += 'guardrails' }
}

if ($phases.Count -eq 0) {
    Write-Warning 'Both -SkipLab and -SkipGuardrails were specified. Nothing to do.'
    return
}

foreach ($phase in $phases) {
    switch ($phase) {
        'lab' {
            Invoke-LabDeploy `
                -ConfigPath $ConfigPath `
                -TenantId $TenantId `
                -Cloud $Cloud `
                -SkipAuth:$SkipAuth `
                -TestUsersMode $TestUsersMode `
                -WhatIfRequested ([bool]$WhatIfPreference)
        }
        'guardrails' {
            Invoke-GuardrailDeploy `
                -ConfigPath $ConfigPath `
                -SubscriptionId $SubscriptionId `
                -GuardrailEffect $GuardrailEffect `
                -WhatIfRequested ([bool]$WhatIfPreference)
        }
    }
}

Write-Phase 'Deploy-All complete'
Write-Host "Next steps:"
Write-Host "  - Verify Foundry account region: az cognitiveservices account show -n aisec-foundry -g rg-ai-agent-security --query location -o tsv"
Write-Host "  - Run attack harness:            python3.12 scripts/attack_agents.py --list"
Write-Host "  - Check Compliance blade:        https://ai.azure.com/ -> Compliance (filter: All projects)"
