#Requires -Version 7.0
#Requires -Modules Pester

<#
.SYNOPSIS
    Config-shape regression tests for ai-agent-security.

.DESCRIPTION
    Asserts the shape of config.json matches the authoritative Foundry ×
    Purview integration model documented in
    docs/foundry-purview-integration.md. These tests protect against
    regressions where a contributor reverts a corrected field (e.g.,
    retention location back to Exchange/OneDrive, or DLP scope back to
    CopilotExperiences).
#>

BeforeAll {
    $script:ConfigPath = Join-Path $PSScriptRoot '..' 'config.json'
    $script:Config = Get-Content -Path $script:ConfigPath -Raw | ConvertFrom-Json
}

Describe 'Foundry subscription-level prerequisites' {
    It 'Declares foundry.purviewDataSecurity.enable = true' {
        $script:Config.workloads.foundry.purviewDataSecurity.enable | Should -BeTrue
    }

    It 'Records a method for enabling Purview Data Security' {
        $script:Config.workloads.foundry.purviewDataSecurity.method | Should -Not -BeNullOrEmpty
    }

    It 'Declares foundry.userSecurityContext.enabled = true' {
        $script:Config.workloads.foundry.userSecurityContext.enabled | Should -BeTrue
    }

    It 'Declares a foundry.purviewProcessContent block' {
        $script:Config.workloads.foundry.PSObject.Properties['purviewProcessContent'] | Should -Not -BeNullOrEmpty
    }

    It 'Declares a valid failMode for purviewProcessContent' {
        $script:Config.workloads.foundry.purviewProcessContent.failMode | Should -BeIn @('open', 'closed')
    }
}

Describe 'Collection policies prerequisite workload' {
    It 'Includes a top-level collectionPolicies workload' {
        $script:Config.workloads.PSObject.Properties['collectionPolicies'] | Should -Not -BeNullOrEmpty
    }

    It 'Defines at least one collection policy' {
        @($script:Config.workloads.collectionPolicies.policies).Count | Should -BeGreaterThan 0
    }

    It 'Targets the EnterpriseAIApps category for each collection policy' {
        foreach ($policy in @($script:Config.workloads.collectionPolicies.policies)) {
            $policy.appCategory | Should -Be 'EnterpriseAIApps'
        }
    }
}

Describe 'DLP scope (Entra-registered AI app)' {
    It 'Uses entraRegisteredAiApp scope for the Foundry-targeted policy' {
        $foundryDlp = @($script:Config.workloads.dlp.policies) |
            Where-Object { $_.PSObject.Properties['scope'] -and $_.scope -eq 'entraRegisteredAiApp' } |
            Select-Object -First 1
        $foundryDlp | Should -Not -BeNullOrEmpty
    }

    It 'Declares target Entra app(s) for app-scoped DLP rules' {
        $foundryDlp = @($script:Config.workloads.dlp.policies) |
            Where-Object { $_.PSObject.Properties['scope'] -and $_.scope -eq 'entraRegisteredAiApp' } |
            Select-Object -First 1
        # Accept either the singular `targetedEntraAppDisplayName` (legacy) or the
        # plural `targetedEntraAppDisplayNames` (preferred — covers all bot apps).
        $hasSingular = $foundryDlp.PSObject.Properties['targetedEntraAppDisplayName'] -and
                       -not [string]::IsNullOrWhiteSpace([string]$foundryDlp.targetedEntraAppDisplayName)
        $hasPlural = $foundryDlp.PSObject.Properties['targetedEntraAppDisplayNames'] -and
                     @($foundryDlp.targetedEntraAppDisplayNames).Count -gt 0
        ($hasSingular -or $hasPlural) | Should -BeTrue
    }

    It 'Does NOT use CopilotExperiences location (wrong for custom Foundry agents)' {
        foreach ($policy in @($script:Config.workloads.dlp.policies)) {
            if ($policy.PSObject.Properties['locations']) {
                $policy.locations | Should -Not -Contain 'CopilotExperiences'
            }
        }
    }
}

Describe 'Retention location (EnterpriseAI)' {
    It 'Uses EnterpriseAI as the retention location for AI interactions' {
        $script:Config.workloads.retention.policies[0].locations | Should -Contain 'EnterpriseAI'
    }

    It 'Does NOT use Exchange/OneDrive (those locations do not capture Foundry interactions)' {
        $script:Config.workloads.retention.policies[0].locations | Should -Not -Contain 'Exchange'
        $script:Config.workloads.retention.policies[0].locations | Should -Not -Contain 'OneDrive'
    }
}

Describe 'eDiscovery workload removed' {
    It 'Does not declare the eDiscovery workload (removed from lab surface)' {
        $script:Config.workloads.PSObject.Properties['eDiscovery'] | Should -BeNullOrEmpty
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

Describe 'Insider Risk template name' {
    It 'References the Risky AI usage template by human-readable name' {
        $script:Config.workloads.insiderRisk.policies[0].template | Should -Match 'Risky\s*AI\s*usage'
    }
}

Describe 'Test-LabConfigValidity accepts the full config shape' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'Prerequisites.psm1') -Force
    }

    It 'Returns true for the current config.json' {
        Test-LabConfigValidity -Config $script:Config | Should -BeTrue
    }
}
