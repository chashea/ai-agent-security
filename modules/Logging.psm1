#Requires -Version 7.0

<#
.SYNOPSIS
    Structured logging module for purview-lab-deployer.
#>

$script:LogPrefix = 'PurviewLab'
$script:LogFile = $null

function Initialize-LabLogging {
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$LogDirectory = (Join-Path $PSScriptRoot '..' 'logs'),

        [Parameter()]
        [string]$Prefix = 'PurviewLab'
    )

    $script:LogPrefix = $Prefix

    if (-not (Test-Path $LogDirectory)) {
        New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null
    }

    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $script:LogFile = Join-Path $LogDirectory "${Prefix}_${timestamp}.log"

    Start-Transcript -Path $script:LogFile -Append | Out-Null

    Write-LabLog -Message "Logging initialized. Log file: $($script:LogFile)" -Level Info

    Clear-LabOldLogs -LogDirectory $LogDirectory
}

function Write-LabLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Message,

        [Parameter()]
        [ValidateSet('Info', 'Warning', 'Error', 'Success')]
        [string]$Level = 'Info'
    )

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $formatted = "[$timestamp] [$($script:LogPrefix)] [$Level] $Message"

    $color = switch ($Level) {
        'Info'    { 'Cyan' }
        'Warning' { 'Yellow' }
        'Error'   { 'Red' }
        'Success' { 'Green' }
    }

    Write-Host $formatted -ForegroundColor $color
}

function Write-LabStep {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$StepName,

        [Parameter(Mandatory, Position = 1)]
        [string]$Description
    )

    $separator = '=' * 60
    Write-Host ''
    Write-Host $separator -ForegroundColor White
    Write-LabLog -Message "STEP: $StepName - $Description" -Level Info
    Write-Host $separator -ForegroundColor White
    Write-Host ''
}

function Clear-LabOldLogs {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter()]
        [string]$LogDirectory = (Join-Path $PSScriptRoot '..' 'logs'),

        [Parameter()]
        [int]$RetentionDays = 30
    )

    if (-not (Test-Path $LogDirectory)) {
        return
    }

    $cutoff = (Get-Date).AddDays(-$RetentionDays)
    Get-ChildItem -Path $LogDirectory -Filter '*.log' -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt $cutoff } |
        ForEach-Object {
            if ($PSCmdlet.ShouldProcess($_.FullName, 'Remove old log file')) {
                Remove-Item $_.FullName -Force
                Write-Verbose "Removed old log: $($_.Name)"
            }
        }
}

function Complete-LabLogging {
    [CmdletBinding()]
    param()

    Write-LabLog -Message 'Logging complete. Stopping transcript.' -Level Info

    try {
        Stop-Transcript | Out-Null
    }
    catch {
        $null = $_ # Transcript may not be running; safe to ignore
    }
}

Export-ModuleMember -Function @(
    'Initialize-LabLogging'
    'Write-LabLog'
    'Write-LabStep'
    'Complete-LabLogging'
    'Clear-LabOldLogs'
)
