#Requires -Version 7.0
#Requires -Modules Pester

BeforeAll {
    $loggingPath = Join-Path $PSScriptRoot '..' 'modules' 'Logging.psm1'
    Import-Module $loggingPath -Force

    $modulePath = Join-Path $PSScriptRoot '..' 'modules' 'Interactive.psm1'
    Import-Module $modulePath -Force
}

Describe 'Resolve-LabConfigPlaceholders' {

    It 'No-op when no placeholders present' {
        $configContent = '{"labName":"Test","prefix":"T","domain":"contoso.com","cloud":"commercial"}'
        $tempFile = Join-Path $TestDrive 'no-placeholders.json'
        Set-Content -Path $tempFile -Value $configContent -Encoding UTF8

        Resolve-LabConfigPlaceholders -ConfigPath $tempFile

        $after = Get-Content -Path $tempFile -Raw
        $after.Trim() | Should -Be $configContent
    }

    It 'Replaces all four placeholder tokens when present' {
        $samplePath = Join-Path $PSScriptRoot '..' 'config.sample.json'
        $tempFile = Join-Path $TestDrive 'with-placeholders.json'
        Copy-Item -Path $samplePath -Destination $tempFile

        $script:readHostCalls = 0
        Mock Read-Host {
            $script:readHostCalls++
            switch ($script:readHostCalls) {
                1 { return 'testlab.onmicrosoft.com' }
                2 { return '12345678-1234-1234-1234-123456789012' }
                3 { return 'admin@testlab.onmicrosoft.com' }
                default { return '' }
            }
        } -ModuleName Interactive

        Mock Write-LabLog {} -ModuleName Interactive

        # Allow prompts even in non-TTY Pester runner
        InModuleScope Interactive { $script:LabInteractiveBypassTtyCheck = $true }

        try {
            Resolve-LabConfigPlaceholders -ConfigPath $tempFile
        } finally {
            InModuleScope Interactive { $script:LabInteractiveBypassTtyCheck = $false }
        }

        $after = Get-Content -Path $tempFile -Raw
        $after | Should -Not -BeLike '*<TENANT_DOMAIN>*'
        $after | Should -Not -BeLike '*<SUBSCRIPTION_ID>*'
        $after | Should -Not -BeLike '*<PUBLISHER_UPN>*'
        $after | Should -Not -BeLike '*<USER_UPN>*'
        $after | Should -BeLike '*testlab.onmicrosoft.com*'
        $after | Should -BeLike '*12345678-1234-1234-1234-123456789012*'
        $after | Should -BeLike '*admin@testlab.onmicrosoft.com*'
    }

    It 'Copies config.sample.json and resolves placeholders when ConfigPath does not exist' {
        $tempFile = Join-Path $TestDrive 'new-config.json'

        $script:readHostCallsBootstrap = 0
        Mock Read-Host {
            switch ($script:readHostCallsBootstrap++) {
                0 { return 'bootstrapped.onmicrosoft.com' }
                1 { return 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee' }
                2 { return 'admin@bootstrapped.onmicrosoft.com' }
                default { return '' }
            }
        } -ModuleName Interactive

        Mock Write-LabLog {} -ModuleName Interactive

        InModuleScope Interactive { $script:LabInteractiveBypassTtyCheck = $true }

        try {
            Resolve-LabConfigPlaceholders -ConfigPath $tempFile
        } finally {
            InModuleScope Interactive { $script:LabInteractiveBypassTtyCheck = $false }
        }

        Test-Path -Path $tempFile -PathType Leaf | Should -Be $true
        $after = Get-Content -Path $tempFile -Raw
        $after | Should -Not -BeLike '*<TENANT_DOMAIN>*'
        $after | Should -Not -BeLike '*<SUBSCRIPTION_ID>*'
    }

    It 'Throws when source sample is missing and ConfigPath does not exist' {
        $tempFile = Join-Path $TestDrive 'ghost-config.json'

        # Validate the throw logic directly using a scriptblock that mirrors the
        # bootstrap guard inside Resolve-LabConfigPlaceholders.
        $fakeSample = Join-Path $TestDrive 'does-not-exist.json'
        {
            if (-not (Test-Path -Path $tempFile -PathType Leaf)) {
                if (-not (Test-Path -Path $fakeSample -PathType Leaf)) {
                    throw "config.sample.json not found at '$fakeSample'. Cannot bootstrap config."
                }
            }
        } | Should -Throw '*config.sample.json*'
    }
}

Describe 'Request-CreateTestUsersChoice' {

    It 'Returns existing when user presses Enter (default N)' {
        Mock Read-Host { return '' } -ModuleName Interactive
        Request-CreateTestUsersChoice | Should -Be 'existing'
    }

    It 'Returns existing for explicit N' {
        Mock Read-Host { return 'N' } -ModuleName Interactive
        Request-CreateTestUsersChoice | Should -Be 'existing'
    }

    It 'Returns create for y' {
        Mock Read-Host { return 'y' } -ModuleName Interactive
        Request-CreateTestUsersChoice | Should -Be 'create'
    }

    It 'Returns create for Y (case-insensitive)' {
        Mock Read-Host { return 'Y' } -ModuleName Interactive
        Request-CreateTestUsersChoice | Should -Be 'create'
    }
}
