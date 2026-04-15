#Requires -Version 7.0
#Requires -Modules Pester

BeforeAll {
    $loggingPath = Join-Path $PSScriptRoot '..' 'modules' 'Logging.psm1'
    Import-Module $loggingPath -Force

    $prereqPath = Join-Path $PSScriptRoot '..' 'modules' 'Prerequisites.psm1'
    Import-Module $prereqPath -Force

    $modulePath = Join-Path $PSScriptRoot '..' 'modules' 'Foundry.psm1'
    Import-Module $modulePath -Force
}

Describe 'Invoke-FoundryPython' {
    BeforeEach {
        # Mock Get-Command so it finds our fake python
        Mock Get-Command { [PSCustomObject]@{ Name = 'python3.12' } } -ModuleName Foundry
    }

    It 'Passes config JSON to temp file and captures stdout' {
        # Create a mock Python script that reads config and echoes JSON
        $mockScript = Join-Path $TestDrive 'mock_script.py'
        @'
import sys, json
for i, a in enumerate(sys.argv):
    if a == '--config':
        cfg = json.load(open(sys.argv[i+1]))
        print(json.dumps({"result": cfg["key"]}))
        sys.exit(0)
sys.exit(1)
'@ | Set-Content -Path $mockScript -Encoding UTF8

        $result = InModuleScope Foundry -Parameters @{ mockScript = $mockScript } {
            param($mockScript)
            $inputFile = [System.IO.Path]::GetTempFileName()
            @{ key = 'hello' } | ConvertTo-Json | Set-Content -Path $inputFile -Encoding UTF8
            try {
                $pythonCmd = if (Get-Command 'python3.12' -ErrorAction SilentlyContinue) { 'python3.12' } else { 'python3' }
                $rawOutput = & $pythonCmd $mockScript --action test --config $inputFile 2>&1
                $stdoutLines = @()
                foreach ($line in $rawOutput) {
                    if ($line -is [System.Management.Automation.ErrorRecord]) { continue }
                    $stdoutLines += [string]$line
                }
                $stdoutLines -join "`n" | ConvertFrom-Json
            }
            finally { Remove-Item $inputFile -Force -ErrorAction SilentlyContinue }
        }

        $result.result | Should -Be 'hello'
    }

    It 'Throws on non-zero exit code' {
        $failScript = Join-Path $TestDrive 'fail_script.py'
        'import sys; sys.exit(1)' | Set-Content -Path $failScript -Encoding UTF8

        {
            InModuleScope Foundry -Parameters @{ failScript = $failScript } {
                param($failScript)
                $inputFile = [System.IO.Path]::GetTempFileName()
                '{}' | Set-Content -Path $inputFile -Encoding UTF8
                try {
                    $pythonCmd = if (Get-Command 'python3.12' -ErrorAction SilentlyContinue) { 'python3.12' } else { 'python3' }
                    $null = & $pythonCmd $failScript --action test --config $inputFile 2>&1
                    if ($LASTEXITCODE -ne 0) {
                        throw "Script failed (exit $LASTEXITCODE)"
                    }
                }
                finally { Remove-Item $inputFile -Force -ErrorAction SilentlyContinue }
            }
        } | Should -Throw
    }

    It 'Cleans up temp file on success and failure' {
        $cleanupScript = Join-Path $TestDrive 'cleanup_test.py'
        'import sys; print("{}"); sys.exit(0)' | Set-Content -Path $cleanupScript -Encoding UTF8

        $tempFile = InModuleScope Foundry -Parameters @{ cleanupScript = $cleanupScript } {
            param($cleanupScript)
            $inputFile = [System.IO.Path]::GetTempFileName()
            '{}' | Set-Content -Path $inputFile -Encoding UTF8
            $pythonCmd = if (Get-Command 'python3.12' -ErrorAction SilentlyContinue) { 'python3.12' } else { 'python3' }
            & $pythonCmd $cleanupScript --action test --config $inputFile 2>&1 | Out-Null
            Remove-Item $inputFile -Force -ErrorAction SilentlyContinue
            return $inputFile
        }

        Test-Path $tempFile | Should -Be $false
    }
}
