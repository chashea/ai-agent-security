#Requires -Version 7.0
#Requires -Modules Pester

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..' 'modules' 'Prerequisites.psm1'
    Import-Module $modulePath -Force
}

Describe 'Test-LabConfigValidity' {
    It 'Returns true for valid config with enabled workloads' {
        $config = [PSCustomObject]@{
            labName   = 'AI Agent Security'
            prefix    = 'AISec'
            domain    = 'MngEnvMCAP648165.onmicrosoft.com'
            workloads = [PSCustomObject]@{
                sensitivityLabels = [PSCustomObject]@{
                    enabled = $true
                    labels  = @(
                        [PSCustomObject]@{ name = 'Confidential' }
                    )
                }
                testUsers = [PSCustomObject]@{
                    enabled = $true
                    users   = @(
                        [PSCustomObject]@{ identity = 'user@contoso.com' }
                    )
                }
            }
        }
        Test-LabConfigValidity -Config $config | Should -Be $true
    }

    It 'Returns true when workloads are disabled (no validation needed)' {
        $config = [PSCustomObject]@{
            labName   = 'AI Agent Security'
            prefix    = 'AISec'
            domain    = 'MngEnvMCAP648165.onmicrosoft.com'
            workloads = [PSCustomObject]@{
                sensitivityLabels = [PSCustomObject]@{
                    enabled = $false
                }
            }
        }
        Test-LabConfigValidity -Config $config | Should -Be $true
    }

    It 'Warns when enabled workload has missing required field' {
        $config = [PSCustomObject]@{
            labName   = 'AI Agent Security'
            prefix    = 'AISec'
            domain    = 'MngEnvMCAP648165.onmicrosoft.com'
            workloads = [PSCustomObject]@{
                sensitivityLabels = [PSCustomObject]@{
                    enabled = $true
                }
            }
        }
        Test-LabConfigValidity -Config $config -WarningVariable w 3>$null | Should -Be $false
        $w | Should -Not -BeNullOrEmpty
    }

    It 'Warns when enabled workload has empty array' {
        $config = [PSCustomObject]@{
            labName   = 'AI Agent Security'
            prefix    = 'AISec'
            domain    = 'MngEnvMCAP648165.onmicrosoft.com'
            workloads = [PSCustomObject]@{
                sensitivityLabels = [PSCustomObject]@{
                    enabled = $true
                    labels  = @()
                }
            }
        }
        Test-LabConfigValidity -Config $config -WarningVariable w 3>$null | Should -Be $false
    }

    It 'Returns false when no workloads section exists' {
        $config = [PSCustomObject]@{
            labName = 'AI Agent Security'
            prefix  = 'AISec'
            domain  = 'MngEnvMCAP648165.onmicrosoft.com'
        }
        Test-LabConfigValidity -Config $config -WarningVariable w 3>$null | Should -Be $false
    }

    It 'Validates all workload types from config.json' {
        $configPath = Join-Path $PSScriptRoot '..' 'config.json'
        if (Test-Path $configPath) {
            $config = Import-LabConfig -ConfigPath $configPath
            $result = Test-LabConfigValidity -Config $config
            $result | Should -Be $true
        }
    }
}
