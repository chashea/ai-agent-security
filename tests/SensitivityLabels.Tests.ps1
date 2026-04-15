#Requires -Version 7.0
#Requires -Modules Pester

BeforeAll {
    # Stub EXO/Compliance cmdlets that are not installed in the test environment.
    # Pester requires a command to exist before it can be mocked.
    $complianceStubs = @(
        'Get-Label', 'New-Label', 'Set-Label', 'Remove-Label',
        'Get-LabelPolicy', 'New-LabelPolicy', 'Set-LabelPolicy', 'Remove-LabelPolicy',
        'Get-AutoSensitivityLabelPolicy', 'New-AutoSensitivityLabelPolicy', 'Remove-AutoSensitivityLabelPolicy',
        'Get-AutoSensitivityLabelRule', 'New-AutoSensitivityLabelRule', 'Remove-AutoSensitivityLabelRule'
    )
    foreach ($cmd in $complianceStubs) {
        if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
            Set-Item -Path "function:global:$cmd" -Value { }
        }
    }

    $loggingPath = Join-Path $PSScriptRoot '..' 'modules' 'Logging.psm1'
    Import-Module $loggingPath -Force

    $prereqPath = Join-Path $PSScriptRoot '..' 'modules' 'Prerequisites.psm1'
    Import-Module $prereqPath -Force

    # Re-import the module so it picks up the stub functions
    $modulePath = Join-Path $PSScriptRoot '..' 'modules' 'SensitivityLabels.psm1'
    Import-Module $modulePath -Force
}

Describe 'Deploy-SensitivityLabels' {
    BeforeEach {
        Mock Get-Command {
            [PSCustomObject]@{
                Parameters = @{
                    IsLabelGroup        = $true
                    Labels              = $true
                    ExchangeLocation    = $true
                    ModernGroupLocation = $true
                    ScopedLabels        = $true
                    AddLabels           = $true
                }
            }
        } -ModuleName SensitivityLabels

        Mock Get-Label { return @() } -ModuleName SensitivityLabels
        Mock New-Label {} -ModuleName SensitivityLabels
        Mock Set-Label {} -ModuleName SensitivityLabels
        Mock Get-LabelPolicy { return $null } -ModuleName SensitivityLabels
        Mock New-LabelPolicy {} -ModuleName SensitivityLabels
        Mock Get-AutoSensitivityLabelPolicy { throw 'Not found' } -ModuleName SensitivityLabels
        Mock New-AutoSensitivityLabelPolicy {} -ModuleName SensitivityLabels
        Mock New-AutoSensitivityLabelRule {} -ModuleName SensitivityLabels
        Mock Invoke-LabRetry { & $ScriptBlock } -ModuleName SensitivityLabels
    }

    It 'Creates parent labels when none exist' {
        $config = [PSCustomObject]@{
            prefix = 'AISec'
            workloads = [PSCustomObject]@{
                sensitivityLabels = [PSCustomObject]@{
                    labels = @(
                        [PSCustomObject]@{
                            name      = 'Confidential'
                            tooltip   = 'Test tooltip'
                            sublabels = @()
                        }
                    )
                    autoLabelPolicies = @()
                }
            }
        }
        $result = Deploy-SensitivityLabels -Config $config
        $result.labels | Should -HaveCount 1
        $result.labels[0].name | Should -Be 'AISec-Confidential'
        Should -Invoke New-Label -Times 1 -ModuleName SensitivityLabels
    }

    It 'Skips existing labels (idempotent)' {
        Mock Get-Label {
            @([PSCustomObject]@{
                DisplayName  = 'AISec-Confidential'
                Guid         = 'aaaa-bbbb'
                Mode         = 'Enforce'
                IsLabelGroup = $true
            })
        } -ModuleName SensitivityLabels

        $config = [PSCustomObject]@{
            prefix = 'AISec'
            workloads = [PSCustomObject]@{
                sensitivityLabels = [PSCustomObject]@{
                    labels = @(
                        [PSCustomObject]@{
                            name      = 'Confidential'
                            tooltip   = 'Tip'
                            sublabels = @()
                        }
                    )
                    autoLabelPolicies = @()
                }
            }
        }
        $result = Deploy-SensitivityLabels -Config $config
        $result.labels | Should -HaveCount 1
        Should -Invoke New-Label -Times 0 -ModuleName SensitivityLabels
    }

    It 'Returns manifest with label entries' {
        $config = [PSCustomObject]@{
            prefix = 'AISec'
            workloads = [PSCustomObject]@{
                sensitivityLabels = [PSCustomObject]@{
                    labels            = @()
                    autoLabelPolicies = @()
                }
            }
        }
        $result = Deploy-SensitivityLabels -Config $config
        $result | Should -Not -BeNullOrEmpty
        $result.PSObject.Properties.Name | Should -Contain 'labels'
        $result.PSObject.Properties.Name | Should -Contain 'autoLabelPolicies'
    }

    It 'WhatIf mode makes no changes' {
        $config = [PSCustomObject]@{
            prefix = 'AISec'
            workloads = [PSCustomObject]@{
                sensitivityLabels = [PSCustomObject]@{
                    labels = @(
                        [PSCustomObject]@{
                            name      = 'Secret'
                            tooltip   = 'Tip'
                            sublabels = @()
                        }
                    )
                    autoLabelPolicies = @()
                }
            }
        }
        Deploy-SensitivityLabels -Config $config -WhatIf
        Should -Invoke New-Label -Times 0 -ModuleName SensitivityLabels
    }
}

Describe 'Remove-SensitivityLabels' {
    BeforeEach {
        Mock Get-AutoSensitivityLabelRule { throw 'Not found' } -ModuleName SensitivityLabels
        Mock Remove-AutoSensitivityLabelRule {} -ModuleName SensitivityLabels
        Mock Get-AutoSensitivityLabelPolicy { throw 'Not found' } -ModuleName SensitivityLabels
        Mock Remove-AutoSensitivityLabelPolicy {} -ModuleName SensitivityLabels
        Mock Get-LabelPolicy { return $null } -ModuleName SensitivityLabels
        Mock Remove-LabelPolicy {} -ModuleName SensitivityLabels
        Mock Get-Label { return @() } -ModuleName SensitivityLabels
        Mock Remove-Label {} -ModuleName SensitivityLabels
    }

    It 'Uses manifest entries for removal' {
        Mock Get-Label {
            [PSCustomObject]@{ DisplayName = 'AISec-Confidential'; Guid = 'lbl-1'; Mode = 'Enforce' }
        } -ModuleName SensitivityLabels

        $config = [PSCustomObject]@{
            prefix = 'AISec'
            workloads = [PSCustomObject]@{
                sensitivityLabels = [PSCustomObject]@{
                    labels            = @()
                    autoLabelPolicies = @()
                }
            }
        }
        $manifest = [PSCustomObject]@{
            labels = @([PSCustomObject]@{ name = 'AISec-Confidential'; sublabels = @() })
            autoLabelPolicies = @()
            publicationPolicy = $null
        }
        Remove-SensitivityLabels -Config $config -Manifest $manifest
        Should -Invoke Remove-Label -ModuleName SensitivityLabels
    }
}
