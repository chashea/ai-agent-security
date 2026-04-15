#Requires -Version 7.0
#Requires -Modules Pester

BeforeAll {
    $loggingPath = Join-Path $PSScriptRoot '..' 'modules' 'Logging.psm1'
    Import-Module $loggingPath -Force

    $prereqPath = Join-Path $PSScriptRoot '..' 'modules' 'Prerequisites.psm1'
    Import-Module $prereqPath -Force

    $modulePath = Join-Path $PSScriptRoot '..' 'modules' 'FoundryInfra.psm1'
    Import-Module $modulePath -Force
}

Describe 'New-FoundryAgentPackage' {
    BeforeAll {
        $script:OutputDir = Join-Path $TestDrive 'packages'
        New-Item -ItemType Directory -Path $script:OutputDir -Force | Out-Null
    }

    AfterEach {
        Get-ChildItem -Path $script:OutputDir -Filter '*.zip' -ErrorAction SilentlyContinue |
            Remove-Item -Force
    }

    It 'Generates a valid zip file with manifest.json inside' {
        $agent = [PSCustomObject]@{
            name    = 'AISec-HR-Helpdesk'
            baseUrl = 'https://example.com'
        }
        $agentConfig = [PSCustomObject]@{
            description  = 'HR helper agent'
            instructions = 'Help users with HR questions'
        }

        $zipPath = New-FoundryAgentPackage `
            -Agent $agent `
            -Prefix 'AISec' `
            -AgentConfig $agentConfig `
            -OutputDir $script:OutputDir `
            -TenantId '00000000-0000-0000-0000-000000000000'

        $zipPath | Should -Not -BeNullOrEmpty
        Test-Path $zipPath | Should -BeTrue

        # Verify manifest.json is inside the zip
        $extractDir = Join-Path $TestDrive 'extract'
        Expand-Archive -Path $zipPath -DestinationPath $extractDir -Force
        $manifestPath = Join-Path $extractDir 'manifest.json'
        Test-Path $manifestPath | Should -BeTrue

        $manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
        $manifest.id | Should -Not -BeNullOrEmpty
        $manifest.name.short | Should -Be 'HR-Helpdesk'

        Remove-Item $extractDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'Manifest ID is deterministic (same prefix + name = same GUID)' {
        $agent = [PSCustomObject]@{ name = 'AISec-Finance-Analyst'; baseUrl = 'https://example.com' }
        $agentConfig = [PSCustomObject]@{ description = 'Finance agent'; instructions = 'Help with finance' }

        $zip1 = New-FoundryAgentPackage -Agent $agent -Prefix 'AISec' -AgentConfig $agentConfig `
            -OutputDir $script:OutputDir -TenantId '00000000-0000-0000-0000-000000000000'
        $extract1 = Join-Path $TestDrive 'extract1'
        Expand-Archive -Path $zip1 -DestinationPath $extract1 -Force
        $id1 = (Get-Content (Join-Path $extract1 'manifest.json') -Raw | ConvertFrom-Json).id

        Remove-Item $zip1 -Force

        $zip2 = New-FoundryAgentPackage -Agent $agent -Prefix 'AISec' -AgentConfig $agentConfig `
            -OutputDir $script:OutputDir -TenantId '00000000-0000-0000-0000-000000000000'
        $extract2 = Join-Path $TestDrive 'extract2'
        Expand-Archive -Path $zip2 -DestinationPath $extract2 -Force
        $id2 = (Get-Content (Join-Path $extract2 'manifest.json') -Raw | ConvertFrom-Json).id

        $id1 | Should -Be $id2

        Remove-Item $extract1, $extract2 -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'Manifest version follows the 1.<mmdd>.<hhmmss> pattern' {
        $agent = [PSCustomObject]@{ name = 'AISec-IT-Support'; baseUrl = 'https://example.com' }
        $agentConfig = [PSCustomObject]@{ description = 'IT agent'; instructions = 'IT support' }

        $zipPath = New-FoundryAgentPackage -Agent $agent -Prefix 'AISec' -AgentConfig $agentConfig `
            -OutputDir $script:OutputDir -TenantId '00000000-0000-0000-0000-000000000000'
        $extractDir = Join-Path $TestDrive 'extract_ver'
        Expand-Archive -Path $zipPath -DestinationPath $extractDir -Force

        $manifest = Get-Content (Join-Path $extractDir 'manifest.json') -Raw | ConvertFrom-Json
        $manifest.version | Should -Match '^1\.\d{4}\.\d{6}$'

        Remove-Item $extractDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
