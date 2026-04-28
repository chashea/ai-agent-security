#Requires -Version 7.0

<#
.SYNOPSIS
    Shared interactive prompting functions for ai-agent-security.
#>

# Tests can set this to $true to bypass the TTY redirect check
$script:LabInteractiveBypassTtyCheck = $false

function Request-LabCloud {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()]
        [string]$DefaultCloud
    )

    if ([string]::IsNullOrWhiteSpace($DefaultCloud)) {
        $DefaultCloud = if ([string]::IsNullOrWhiteSpace($env:PURVIEW_CLOUD)) { 'commercial' } else { $env:PURVIEW_CLOUD.ToLowerInvariant() }
    }

    $allowedClouds = @('commercial', 'gcc')

    do {
        $cloudInput = Read-Host "Purview cloud [commercial/gcc] (default: $DefaultCloud)"
        if ([string]::IsNullOrWhiteSpace($cloudInput)) {
            $cloud = $DefaultCloud
        }
        else {
            $cloud = $cloudInput.Trim().ToLowerInvariant()
        }

        if ($allowedClouds -notcontains $cloud) {
            Write-Warning "Invalid cloud '$cloud'. Enter 'commercial' or 'gcc'."
            $cloud = $null
        }
    } while (-not $cloud)

    return $cloud
}

function Request-LabTenantId {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $tenantId = $null
    do {
        $defaultTenant = $env:PURVIEW_TENANT_ID
        $tenantPrompt = if ([string]::IsNullOrWhiteSpace($defaultTenant)) {
            'Tenant ID (GUID)'
        }
        else {
            "Tenant ID (GUID) (default: $defaultTenant)"
        }

        $tenantInput = Read-Host $tenantPrompt
        if ([string]::IsNullOrWhiteSpace($tenantInput)) {
            $tenantId = $defaultTenant
        }
        else {
            $tenantId = $tenantInput.Trim()
        }

        if ([string]::IsNullOrWhiteSpace($tenantId)) {
            Write-Warning 'Tenant ID is required unless -SkipAuth is used.'
        }
    } while ([string]::IsNullOrWhiteSpace($tenantId))

    return $tenantId
}

function Request-DeploymentMode {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $modes = @(
        @{ Number = 1; Name = 'full';          Description = 'Full (Foundry + Security controls)' }
        @{ Number = 2; Name = 'security-only'; Description = 'Security only (skip Foundry deployment)' }
        @{ Number = 3; Name = 'foundry-only';  Description = 'Foundry only (skip Purview security workloads)' }
    )

    Write-Host ''
    Write-Host 'Deployment mode:'
    foreach ($m in $modes) {
        Write-Host "  [$($m.Number)] $($m.Description)"
    }
    Write-Host ''

    $selectedMode = $null
    do {
        $modeInput = Read-Host 'Select mode [1/2/3] (default: 1)'
        if ([string]::IsNullOrWhiteSpace($modeInput)) {
            $selectedMode = 'full'
        }
        else {
            $match = $modes | Where-Object { $_.Number -eq [int]$modeInput -or $_.Name -eq $modeInput.Trim() }
            if ($match) {
                $selectedMode = $match.Name
            }
            else {
                Write-Warning "Invalid selection '$modeInput'. Enter 1, 2, or 3."
                $selectedMode = $null
            }
        }
    } while (-not $selectedMode)

    return $selectedMode
}

function Resolve-LabConfigPlaceholders {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ConfigPath
    )

    $samplePath = Join-Path $PSScriptRoot '..' 'config.sample.json'

    # Copy sample → config on first-time setup
    if (-not (Test-Path -Path $ConfigPath -PathType Leaf)) {
        if (-not (Test-Path -Path $samplePath -PathType Leaf)) {
            throw "config.sample.json not found at '$samplePath'. Cannot bootstrap config."
        }
        Copy-Item -Path $samplePath -Destination $ConfigPath -Force
        Write-LabLog "First-time setup: copied config.sample.json -> $ConfigPath" -Level Info
    }

    $content = Get-Content -Path $ConfigPath -Raw -Encoding UTF8

    # Detect which placeholders are present
    $needsDomain     = $content -like '*<TENANT_DOMAIN>*'
    $needsSubId      = $content -like '*<SUBSCRIPTION_ID>*'
    $needsPublisher  = $content -like '*<PUBLISHER_UPN>*'
    # USER_UPN is filled with the publisher value — no separate prompt

    # No placeholders → nothing to do
    if (-not $needsDomain -and -not $needsSubId -and -not $needsPublisher) {
        return
    }

    # Non-interactive guard (bypass flag lets Pester tests exercise prompts)
    $isNonInteractive = (-not $script:LabInteractiveBypassTtyCheck) -and
                        ([Console]::IsInputRedirected -or $env:CI -eq 'true')
    if ($isNonInteractive) {
        $missing = @()
        if ($needsDomain)    { $missing += '<TENANT_DOMAIN>' }
        if ($needsSubId)     { $missing += '<SUBSCRIPTION_ID>' }
        if ($needsPublisher) { $missing += '<PUBLISHER_UPN>' }
        throw "Config at '$ConfigPath' still contains placeholder(s): $($missing -join ', '). Edit the file manually before running in non-interactive mode."
    }

    Write-Host ''
    Write-Host 'First-time setup — replace config placeholders.'
    Write-Host ''

    $domain = $null
    if ($needsDomain) {
        do {
            $domain = (Read-Host 'Tenant domain (e.g., contoso.onmicrosoft.com)').Trim()
            if ([string]::IsNullOrWhiteSpace($domain) -or -not $domain.Contains('.')) {
                Write-Warning "Enter a valid domain (must contain '.')."
                $domain = $null
            }
        } while (-not $domain)
        $content = $content.Replace('<TENANT_DOMAIN>', $domain)
    }

    if ($needsSubId) {
        $subId = $null
        do {
            $subId = (Read-Host 'Azure subscription ID (GUID)').Trim()
            if ($subId -notmatch '^[0-9a-fA-F-]{36}$') {
                Write-Warning 'Enter a valid GUID (xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx).'
                $subId = $null
            }
        } while (-not $subId)
        $content = $content.Replace('<SUBSCRIPTION_ID>', $subId)
    }

    if ($needsPublisher) {
        $defaultPublisher = if ($domain) { "admin@$domain" } else { $null }
        $publisherPrompt = if ($defaultPublisher) {
            "Publisher / admin UPN (default: $defaultPublisher)"
        } else {
            'Publisher / admin UPN (used for APIM publisher email + default test user)'
        }
        $publisher = $null
        do {
            $upnEntry = (Read-Host $publisherPrompt).Trim()
            if ([string]::IsNullOrWhiteSpace($upnEntry) -and $defaultPublisher) {
                $publisher = $defaultPublisher
            } elseif ($upnEntry.Contains('@')) {
                $publisher = $upnEntry
            } else {
                Write-Warning "Enter a valid UPN containing '@'."
            }
        } while (-not $publisher)
        $content = $content.Replace('<PUBLISHER_UPN>', $publisher)
        # USER_UPN reuses the publisher value
        $content = $content.Replace('<USER_UPN>', $publisher)
    }

    Set-Content -Path $ConfigPath -Value $content -Encoding UTF8 -NoNewline
    Write-LabLog "Config placeholders resolved and saved to $ConfigPath" -Level Info
}

function Request-CreateTestUsersChoice {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $answer = (Read-Host 'Create new test users in this tenant? [y/N]').Trim().ToLowerInvariant()
    if ($answer -eq 'y' -or $answer -eq 'yes') {
        return 'create'
    }
    return 'existing'
}

Export-ModuleMember -Function @(
    'Request-LabCloud'
    'Request-LabTenantId'
    'Request-DeploymentMode'
    'Resolve-LabConfigPlaceholders'
    'Request-CreateTestUsersChoice'
)
