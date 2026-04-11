#Requires -Version 7.0

<#
.SYNOPSIS
    Main teardown orchestrator for ai-agent-security.

.DESCRIPTION
    Removes Azure AI Foundry agents and Microsoft Purview security workloads in reverse
    dependency order. Can use a deployment manifest for precise removal, or fall back to
    config + prefix-based removal.

.PARAMETER ConfigPath
    Path to the configuration JSON file. Defaults to config.json in the repo root.

.PARAMETER ManifestPath
    Optional path to a deployment manifest. When provided, uses manifest entries for
    precise resource removal. Otherwise falls back to config + prefix-based removal.

.PARAMETER SkipFoundry
    Skip removal of Foundry and AgentIdentity workloads.

.PARAMETER FoundryOnly
    Remove Foundry and AgentIdentity only. Skip removal of Purview security workloads.

.PARAMETER SkipAuth
    Skip connecting to Exchange Online, Microsoft Graph, and Azure (for testing).

.PARAMETER TenantId
    Microsoft Entra tenant ID. Defaults to environment variable PURVIEW_TENANT_ID.
    Required unless -SkipAuth is specified.

.PARAMETER Cloud
    Cloud environment to use (`commercial` or `gcc`). If omitted, uses config value.

.EXAMPLE
    ./Remove.ps1

.EXAMPLE
    ./Remove.ps1 -ManifestPath manifests/AIAgent_20260411-120000.json -Confirm:$false

.EXAMPLE
    ./Remove.ps1 -SkipFoundry -TenantId 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx'

.EXAMPLE
    ./Remove.ps1 -ConfigPath ./config.json -WhatIf
#>

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter()]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config.json'),

    [Parameter()]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$ManifestPath,

    [Parameter()]
    [switch]$SkipFoundry,

    [Parameter()]
    [switch]$FoundryOnly,

    [Parameter()]
    [switch]$SkipAuth,

    [Parameter()]
    [string]$TenantId = $env:PURVIEW_TENANT_ID,

    [Parameter()]
    [ValidateSet('commercial', 'gcc')]
    [string]$Cloud = 'commercial'
)

$ErrorActionPreference = 'Stop'

# Mutual exclusion guard
if ($SkipFoundry -and $FoundryOnly) {
    throw '-SkipFoundry and -FoundryOnly are mutually exclusive. Specify at most one.'
}

# Import Prerequisites early
Import-Module (Join-Path $PSScriptRoot 'modules' 'Prerequisites.psm1') -Force

# Import all modules
foreach ($mod in (Get-ChildItem -Path (Join-Path $PSScriptRoot 'modules') -Filter '*.psm1')) {
    Import-Module $mod.FullName -Force
}

try {
    # Initialize logging
    Initialize-LabLogging -Prefix 'AIAgentSec'
    Write-LabLog -Message 'Remove started.' -Level Info

    # Load configuration
    Write-LabStep -StepName 'Config' -Description 'Loading configuration'
    $Config = Import-LabConfig -ConfigPath $ConfigPath
    $resolvedCloud = Resolve-LabCloud -Cloud $Cloud -Config $Config
    Write-LabLog -Message "Lab: $($Config.labName) | Prefix: $($Config.prefix) | Domain: $($Config.domain) | Cloud: $resolvedCloud" -Level Info
    if ($SkipFoundry) {
        Write-LabLog -Message 'Mode: Security only removal (-SkipFoundry).' -Level Info
    }
    elseif ($FoundryOnly) {
        Write-LabLog -Message 'Mode: Foundry only removal (-FoundryOnly).' -Level Info
    }
    else {
        Write-LabLog -Message 'Mode: Full removal (Foundry + Security).' -Level Info
    }

    # Load manifest if provided
    $Manifest = $null
    if ($ManifestPath) {
        Write-LabLog -Message "Loading manifest from $ManifestPath" -Level Info
        $Manifest = Import-LabManifest -ManifestPath $ManifestPath
        Write-LabLog -Message 'Manifest loaded. Using manifest for precise removal.' -Level Info
    }
    else {
        $defaultManifestDir = Join-Path $PSScriptRoot 'manifests'
        Write-LabLog -Message "No manifest provided. Falling back to config + prefix-based removal. Manifest folder: $defaultManifestDir" -Level Warning
    }

    function Get-WorkloadManifest {
        param(
            [Parameter(Mandatory)]
            [string]$WorkloadName
        )

        if ($Manifest -and $Manifest.data -and $Manifest.data.PSObject.Properties[$WorkloadName]) {
            return $Manifest.data.$WorkloadName
        }

        return $null
    }

    # Determine whether Foundry is active in config
    $foundryConfigEnabled = $Config.workloads.PSObject.Properties['foundry'] -and $Config.workloads.foundry.enabled
    $removeFoundry = $foundryConfigEnabled -and -not $SkipFoundry

    # Test prerequisites
    Write-LabStep -StepName 'Prerequisites' -Description 'Validating prerequisites'
    $checkFoundryModules = $removeFoundry -and -not $SkipAuth
    if (-not (Test-LabPrerequisites -IncludeFoundry:$checkFoundryModules)) {
        Write-LabLog -Message 'Prerequisites check failed. Exiting.' -Level Error
        exit 1
    }
    Write-LabLog -Message 'All prerequisites satisfied.' -Level Success

    # Connect to services
    if (-not $SkipAuth) {
        if ([string]::IsNullOrWhiteSpace($TenantId)) {
            throw 'TenantId is required when authentication is enabled. Use -TenantId or set PURVIEW_TENANT_ID.'
        }

        Write-LabStep -StepName 'Auth' -Description 'Connecting to cloud services'
        $azureSubscriptionId = if ($removeFoundry -and $Config.workloads.foundry.PSObject.Properties['subscriptionId']) {
            [string]$Config.workloads.foundry.subscriptionId
        }
        else { $null }
        Connect-LabServices -TenantId $TenantId -ConnectAzure:$removeFoundry -AzureSubscriptionId $azureSubscriptionId
        $connectMsg = if ($removeFoundry) {
            'Connected to Exchange Online, Microsoft Graph, and Azure.'
        }
        else {
            'Connected to Exchange Online and Microsoft Graph.'
        }
        Write-LabLog -Message $connectMsg -Level Success

        $resolvedDomain = Resolve-LabTenantDomain -ConfiguredDomain $Config.domain
        if (-not [string]::Equals($resolvedDomain, [string]$Config.domain, [System.StringComparison]::OrdinalIgnoreCase)) {
            Write-LabLog -Message "Configured domain '$($Config.domain)' is not verified in this tenant. Using '$resolvedDomain' for teardown lookups." -Level Warning
            $Config.domain = $resolvedDomain
        }
    }
    else {
        Write-LabLog -Message 'Skipping authentication (-SkipAuth).' -Level Warning
    }

    # Remove workloads in reverse dependency order

    # Security workloads first (reverse of deploy: AuditConfig, ConditionalAccess, InsiderRisk, CommCompliance, EDiscovery, Retention, DLP, SensitivityLabels, TestUsers)
    if (-not $FoundryOnly) {

        if ($Config.workloads.PSObject.Properties['auditConfig'] -and $Config.workloads.auditConfig.enabled) {
            Write-LabStep -StepName 'AuditConfig' -Description 'Audit configuration removal'
            Remove-AuditConfig -Config $Config -Manifest (Get-WorkloadManifest -WorkloadName 'auditConfig') -WhatIf:$WhatIfPreference
            Write-LabLog -Message 'AuditConfig removal complete.' -Level Success
        }

        if ($Config.workloads.PSObject.Properties['mdca'] -and $Config.workloads.mdca.enabled) {
            Write-LabStep -StepName 'MDCA' -Description 'Removing Defender for Cloud Apps policies'
            Remove-MDCA -Config $Config -Manifest (Get-WorkloadManifest -WorkloadName 'mdca') -WhatIf:$WhatIfPreference
            Write-LabLog -Message 'MDCA removal complete.' -Level Success
        }

        if ($Config.workloads.PSObject.Properties['conditionalAccess'] -and $Config.workloads.conditionalAccess.enabled) {
            Write-LabStep -StepName 'ConditionalAccess' -Description 'Removing Conditional Access policies'
            Remove-ConditionalAccess -Config $Config -Manifest (Get-WorkloadManifest -WorkloadName 'conditionalAccess') -WhatIf:$WhatIfPreference
            Write-LabLog -Message 'Conditional Access removal complete.' -Level Success
        }

        if ($Config.workloads.PSObject.Properties['insiderRisk'] -and $Config.workloads.insiderRisk.enabled) {
            Write-LabStep -StepName 'InsiderRisk' -Description 'Removing insider risk management policies'
            Remove-InsiderRisk -Config $Config -Manifest (Get-WorkloadManifest -WorkloadName 'insiderRisk') -WhatIf:$WhatIfPreference
            Write-LabLog -Message 'Insider Risk removal complete.' -Level Success
        }
        else {
            Write-LabLog -Message 'insiderRisk workload is disabled, skipping.' -Level Info
        }

        if ($Config.workloads.PSObject.Properties['communicationCompliance'] -and $Config.workloads.communicationCompliance.enabled) {
            Write-LabStep -StepName 'CommunicationCompliance' -Description 'Removing communication compliance policies'
            Remove-CommunicationCompliance -Config $Config -Manifest (Get-WorkloadManifest -WorkloadName 'communicationCompliance') -WhatIf:$WhatIfPreference
            Write-LabLog -Message 'Communication Compliance removal complete.' -Level Success
        }
        else {
            Write-LabLog -Message 'communicationCompliance workload is disabled, skipping.' -Level Info
        }

        if ($Config.workloads.PSObject.Properties['eDiscovery'] -and $Config.workloads.eDiscovery.enabled) {
            Write-LabStep -StepName 'EDiscovery' -Description 'Removing eDiscovery cases'
            Remove-EDiscovery -Config $Config -Manifest (Get-WorkloadManifest -WorkloadName 'eDiscovery') -WhatIf:$WhatIfPreference
            Write-LabLog -Message 'eDiscovery removal complete.' -Level Success
        }
        else {
            Write-LabLog -Message 'eDiscovery workload is disabled, skipping.' -Level Info
        }

        if ($Config.workloads.PSObject.Properties['retention'] -and $Config.workloads.retention.enabled) {
            Write-LabStep -StepName 'Retention' -Description 'Removing retention policies and labels'
            Remove-Retention -Config $Config -Manifest (Get-WorkloadManifest -WorkloadName 'retention') -WhatIf:$WhatIfPreference
            Write-LabLog -Message 'Retention removal complete.' -Level Success
        }
        else {
            Write-LabLog -Message 'retention workload is disabled, skipping.' -Level Info
        }

        if ($Config.workloads.PSObject.Properties['dlp'] -and $Config.workloads.dlp.enabled) {
            Write-LabStep -StepName 'DLP' -Description 'Removing DLP policies'
            Remove-DLP -Config $Config -Manifest (Get-WorkloadManifest -WorkloadName 'dlp') -WhatIf:$WhatIfPreference
            Write-LabLog -Message 'DLP removal complete.' -Level Success
        }
        else {
            Write-LabLog -Message 'dlp workload is disabled, skipping.' -Level Info
        }

        if ($Config.workloads.PSObject.Properties['sensitivityLabels'] -and $Config.workloads.sensitivityLabels.enabled) {
            Write-LabStep -StepName 'SensitivityLabels' -Description 'Removing sensitivity labels'
            Remove-SensitivityLabels -Config $Config -Manifest (Get-WorkloadManifest -WorkloadName 'sensitivityLabels') -WhatIf:$WhatIfPreference
            Write-LabLog -Message 'Sensitivity Labels removal complete.' -Level Success
        }
        else {
            Write-LabLog -Message 'sensitivityLabels workload is disabled, skipping.' -Level Info
        }

        if ($Config.workloads.PSObject.Properties['testUsers'] -and $Config.workloads.testUsers.enabled) {
            Write-LabStep -StepName 'TestUsers' -Description 'Removing test users'
            Remove-TestUsers -Config $Config -Manifest (Get-WorkloadManifest -WorkloadName 'testUsers') -WhatIf:$WhatIfPreference
            Write-LabLog -Message 'Test Users removal complete.' -Level Success
        }
        else {
            Write-LabLog -Message 'testUsers workload is disabled, skipping.' -Level Info
        }

    }
    else {
        Write-LabLog -Message 'Security workload removal skipped (-FoundryOnly).' -Level Info
    }

    # Foundry removed last — reverse of deploy order (Foundry deploys first)
    if (-not $SkipFoundry) {
        if ($foundryConfigEnabled) {
            Write-LabStep -StepName 'AgentIdentity' -Description 'Removing agent managed identity and RBAC'
            Remove-AgentIdentity -Config $Config -Manifest (Get-WorkloadManifest -WorkloadName 'agentIdentity') -WhatIf:$WhatIfPreference
            Write-LabLog -Message 'AgentIdentity removal complete.' -Level Success

            Write-LabStep -StepName 'Foundry' -Description 'Removing Azure AI Foundry agents, project, and account'
            Remove-Foundry -Config $Config -Manifest (Get-WorkloadManifest -WorkloadName 'foundry') -WhatIf:$WhatIfPreference
            Write-LabLog -Message 'Foundry removal complete.' -Level Success
        }
        else {
            Write-LabLog -Message 'foundry workload is disabled in config, skipping.' -Level Info
        }
    }
    else {
        Write-LabLog -Message 'Foundry and AgentIdentity removal skipped (-SkipFoundry).' -Level Info
    }

    # Summary
    Write-LabStep -StepName 'Summary' -Description 'Teardown complete'
    Write-LabLog -Message 'Remove finished successfully.' -Level Success
}
catch {
    Write-LabLog -Message "Remove failed: $_" -Level Error
    Write-LabLog -Message $_.ScriptStackTrace -Level Error
    throw
}
finally {
    if (-not $SkipAuth) {
        Disconnect-LabServices
    }
    Complete-LabLogging
}
