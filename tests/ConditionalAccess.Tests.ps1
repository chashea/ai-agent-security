#Requires -Version 7.0
#Requires -Modules Pester

BeforeAll {
    $loggingPath = Join-Path $PSScriptRoot '..' 'modules' 'Logging.psm1'
    Import-Module $loggingPath -Force

    $prereqPath = Join-Path $PSScriptRoot '..' 'modules' 'Prerequisites.psm1'
    Import-Module $prereqPath -Force

    $modulePath = Join-Path $PSScriptRoot '..' 'modules' 'ConditionalAccess.psm1'
    Import-Module $modulePath -Force
}

Describe 'Deploy-ConditionalAccess' {
    BeforeEach {
        Mock Get-MgContext {
            [PSCustomObject]@{ Scopes = @('Policy.ReadWrite.ConditionalAccess', 'Policy.Read.All') }
        } -ModuleName ConditionalAccess

        Mock Get-MgIdentityConditionalAccessPolicy { return $null } -ModuleName ConditionalAccess
        Mock New-MgIdentityConditionalAccessPolicy {
            [PSCustomObject]@{ Id = 'new-ca-id' }
        } -ModuleName ConditionalAccess
    }

    It 'Returns empty manifest when Graph scopes missing' {
        Mock Get-MgContext { return $null } -ModuleName ConditionalAccess

        $config = [PSCustomObject]@{
            prefix = 'AISec'
            workloads = [PSCustomObject]@{
                conditionalAccess = [PSCustomObject]@{
                    policies = @([PSCustomObject]@{
                        name         = 'Block-Risky'
                        action       = 'block'
                        targetAppIds = @('all')
                    })
                }
            }
        }
        $result = Deploy-ConditionalAccess -Config $config
        $result.policies | Should -HaveCount 0
    }

    It 'Creates policies in report-only state' {
        $config = [PSCustomObject]@{
            prefix = 'AISec'
            workloads = [PSCustomObject]@{
                conditionalAccess = [PSCustomObject]@{
                    policies = @([PSCustomObject]@{
                        name         = 'Block-Risky'
                        action       = 'block'
                        targetAppIds = @('all')
                    })
                }
            }
        }
        $result = Deploy-ConditionalAccess -Config $config
        $result.policies | Should -HaveCount 1
        $result.policies[0].state | Should -Be 'enabledForReportingButNotEnforced'
        $result.policies[0].status | Should -Be 'created'
    }

    It 'WhatIf mode makes no changes' {
        $config = [PSCustomObject]@{
            prefix = 'AISec'
            workloads = [PSCustomObject]@{
                conditionalAccess = [PSCustomObject]@{
                    policies = @([PSCustomObject]@{
                        name         = 'MFA-Policy'
                        action       = 'mfa'
                        targetAppIds = @('all')
                    })
                }
            }
        }
        Deploy-ConditionalAccess -Config $config -WhatIf
        Should -Invoke New-MgIdentityConditionalAccessPolicy -Times 0 -ModuleName ConditionalAccess
    }
}

Describe 'Remove-ConditionalAccess' {
    BeforeEach {
        Mock Get-MgIdentityConditionalAccessPolicy {
            [PSCustomObject]@{ Id = 'ca-id-1'; DisplayName = 'AISec-Block-Risky' }
        } -ModuleName ConditionalAccess
        Mock Remove-MgIdentityConditionalAccessPolicy {} -ModuleName ConditionalAccess
    }

    It 'Removes policies by manifest ID' {
        $config = [PSCustomObject]@{
            prefix = 'AISec'
            workloads = [PSCustomObject]@{
                conditionalAccess = [PSCustomObject]@{ policies = @() }
            }
        }
        $manifest = [PSCustomObject]@{
            policies = @(@{ name = 'AISec-Block-Risky'; id = 'ca-id-1' })
        }
        Remove-ConditionalAccess -Config $config -Manifest $manifest
        Should -Invoke Remove-MgIdentityConditionalAccessPolicy -Times 1 -ModuleName ConditionalAccess
    }
}
