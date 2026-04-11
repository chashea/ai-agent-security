#Requires -Version 7.0
#Requires -Modules Pester

BeforeAll {
    # Import Logging first (dependency for AgentIdentity)
    $loggingPath = Join-Path $PSScriptRoot '..' 'modules' 'Logging.psm1'
    Import-Module $loggingPath -Force

    $modulePath = Join-Path $PSScriptRoot '..' 'modules' 'AgentIdentity.psm1'
    Import-Module $modulePath -Force
}

Describe 'Get-ToolRoleRequirements' {
    It 'Always includes baseline Cognitive Services User role' {
        $agents = @()
        $result = Get-ToolRoleRequirements -Agents $agents
        $result.Count | Should -Be 1
        $result[0].roleName | Should -Be 'Cognitive Services User'
        $result[0].scopeType | Should -Be 'foundryAccount'
        $result[0].roleDefinitionId | Should -Be 'a97b65f3-24c7-4388-baec-2e87135dc908'
    }

    It 'Maps azure_ai_search to Search Index Data Reader' {
        $agents = @(
            [PSCustomObject]@{ name = 'TestAgent'; tools = @([PSCustomObject]@{ type = 'azure_ai_search' }) }
        )
        $result = Get-ToolRoleRequirements -Agents $agents
        $searchRole = $result | Where-Object { $_.roleName -eq 'Search Index Data Reader' }
        $searchRole | Should -Not -BeNullOrEmpty
        $searchRole.scopeType | Should -Be 'aiSearch'
    }

    It 'Maps file_search to Storage Blob Data Reader' {
        $agents = @(
            [PSCustomObject]@{ name = 'TestAgent'; tools = @([PSCustomObject]@{ type = 'file_search' }) }
        )
        $result = Get-ToolRoleRequirements -Agents $agents
        $storageRole = $result | Where-Object { $_.roleName -eq 'Storage Blob Data Reader' }
        $storageRole | Should -Not -BeNullOrEmpty
        $storageRole.scopeType | Should -Be 'storage'
    }

    It 'Maps code_interpreter to Storage Blob Data Contributor' {
        $agents = @(
            [PSCustomObject]@{ name = 'TestAgent'; tools = @([PSCustomObject]@{ type = 'code_interpreter' }) }
        )
        $result = Get-ToolRoleRequirements -Agents $agents
        $storageRole = $result | Where-Object { $_.roleName -eq 'Storage Blob Data Contributor' }
        $storageRole | Should -Not -BeNullOrEmpty
        $storageRole.scopeType | Should -Be 'storage'
    }

    It 'Maps azure_function to Website Contributor' {
        $agents = @(
            [PSCustomObject]@{ name = 'TestAgent'; tools = @([PSCustomObject]@{ type = 'azure_function' }) }
        )
        $result = Get-ToolRoleRequirements -Agents $agents
        $funcRole = $result | Where-Object { $_.roleName -eq 'Website Contributor' }
        $funcRole | Should -Not -BeNullOrEmpty
        $funcRole.scopeType | Should -Be 'functionApp'
    }

    It 'Deduplicates roles across multiple agents with the same tool' {
        $agents = @(
            [PSCustomObject]@{ name = 'Agent1'; tools = @([PSCustomObject]@{ type = 'code_interpreter' }) }
            [PSCustomObject]@{ name = 'Agent2'; tools = @([PSCustomObject]@{ type = 'code_interpreter' }) }
            [PSCustomObject]@{ name = 'Agent3'; tools = @([PSCustomObject]@{ type = 'code_interpreter' }) }
        )
        $result = Get-ToolRoleRequirements -Agents $agents
        $storageRoles = @($result | Where-Object { $_.roleName -eq 'Storage Blob Data Contributor' })
        $storageRoles.Count | Should -Be 1
    }

    It 'Produces no extra roles for tools without RBAC mapping' {
        $agents = @(
            [PSCustomObject]@{ name = 'TestAgent'; tools = @(
                [PSCustomObject]@{ type = 'openapi' }
                [PSCustomObject]@{ type = 'mcp' }
                [PSCustomObject]@{ type = 'a2a' }
                [PSCustomObject]@{ type = 'function' }
                [PSCustomObject]@{ type = 'sharepoint_grounding' }
            )}
        )
        $result = Get-ToolRoleRequirements -Agents $agents
        # Only baseline role
        $result.Count | Should -Be 1
        $result[0].roleName | Should -Be 'Cognitive Services User'
    }

    It 'Handles multiple tool types across agents correctly' {
        $agents = @(
            [PSCustomObject]@{ name = 'Agent1'; tools = @(
                [PSCustomObject]@{ type = 'azure_ai_search' }
                [PSCustomObject]@{ type = 'code_interpreter' }
            )}
            [PSCustomObject]@{ name = 'Agent2'; tools = @(
                [PSCustomObject]@{ type = 'file_search' }
                [PSCustomObject]@{ type = 'azure_function' }
            )}
        )
        $result = Get-ToolRoleRequirements -Agents $agents
        # Baseline + Search Index Data Reader + Storage Blob Data Contributor + Storage Blob Data Reader + Website Contributor
        $result.Count | Should -Be 5
    }

    It 'Handles agents with no tools property' {
        $agents = @(
            [PSCustomObject]@{ name = 'NoToolsAgent' }
        )
        $result = Get-ToolRoleRequirements -Agents $agents
        $result.Count | Should -Be 1
    }

    It 'Handles string tool type values' {
        $agents = @(
            [PSCustomObject]@{ name = 'TestAgent'; tools = @('code_interpreter', 'file_search') }
        )
        $result = Get-ToolRoleRequirements -Agents $agents
        $result.Count | Should -Be 3  # baseline + StorageBlobDataContributor + StorageBlobDataReader
    }
}
