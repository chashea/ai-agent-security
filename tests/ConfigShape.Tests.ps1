#Requires -Version 7.0
#Requires -Modules Pester

<#
.SYNOPSIS
    Config-shape regression tests for ai-agent-security.

.DESCRIPTION
    Asserts the shape of config.sample.json matches the expected layout for
    the Foundry + labeling tool. These tests protect against regressions
    where a contributor reverts a corrected field (e.g., label AI Search
    roles) or reintroduces a removed workload section. Prefers the user's
    local config.json when present, falls back to the tracked sample so CI
    can run without a populated config.
#>

BeforeAll {
    $repoRoot = Join-Path $PSScriptRoot '..'
    $script:ConfigPath = Join-Path $repoRoot 'config.json'
    if (-not (Test-Path -Path $script:ConfigPath -PathType Leaf)) {
        $script:ConfigPath = Join-Path $repoRoot 'config.sample.json'
    }
    $script:Config = Get-Content -Path $script:ConfigPath -Raw | ConvertFrom-Json
}

Describe 'Foundry subscription-level prerequisites' {
    It 'Declares foundry.userSecurityContext.enabled = true' {
        $script:Config.workloads.foundry.userSecurityContext.enabled | Should -BeTrue
    }
}

Describe 'Sensitivity label AI Search enforcement' {
    It 'Declares the aiSearchEnforcement block' {
        $script:Config.workloads.sensitivityLabels.aiSearchEnforcement | Should -Not -BeNullOrEmpty
    }

    It 'Grants both required Purview roles to the AI Search managed identity' {
        $roles = @($script:Config.workloads.sensitivityLabels.aiSearchEnforcement.managedIdentityRoles)
        $roles | Should -Contain 'Content.SuperUser'
        $roles | Should -Contain 'UnifiedPolicy.Tenant.Read'
    }
}

Describe 'Removed workload sections' {
    It 'Does not declare the dlp workload' {
        $script:Config.workloads.PSObject.Properties['dlp'] | Should -BeNullOrEmpty
    }

    It 'Does not declare the retention workload' {
        $script:Config.workloads.PSObject.Properties['retention'] | Should -BeNullOrEmpty
    }

    It 'Does not declare the collectionPolicies workload' {
        $script:Config.workloads.PSObject.Properties['collectionPolicies'] | Should -BeNullOrEmpty
    }

    It 'Does not declare the communicationCompliance workload' {
        $script:Config.workloads.PSObject.Properties['communicationCompliance'] | Should -BeNullOrEmpty
    }

    It 'Does not declare the insiderRisk workload' {
        $script:Config.workloads.PSObject.Properties['insiderRisk'] | Should -BeNullOrEmpty
    }

    It 'Does not declare the auditConfig workload' {
        $script:Config.workloads.PSObject.Properties['auditConfig'] | Should -BeNullOrEmpty
    }

    It 'Does not declare the eDiscovery workload' {
        $script:Config.workloads.PSObject.Properties['eDiscovery'] | Should -BeNullOrEmpty
    }
}

Describe 'Test-LabConfigValidity accepts the full config shape' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'Logging.psm1') -Force
        Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'Prerequisites.psm1') -Force
        $script:UsingRealConfig = (Split-Path -Leaf $script:ConfigPath) -eq 'config.json'
    }

    It 'Returns true for a populated config.json' -Skip:(-not $script:UsingRealConfig) {
        Test-LabConfigValidity -Config $script:Config | Should -BeTrue
    }
}
