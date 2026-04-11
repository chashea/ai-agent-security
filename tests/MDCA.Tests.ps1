#Requires -Version 7.0
#Requires -Modules Pester

BeforeAll {
    # Import dependencies
    $loggingPath = Join-Path $PSScriptRoot '..' 'modules' 'Logging.psm1'
    Import-Module $loggingPath -Force

    $modulePath = Join-Path $PSScriptRoot '..' 'modules' 'MDCA.psm1'
    Import-Module $modulePath -Force
}

Describe 'Test-MdcaGraphScopes' {
    It 'Returns false when no Graph context exists' {
        Mock Get-MgContext { return $null } -ModuleName MDCA
        InModuleScope MDCA { Test-MdcaGraphScopes } | Should -Be $false
    }

    It 'Returns false when required scopes are missing' {
        Mock Get-MgContext {
            [PSCustomObject]@{ Scopes = @('User.Read') }
        } -ModuleName MDCA
        InModuleScope MDCA { Test-MdcaGraphScopes } | Should -Be $false
    }

    It 'Returns true when required scopes are present' {
        Mock Get-MgContext {
            [PSCustomObject]@{ Scopes = @('Policy.ReadWrite.ConditionalAccess', 'Policy.Read.All', 'CloudAppSecurity.ReadWrite.All') }
        } -ModuleName MDCA
        InModuleScope MDCA { Test-MdcaGraphScopes } | Should -Be $true
    }
}

Describe 'Resolve-AgentAppIds' {
    It 'Extracts app IDs from Foundry manifest bot services' {
        $manifest = [PSCustomObject]@{
            botServices = [PSCustomObject]@{
                bots = @(
                    [PSCustomObject]@{ appClientId = 'app-id-1' }
                    [PSCustomObject]@{ appClientId = 'app-id-2' }
                )
            }
        }
        $result = InModuleScope MDCA -Parameters @{ manifest = $manifest } {
            param($manifest)
            Resolve-AgentAppIds -FoundryManifest $manifest
        }
        $result.Count | Should -Be 2
        $result | Should -Contain 'app-id-1'
        $result | Should -Contain 'app-id-2'
    }

    It 'Returns empty array when manifest has no bot services' {
        $manifest = [PSCustomObject]@{ accountId = 'test' }
        Mock Get-MgApplication { return @() } -ModuleName MDCA
        $result = InModuleScope MDCA -Parameters @{ manifest = $manifest } {
            param($manifest)
            Resolve-AgentAppIds -FoundryManifest $manifest -Prefix 'AISec'
        }
        $result.Count | Should -Be 0
    }
}

Describe 'Deploy-MDCA' {
    BeforeEach {
        # Mock Graph scopes as valid
        Mock Get-MgContext {
            [PSCustomObject]@{ Scopes = @('Policy.ReadWrite.ConditionalAccess', 'Policy.Read.All', 'CloudAppSecurity.ReadWrite.All') }
        } -ModuleName MDCA

        # Mock CA policy operations
        Mock Get-MgIdentityConditionalAccessPolicy { return $null } -ModuleName MDCA
        Mock New-MgIdentityConditionalAccessPolicy {
            [PSCustomObject]@{ Id = 'ca-policy-id-1' }
        } -ModuleName MDCA

        # Mock SP operations
        Mock Get-MgApplication { return @() } -ModuleName MDCA
        Mock Get-MgServicePrincipal { return $null } -ModuleName MDCA
        Mock Update-MgServicePrincipal {} -ModuleName MDCA
    }

    It 'Skips all policies when Graph scopes are missing' {
        Mock Get-MgContext { return $null } -ModuleName MDCA

        $config = [PSCustomObject]@{
            prefix = 'AISec'
            workloads = [PSCustomObject]@{
                mdca = [PSCustomObject]@{
                    enabled   = $true
                    portalUrl = ''
                    policies  = @([PSCustomObject]@{ name = 'Test'; type = 'session'; sessionControlType = 'monitorOnly' })
                }
            }
        }
        $result = Deploy-MDCA -Config $config
        $result.caPolicies.Count | Should -Be 0
        $result.mdcaPolicies.Count | Should -Be 0
    }

    It 'Creates session CA policy with CAAC controls' {
        $config = [PSCustomObject]@{
            prefix = 'AISec'
            workloads = [PSCustomObject]@{
                mdca = [PSCustomObject]@{
                    enabled   = $true
                    portalUrl = ''
                    policies  = @([PSCustomObject]@{
                        name               = 'AI Agent Session Monitor'
                        type               = 'session'
                        sessionControlType = 'monitorOnly'
                        description        = 'Test session policy'
                    })
                }
            }
        }
        $result = Deploy-MDCA -Config $config
        $result.caPolicies.Count | Should -Be 1
        $result.caPolicies[0].type | Should -Be 'session'
        $result.caPolicies[0].status | Should -Be 'created'
        Should -Invoke New-MgIdentityConditionalAccessPolicy -Times 1 -ModuleName MDCA
    }

    It 'Skips activity policy when portalUrl is empty' {
        $config = [PSCustomObject]@{
            prefix = 'AISec'
            workloads = [PSCustomObject]@{
                mdca = [PSCustomObject]@{
                    enabled   = $true
                    portalUrl = ''
                    policies  = @([PSCustomObject]@{
                        name        = 'Test Activity'
                        type        = 'activity'
                        description = 'Test'
                        severity    = 'medium'
                    })
                }
            }
        }
        $result = Deploy-MDCA -Config $config
        $result.mdcaPolicies.Count | Should -Be 1
        $result.mdcaPolicies[0].status | Should -Be 'skipped'
    }

    It 'Reports existing session policy as idempotent' {
        Mock Get-MgIdentityConditionalAccessPolicy {
            [PSCustomObject]@{ Id = 'existing-ca-id' }
        } -ModuleName MDCA

        $config = [PSCustomObject]@{
            prefix = 'AISec'
            workloads = [PSCustomObject]@{
                mdca = [PSCustomObject]@{
                    enabled   = $true
                    portalUrl = ''
                    policies  = @([PSCustomObject]@{
                        name               = 'Test Session'
                        type               = 'session'
                        sessionControlType = 'monitorOnly'
                    })
                }
            }
        }
        $result = Deploy-MDCA -Config $config
        $result.caPolicies[0].status | Should -Be 'existing'
        Should -Invoke New-MgIdentityConditionalAccessPolicy -Times 0 -ModuleName MDCA
    }
}

Describe 'Remove-MDCA' {
    BeforeEach {
        Mock Get-MgIdentityConditionalAccessPolicy {
            [PSCustomObject]@{ Id = 'ca-id-1'; DisplayName = 'AISec-Test' }
        } -ModuleName MDCA
        Mock Remove-MgIdentityConditionalAccessPolicy {} -ModuleName MDCA
        Mock Get-MgServicePrincipal { return $null } -ModuleName MDCA
    }

    It 'Removes CA policies by manifest ID' {
        $config = [PSCustomObject]@{
            prefix = 'AISec'
            workloads = [PSCustomObject]@{
                mdca = [PSCustomObject]@{
                    enabled   = $true
                    portalUrl = ''
                    policies  = @()
                }
            }
        }
        $manifest = [PSCustomObject]@{
            caPolicies = @(
                @{ name = 'AISec-Test'; id = 'ca-id-1'; type = 'session' }
            )
            mdcaPolicies = @()
            taggedServicePrincipals = @()
        }

        Remove-MDCA -Config $config -Manifest $manifest
        Should -Invoke Remove-MgIdentityConditionalAccessPolicy -Times 1 -ModuleName MDCA -ParameterFilter { $ConditionalAccessPolicyId -eq 'ca-id-1' }
    }

    It 'Falls back to prefix lookup when no manifest' {
        $config = [PSCustomObject]@{
            prefix = 'AISec'
            workloads = [PSCustomObject]@{
                mdca = [PSCustomObject]@{
                    enabled   = $true
                    portalUrl = ''
                    policies  = @([PSCustomObject]@{ name = 'Test'; type = 'session' })
                }
            }
        }

        Remove-MDCA -Config $config
        Should -Invoke Get-MgIdentityConditionalAccessPolicy -ModuleName MDCA
    }
}
