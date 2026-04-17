#Requires -Version 7.0

<#
.SYNOPSIS
    Prerequisites, authentication, and configuration module for ai-agent-security.
#>

$script:RequiredModules = @(
    'ExchangeOnlineManagement'
    'Microsoft.Graph.Authentication'
    'Microsoft.Graph.Users'
    'Microsoft.Graph.Groups'
    'Microsoft.Graph.Identity.SignIns'
)

$script:RequiredModulesFoundry = @(
    'Az.Accounts'
)

function Test-LabPrerequisites {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter()]
        [switch]$IncludeFoundry
    )

    $allPassed = $true

    # Check PowerShell 7+
    if ($PSVersionTable.PSVersion.Major -lt 7) {
        Write-Warning "PowerShell 7+ is required. Current version: $($PSVersionTable.PSVersion)"
        $allPassed = $false
    }
    else {
        Write-Verbose "PowerShell $($PSVersionTable.PSVersion) detected."
    }

    # Check required modules
    foreach ($moduleName in $script:RequiredModules) {
        $module = Get-Module -ListAvailable -Name $moduleName | Select-Object -First 1
        if (-not $module) {
            Write-Warning "Required module not installed: $moduleName"
            $allPassed = $false
        }
        else {
            Write-Verbose "Module found: $moduleName ($($module.Version))"
        }
    }

    # Check Foundry-specific modules when the foundry workload is enabled
    if ($IncludeFoundry) {
        foreach ($moduleName in $script:RequiredModulesFoundry) {
            $module = Get-Module -ListAvailable -Name $moduleName | Select-Object -First 1
            if (-not $module) {
                Write-Warning "Required module for Foundry workload not installed: $moduleName. Install with: Install-Module $moduleName -Scope CurrentUser"
                $allPassed = $false
            }
            else {
                Write-Verbose "Module found: $moduleName ($($module.Version))"
            }
        }

        # Check Python 3.11+ for Foundry SDK script
        $pythonCmd = if (Get-Command 'python3.12' -ErrorAction SilentlyContinue) { 'python3.12' }
                     elseif (Get-Command 'python3' -ErrorAction SilentlyContinue) { 'python3' }
                     else { $null }
        if (-not $pythonCmd) {
            Write-Warning 'Python 3.11+ is required for the Foundry agent SDK script. Install python3.12.'
            $allPassed = $false
        }
        else {
            $pyVersion = & $pythonCmd --version 2>&1
            Write-Verbose "Python found: $pyVersion"

            # Check required Python packages
            foreach ($pkg in @('azure-ai-projects', 'azure-search-documents')) {
                & $pythonCmd -m pip show $pkg 2>&1 | Out-Null
                if ($LASTEXITCODE -ne 0) {
                    Write-Warning "Python package '$pkg' not installed. Install with: $pythonCmd -m pip install -r scripts/requirements.txt"
                    $allPassed = $false
                }
                else {
                    Write-Verbose "Python package $pkg found."
                }
            }
        }

        # Check Azure Bicep CLI
        $bicepVersion = az bicep version 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Warning 'Azure Bicep CLI not found. Install with: az bicep install'
            $allPassed = $false
        }
        else {
            Write-Verbose "Bicep found: $bicepVersion"
        }
    }

    return $allPassed
}

function Connect-LabServices {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$TenantId,

        [Parameter()]
        [switch]$SkipExchange,

        [Parameter()]
        [switch]$SkipGraph,

        [Parameter()]
        [string[]]$GraphScopes,

        [Parameter()]
        [switch]$UseDeviceCode,

        [Parameter()]
        [switch]$ConnectAzure,

        [Parameter()]
        [string]$AzureSubscriptionId
    )

    if (-not $SkipExchange) {
        # Reuse an existing active EXO/IPPS session if one is already on disk. MSAL caches
        # refresh tokens in ~/.IdentityService (macOS/Linux), so subsequent Connect-* calls
        # within the token's lifetime complete silently. Only open a browser when there's
        # genuinely no active session.
        $ippsActive = $false
        try {
            $connections = @(Get-ConnectionInformation -ErrorAction SilentlyContinue)
            $ippsActive = [bool]($connections | Where-Object {
                $_.ConnectionUri -like '*ps.compliance.protection.outlook.com*' -and
                $_.TokenStatus -eq 'Active'
            })
        }
        catch { $ippsActive = $false }

        if ($ippsActive) {
            Write-Verbose "Reusing existing active IPPS session."
        }
        else {
            Write-Verbose "Connecting to Security & Compliance PowerShell (tenant: $TenantId)..."
            # Do NOT pass -CommandName * — the REST-based IPPSSession interprets the wildcard
            # literally and loads zero cmdlets. Omitting -CommandName loads the full cmdlet set.
            Connect-IPPSSession -ShowBanner:$false -WarningAction SilentlyContinue -ErrorAction Stop
        }
    }

    if (-not $SkipGraph) {
        if ($PSBoundParameters.ContainsKey('GraphScopes') -and $GraphScopes -and $GraphScopes.Count -gt 0) {
            $graphScopes = $GraphScopes
        }
        else {
            $graphScopes = @(
                'User.ReadWrite.All'
                'Group.ReadWrite.All'
                'Organization.Read.All'
                'Policy.ReadWrite.ConditionalAccess'
                'Policy.Read.All'
                'eDiscovery.ReadWrite.All'
                'AppCatalog.ReadWrite.All'
            )
        }

        # Reuse an existing Graph context if one is already present and belongs to the
        # requested tenant. Previously we called Disconnect-MgGraph unconditionally, which
        # wiped the in-memory context and forced a fresh browser / device code prompt every
        # run. MSAL will refresh the token silently if it's still in the disk cache.
        $existingContext = $null
        try { $existingContext = Get-MgContext -ErrorAction SilentlyContinue } catch { $existingContext = $null }

        $existingScopes = @()
        if ($existingContext -and $existingContext.Scopes) { $existingScopes = @($existingContext.Scopes) }
        $missingScopes = @($graphScopes | Where-Object { $existingScopes -notcontains $_ })

        $graphActive = $existingContext -and
                       -not [string]::IsNullOrWhiteSpace($existingContext.Account) -and
                       [string]$existingContext.TenantId -eq $TenantId -and
                       $missingScopes.Count -eq 0

        if ($graphActive) {
            Write-Verbose "Reusing existing Microsoft Graph context: $($existingContext.Account)"
        }
        else {
            if ($existingContext -and $missingScopes.Count -gt 0) {
                Write-Verbose "Existing Graph context missing scopes ($($missingScopes -join ', ')) — reconnecting."
            }
            Write-Verbose "Connecting to Microsoft Graph (tenant: $TenantId)..."
            $mgParams = @{
                TenantId    = $TenantId
                Scopes      = $graphScopes
                NoWelcome   = $true
                ErrorAction = 'Stop'
            }
            if ($UseDeviceCode) { $mgParams['UseDeviceCode'] = $true }
            Connect-MgGraph @mgParams
        }

        $graphContext = Get-MgContext
        if (-not $graphContext -or [string]::IsNullOrWhiteSpace($graphContext.Account)) {
            throw 'Microsoft Graph authentication did not produce a usable context.'
        }
    }

    if ($ConnectAzure) {
        $existingAz = $null
        try { $existingAz = Get-AzContext -ErrorAction SilentlyContinue } catch { Write-Verbose "Get-AzContext threw: $_" }
        if ($existingAz -and $existingAz.Account -and $existingAz.Tenant.Id -eq $TenantId) {
            Write-Verbose "Reusing existing Az context (account: $($existingAz.Account.Id), tenant: $TenantId)"
        }
        else {
            Write-Verbose "Connecting to Azure (tenant: $TenantId)..."
            $azConnectParams = @{ TenantId = $TenantId; ErrorAction = 'Stop' }
            if ($UseDeviceCode) { $azConnectParams['UseDeviceAuthentication'] = $true }
            Connect-AzAccount @azConnectParams | Out-Null
        }

        if (-not [string]::IsNullOrWhiteSpace($AzureSubscriptionId)) {
            Set-AzContext -SubscriptionId $AzureSubscriptionId -ErrorAction Stop | Out-Null
            Write-Verbose "Azure context set to subscription: $AzureSubscriptionId"
        }
    }
}

function Resolve-LabTenantDomain {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$ConfiguredDomain
    )

    $configured = $ConfiguredDomain.Trim().ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($configured)) {
        throw 'Configured domain is empty.'
    }

    try {
        $org = Invoke-MgGraphRequest -Method GET -Uri '/v1.0/organization?$select=verifiedDomains' -ErrorAction Stop
        $verifiedDomains = @()
        if ($org.value -and $org.value.Count -gt 0 -and $org.value[0].verifiedDomains) {
            $verifiedDomains = @($org.value[0].verifiedDomains)
        }

        $verifiedNames = @()
        foreach ($d in $verifiedDomains) {
            if ($d.name) { $verifiedNames += [string]$d.name }
        }

        if ($verifiedNames -contains $configured) {
            return $configured
        }

        $defaultDomain = $null
        foreach ($d in $verifiedDomains) {
            if ($d.isDefault -eq $true -and $d.name) {
                $defaultDomain = [string]$d.name
                break
            }
        }

        if ([string]::IsNullOrWhiteSpace($defaultDomain) -and $verifiedNames.Count -gt 0) {
            $defaultDomain = [string]$verifiedNames[0]
        }

        if (-not [string]::IsNullOrWhiteSpace($defaultDomain)) {
            return $defaultDomain.ToLowerInvariant()
        }
    }
    catch {
        Write-Verbose "Unable to resolve verified domains from Graph organization: $($_.Exception.Message)"
    }

    $context = Get-MgContext
    if ($context -and -not [string]::IsNullOrWhiteSpace($context.Account) -and $context.Account.Contains('@')) {
        $accountDomain = $context.Account.Split('@')[-1].ToLowerInvariant()
        if (-not [string]::IsNullOrWhiteSpace($accountDomain)) {
            return $accountDomain
        }
    }

    return $configured
}

function Get-LabUserByIdentity {
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)]
        [string]$Identity,

        [Parameter(Mandatory)]
        [string]$DefaultDomain
    )

    $trimmedIdentity = $Identity.Trim()
    if ([string]::IsNullOrWhiteSpace($trimmedIdentity)) {
        throw 'User identity cannot be empty.'
    }

    $candidateUpn = if ($trimmedIdentity.Contains('@')) {
        $trimmedIdentity
    }
    else {
        "$trimmedIdentity@$DefaultDomain"
    }

    $escapedCandidateUpn = $candidateUpn.Replace("'", "''")
    $byUpn = Get-MgUser -Filter "userPrincipalName eq '$escapedCandidateUpn'" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($byUpn) {
        return $byUpn
    }

    if (-not $trimmedIdentity.Contains('@')) {
        $escapedNickname = $trimmedIdentity.Replace("'", "''")
        $byNickname = Get-MgUser -Filter "mailNickname eq '$escapedNickname'" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($byNickname) {
            return $byNickname
        }
    }

    return $null
}

function Disconnect-LabServices {
    [CmdletBinding()]
    param()

    Write-Verbose 'Disconnecting from Security & Compliance PowerShell...'
    try {
        Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
    }
    catch {
        Write-Verbose "Exchange Online disconnect: $_"
    }

    Write-Verbose 'Disconnecting from Microsoft Graph...'
    try {
        Disconnect-MgGraph -ErrorAction SilentlyContinue
    }
    catch {
        Write-Verbose "Microsoft Graph disconnect: $_"
    }
}

function Import-LabConfig {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [ValidateScript({ Test-Path $_ -PathType Leaf })]
        [string]$ConfigPath
    )

    $fileSize = (Get-Item $ConfigPath).Length
    if ($fileSize -gt 1MB) {
        throw "Config file '$ConfigPath' is $([math]::Round($fileSize / 1MB, 1)) MB — exceeds 1 MB limit."
    }

    $raw = Get-Content -Path $ConfigPath -Raw
    $config = $raw | ConvertFrom-Json

    # Validate required fields
    $requiredFields = @('labName', 'prefix', 'domain')
    foreach ($field in $requiredFields) {
        if (-not $config.PSObject.Properties[$field]) {
            throw "Configuration is missing required field: '$field'"
        }
        if ([string]::IsNullOrWhiteSpace($config.$field)) {
            throw "Configuration field '$field' must not be empty."
        }
    }

    $configDir  = Split-Path $ConfigPath
    $schemaPath = if ($configDir) { Join-Path $configDir '_schema.json' } else { '_schema.json' }
    if (Test-Path $schemaPath) {
        Write-Verbose "Schema file found at $schemaPath. Schema validation is not yet implemented."
    }

    return $config
}

function Resolve-LabCloud {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()]
        [AllowEmptyString()]
        [string]$Cloud,

        [Parameter(Mandatory)]
        [PSCustomObject]$Config
    )

    $validClouds = @('commercial', 'gcc')
    $resolvedCloud = $null

    if (-not [string]::IsNullOrWhiteSpace($Cloud)) {
        $resolvedCloud = $Cloud.Trim().ToLowerInvariant()
    }
    elseif ($Config.PSObject.Properties['cloud'] -and -not [string]::IsNullOrWhiteSpace([string]$Config.cloud)) {
        $resolvedCloud = ([string]$Config.cloud).Trim().ToLowerInvariant()
    }
    else {
        $resolvedCloud = 'commercial'
    }

    if ($validClouds -notcontains $resolvedCloud) {
        throw "Unsupported cloud '$resolvedCloud'. Supported values: commercial, gcc."
    }

    return $resolvedCloud
}

function Export-LabManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$ManifestData,

        [Parameter(Mandatory)]
        [string]$OutputPath
    )

    # Add deployment timestamp
    $manifest = [ordered]@{
        generatedAt = (Get-Date -Format 'o')
        data        = $ManifestData
    }

    $json = $manifest | ConvertTo-Json -Depth 10
    $json | Set-Content -Path $OutputPath -Encoding utf8

    Write-Verbose "Manifest written to $OutputPath"
}

function Import-LabManifest {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [ValidateScript({ Test-Path $_ -PathType Leaf })]
        [string]$ManifestPath
    )

    $raw = Get-Content -Path $ManifestPath -Raw
    $manifest = $raw | ConvertFrom-Json

    if (-not (Test-LabManifestValidity -Manifest $manifest)) {
        Write-Verbose "Manifest at '$ManifestPath' has validation warnings."
    }

    return $manifest
}

function Get-LabStringArray {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter()]
        [object]$Value
    )

    if ($null -eq $Value) {
        return [string[]]@()
    }

    return [string[]]@(
        @($Value) |
            ForEach-Object { [string]$_ } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            ForEach-Object { $_.Trim() } |
            Sort-Object -Unique
    )
}

function Get-LabSupportedParameterName {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.CommandInfo[]]$Commands,

        [Parameter(Mandatory)]
        [string[]]$CandidateNames
    )

    foreach ($command in @($Commands)) {
        if (-not $command) {
            continue
        }

        foreach ($candidate in $CandidateNames) {
            if ($command.Parameters.ContainsKey($candidate)) {
                return [PSCustomObject]@{
                    commandName = $command.Name
                    parameter   = $candidate
                }
            }
        }
    }

    return $null
}

function Get-LabObjectProperty {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [object]$Object,

        [Parameter(Mandatory)]
        [string[]]$CandidateNames
    )

    foreach ($candidate in $CandidateNames) {
        if ($Object.PSObject.Properties.Name -contains $candidate) {
            return [PSCustomObject]@{
                found = $true
                name  = $candidate
                value = $Object.$candidate
            }
        }
    }

    return [PSCustomObject]@{
        found = $false
        name  = $null
        value = $null
    }
}

function Invoke-LabRetry {
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)]
        [scriptblock]$ScriptBlock,

        [Parameter()]
        [int]$MaxAttempts = 3,

        [Parameter()]
        [int]$DelaySeconds = 5,

        [Parameter()]
        [string]$OperationName = 'operation'
    )

    $lastError = $null
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            return (& $ScriptBlock)
        }
        catch {
            $lastError = $_
            if ($attempt -lt $MaxAttempts) {
                Write-Verbose "Invoke-LabRetry: $OperationName attempt $attempt/$MaxAttempts failed. Retrying in ${DelaySeconds}s..."
                Start-Sleep -Seconds $DelaySeconds
            }
        }
    }

    throw "Invoke-LabRetry: $OperationName failed after $MaxAttempts attempts. Last error: $lastError"
}

function Test-LabConfigValidity {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Config
    )

    $isValid = $true

    if (-not $Config.PSObject.Properties['workloads']) {
        Write-Warning 'Config has no workloads section.'
        return $false
    }

    $workloadRequirements = @{
        'sensitivityLabels'         = @('labels')
        'testUsers'                 = @('users')
        'conditionalAccess'         = @('policies')
        'mdca'                      = @('policies')
    }

    foreach ($workloadName in $workloadRequirements.Keys) {
        if (-not $Config.workloads.PSObject.Properties[$workloadName]) {
            continue
        }

        $workload = $Config.workloads.$workloadName
        if (-not $workload -or -not $workload.PSObject.Properties['enabled'] -or -not [bool]$workload.enabled) {
            continue
        }

        foreach ($requiredField in $workloadRequirements[$workloadName]) {
            if (-not $workload.PSObject.Properties[$requiredField]) {
                Write-Warning "Workload '$workloadName' is enabled but missing required field '$requiredField'."
                $isValid = $false
            }
            elseif ($null -eq $workload.$requiredField) {
                Write-Warning "Workload '$workloadName' has null '$requiredField' field."
                $isValid = $false
            }
            elseif ($workload.$requiredField -is [array] -and $workload.$requiredField.Count -eq 0) {
                Write-Warning "Workload '$workloadName' has empty '$requiredField' array."
                $isValid = $false
            }
        }
    }

    $guidPattern = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
    $foundry = $Config.workloads.foundry
    if ($foundry -and $foundry.PSObject.Properties['subscriptionId'] -and
        $foundry.subscriptionId -and $foundry.subscriptionId -notmatch $guidPattern) {
        Write-LabLog -Message "Foundry subscriptionId '$($foundry.subscriptionId)' is not a valid GUID." -Level Warning
        $isValid = $false
    }

    return $isValid
}

function Test-LabManifestValidity {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Manifest
    )

    $isValid = $true

    if (-not $Manifest.PSObject.Properties['generatedAt']) {
        Write-Warning 'Manifest is missing generatedAt timestamp.'
        $isValid = $false
    }

    if (-not $Manifest.PSObject.Properties['data']) {
        Write-Warning 'Manifest is missing data section.'
        $isValid = $false
    }

    return $isValid
}

Export-ModuleMember -Function @(
    'Test-LabPrerequisites'
    'Connect-LabServices'
    'Resolve-LabTenantDomain'
    'Get-LabUserByIdentity'
    'Disconnect-LabServices'
    'Import-LabConfig'
    'Resolve-LabCloud'
    'Export-LabManifest'
    'Import-LabManifest'
    'Get-LabStringArray'
    'Get-LabSupportedParameterName'
    'Get-LabObjectProperty'
    'Invoke-LabRetry'
    'Test-LabConfigValidity'
    'Test-LabManifestValidity'
)
