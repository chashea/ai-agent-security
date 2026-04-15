#Requires -Version 7.0
#Requires -Modules Pester

BeforeAll {
    $loggingPath = Join-Path $PSScriptRoot '..' 'modules' 'Logging.psm1'
    Import-Module $loggingPath -Force

    $prereqPath = Join-Path $PSScriptRoot '..' 'modules' 'Prerequisites.psm1'
    Import-Module $prereqPath -Force

    $modulePath = Join-Path $PSScriptRoot '..' 'modules' 'TestUsers.psm1'
    Import-Module $modulePath -Force
}

Describe 'Deploy-TestUsers' {
    BeforeEach {
        Mock Get-MgContext {
            [PSCustomObject]@{ Account = 'admin@contoso.com'; Scopes = @('User.ReadWrite.All') }
        } -ModuleName TestUsers

        Mock Get-MgGroup { return $null } -ModuleName TestUsers
        Mock New-MgGroup {
            [PSCustomObject]@{ Id = 'grp-001'; DisplayName = $DisplayName }
        } -ModuleName TestUsers
        Mock New-MgGroupMember {} -ModuleName TestUsers
        Mock Get-MgUser { return $null } -ModuleName TestUsers
        Mock New-MgUser {} -ModuleName TestUsers
        Mock Get-MgSubscribedSku { return @() } -ModuleName TestUsers
        Mock Get-LabUserByIdentity { return $null } -ModuleName TestUsers
        Mock Invoke-LabRetry {
            [PSCustomObject]@{ UserPrincipalName = 'test@contoso.com'; Id = 'uid-1' }
        } -ModuleName TestUsers
    }

    It 'Creates groups when none exist' {
        $config = [PSCustomObject]@{
            prefix = 'AISec'
            domain = 'contoso.com'
            workloads = [PSCustomObject]@{
                testUsers = [PSCustomObject]@{
                    users  = @()
                    groups = @(
                        [PSCustomObject]@{
                            displayName = 'AISec-TestGroup'
                            members     = @()
                        }
                    )
                }
            }
        }
        $result = Deploy-TestUsers -Config $config
        $result.groups | Should -HaveCount 1
        $result.groups[0] | Should -Be 'AISec-TestGroup'
        Should -Invoke New-MgGroup -Times 1 -ModuleName TestUsers
    }

    It 'Skips existing groups (idempotent)' {
        Mock Get-MgGroup {
            [PSCustomObject]@{ Id = 'grp-existing'; DisplayName = 'AISec-TestGroup' }
        } -ModuleName TestUsers

        $config = [PSCustomObject]@{
            prefix = 'AISec'
            domain = 'contoso.com'
            workloads = [PSCustomObject]@{
                testUsers = [PSCustomObject]@{
                    users  = @()
                    groups = @(
                        [PSCustomObject]@{
                            displayName = 'AISec-TestGroup'
                            members     = @()
                        }
                    )
                }
            }
        }
        $result = Deploy-TestUsers -Config $config
        $result.groups | Should -HaveCount 1
        Should -Invoke New-MgGroup -Times 0 -ModuleName TestUsers
    }

    It 'Returns manifest with group and user arrays' {
        $config = [PSCustomObject]@{
            prefix = 'AISec'
            domain = 'contoso.com'
            workloads = [PSCustomObject]@{
                testUsers = [PSCustomObject]@{
                    users  = @()
                    groups = @()
                }
            }
        }
        $result = Deploy-TestUsers -Config $config
        $result.Keys | Should -Contain 'users'
        $result.Keys | Should -Contain 'groups'
    }
}

Describe 'Remove-TestUsers' {
    BeforeEach {
        Mock Get-MgContext {
            [PSCustomObject]@{ Account = 'admin@contoso.com'; Scopes = @('User.ReadWrite.All') }
        } -ModuleName TestUsers
        Mock Get-MgGroup {
            [PSCustomObject]@{ Id = 'grp-001'; DisplayName = 'AISec-TestGroup' }
        } -ModuleName TestUsers
        Mock Remove-MgGroup {} -ModuleName TestUsers
        Mock Get-MgUser { return $null } -ModuleName TestUsers
        Mock Remove-MgUser {} -ModuleName TestUsers
    }

    It 'Removes groups from config' {
        $config = [PSCustomObject]@{
            prefix = 'AISec'
            domain = 'contoso.com'
            workloads = [PSCustomObject]@{
                testUsers = [PSCustomObject]@{
                    users  = @()
                    groups = @(
                        [PSCustomObject]@{ displayName = 'AISec-TestGroup'; members = @() }
                    )
                }
            }
        }
        Remove-TestUsers -Config $config
        Should -Invoke Remove-MgGroup -Times 1 -ModuleName TestUsers
    }
}
