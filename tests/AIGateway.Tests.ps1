#Requires -Version 7.0
#Requires -Modules Pester

BeforeAll {
    $loggingPath = Join-Path $PSScriptRoot '..' 'modules' 'Logging.psm1'
    Import-Module $loggingPath -Force

    $modulePath = Join-Path $PSScriptRoot '..' 'modules' 'AIGateway.psm1'
    Import-Module $modulePath -Force
}

Describe 'Deploy-AIGateway config gating' {
    It 'Skips when aiGateway workload is missing from config' {
        $config = [PSCustomObject]@{
            prefix = 'AISec'
            workloads = [PSCustomObject]@{
                foundry = [PSCustomObject]@{
                    subscriptionId = 'sub'; resourceGroup = 'rg'; location = 'eastus2'; accountName = 'acct'
                }
            }
        }
        $result = Deploy-AIGateway -Config $config
        $result | Should -BeNullOrEmpty
    }

    It 'Skips when aiGateway.enabled is false' {
        $config = [PSCustomObject]@{
            prefix = 'AISec'
            workloads = [PSCustomObject]@{
                aiGateway = [PSCustomObject]@{ enabled = $false }
                foundry = [PSCustomObject]@{
                    subscriptionId = 'sub'; resourceGroup = 'rg'; location = 'eastus2'; accountName = 'acct'
                }
            }
        }
        $result = Deploy-AIGateway -Config $config
        $result | Should -BeNullOrEmpty
    }

    It 'Runs in WhatIf mode without invoking Bicep' {
        $config = [PSCustomObject]@{
            prefix = 'AISec'
            workloads = [PSCustomObject]@{
                aiGateway = [PSCustomObject]@{
                    enabled = $true; name = 'aisec-aigw'; sku = 'BasicV2'
                    publisherEmail = 'a@b.com'; publisherName = 'test'
                }
                foundry = [PSCustomObject]@{
                    subscriptionId = 'sub'; resourceGroup = 'rg'; location = 'eastus2'; accountName = 'acct'
                }
            }
        }
        # In WhatIf mode Deploy-AIGateway should short-circuit and return $null
        $result = Deploy-AIGateway -Config $config -WhatIf
        $result | Should -BeNullOrEmpty
    }
}

Describe 'Remove-AIGateway config gating' {
    It 'Skips when aiGateway workload is missing' {
        $config = [PSCustomObject]@{
            prefix = 'AISec'
            workloads = [PSCustomObject]@{
                foundry = [PSCustomObject]@{ subscriptionId = 'sub'; resourceGroup = 'rg' }
            }
        }
        # Should not throw; returns nothing
        { Remove-AIGateway -Config $config } | Should -Not -Throw
    }

    It 'Skips when aiGateway.enabled is false' {
        $config = [PSCustomObject]@{
            prefix = 'AISec'
            workloads = [PSCustomObject]@{
                aiGateway = [PSCustomObject]@{ enabled = $false }
                foundry = [PSCustomObject]@{ subscriptionId = 'sub'; resourceGroup = 'rg' }
            }
        }
        { Remove-AIGateway -Config $config } | Should -Not -Throw
    }
}

Describe 'AIGateway module contract' {
    It 'Exports Deploy-AIGateway and Remove-AIGateway' {
        $exported = Get-Command -Module AIGateway | Select-Object -ExpandProperty Name
        $exported | Should -Contain 'Deploy-AIGateway'
        $exported | Should -Contain 'Remove-AIGateway'
    }
}
