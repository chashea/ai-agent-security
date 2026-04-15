#Requires -Version 7.0
#Requires -Modules Pester

BeforeAll {
    $loggingPath = Join-Path $PSScriptRoot '..' 'modules' 'Logging.psm1'
    Import-Module $loggingPath -Force

    $prereqPath = Join-Path $PSScriptRoot '..' 'modules' 'Prerequisites.psm1'
    Import-Module $prereqPath -Force

    $infraPath = Join-Path $PSScriptRoot '..' 'modules' 'FoundryInfra.psm1'
    Import-Module $infraPath -Force

    $modulePath = Join-Path $PSScriptRoot '..' 'modules' 'Agent365.psm1'
    Import-Module $modulePath -Force
}

Describe 'Publish-FoundryAgentAsDigitalWorker' {
    BeforeEach {
        Mock Get-FoundryDataToken { return 'mock-token' } -ModuleName Agent365
        Mock Invoke-LabRetry { & $ScriptBlock } -ModuleName Agent365
    }

    It 'Submits digital worker for each agent' {
        Mock Invoke-WebRequest {
            [PSCustomObject]@{
                StatusCode = 200
                Content    = '{"status": "ok"}'
            }
        } -ModuleName Agent365

        $result = Publish-FoundryAgentAsDigitalWorker `
            -Location 'eastus' `
            -SubscriptionId 'sub-123' `
            -ResourceGroup 'rg-test' `
            -AccountName 'acct' `
            -ProjectName 'proj' `
            -ApplicationName 'TestAgent' `
            -BotId 'bot-001'

        $result.status | Should -Be 'requested'
        $result.applicationName | Should -Be 'TestAgent'
        $result.botId | Should -Be 'bot-001'
    }

    It 'Handles version already exists gracefully' {
        Mock Invoke-WebRequest {
            [PSCustomObject]@{
                StatusCode = 409
                Content    = '{"error": {"code": "UserError", "message": "version already exists"}}'
            }
        } -ModuleName Agent365

        $result = Publish-FoundryAgentAsDigitalWorker `
            -Location 'eastus' `
            -SubscriptionId 'sub-123' `
            -ResourceGroup 'rg-test' `
            -AccountName 'acct' `
            -ProjectName 'proj' `
            -ApplicationName 'TestAgent' `
            -BotId 'bot-001'

        $result.status | Should -Be 'already-published'
    }

    It 'Retries on transient HTTP errors (503)' {
        $script:callCount = 0
        Mock Invoke-LabRetry {
            param([scriptblock]$ScriptBlock)
            & $ScriptBlock
        } -ModuleName Agent365

        Mock Invoke-WebRequest {
            [PSCustomObject]@{
                StatusCode = 200
                Content    = '{"status": "ok"}'
            }
        } -ModuleName Agent365

        $result = Publish-FoundryAgentAsDigitalWorker `
            -Location 'eastus' `
            -SubscriptionId 'sub-123' `
            -ResourceGroup 'rg-test' `
            -AccountName 'acct' `
            -ProjectName 'proj' `
            -ApplicationName 'RetryAgent' `
            -BotId 'bot-002'

        $result.status | Should -Be 'requested'
        Should -Invoke Invoke-LabRetry -Times 1 -ModuleName Agent365
    }
}

Describe 'Publish-FoundryAgentsAsDigitalWorkers' {
    BeforeEach {
        Mock Get-FoundryDataToken { return 'mock-token' } -ModuleName Agent365
        Mock Invoke-LabRetry { & $ScriptBlock } -ModuleName Agent365
        Mock Invoke-WebRequest {
            [PSCustomObject]@{ StatusCode = 200; Content = '{"status":"ok"}' }
        } -ModuleName Agent365
    }

    It 'Skips when agent365 is disabled' {
        $config = [PSCustomObject]@{
            labName = 'test'
            workloads = [PSCustomObject]@{
                foundry = [PSCustomObject]@{
                    accountName = 'acct'
                    projectName = 'proj'
                    agent365    = [PSCustomObject]@{ enabled = $false }
                }
            }
        }
        $manifest = [PSCustomObject]@{
            agents         = @([PSCustomObject]@{ name = 'Agent1' })
            subscriptionId = 'sub-1'
            resourceGroup  = 'rg-1'
            location       = 'eastus'
        }
        $result = Publish-FoundryAgentsAsDigitalWorkers -Config $config -FoundryManifest $manifest
        $result | Should -HaveCount 0
    }
}
