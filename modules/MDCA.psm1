#Requires -Version 7.0

<#
.SYNOPSIS
    Defender for Cloud Apps (MDCA) workload module for ai-agent-security.
.DESCRIPTION
    Creates session policies (via Conditional Access App Control), activity
    alert policies (via MDCA REST API), and OAuth app governance (service
    principal tagging via Graph) for Azure AI Foundry agents.

    Session policies use CA policies with CAAC session controls — fully
    programmatic via Graph SDK. Activity and app governance policies require
    the MDCA REST API (portalUrl in config). If portalUrl is empty, those
    policy types are skipped with an advisory — graceful degradation.
#>

$script:MdcaApiVersion = 'v1'

# ─── Graph Scope Validation ──────────────────────────────────────────────────

function Test-MdcaGraphScopes {
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    $context = Get-MgContext -ErrorAction SilentlyContinue
    if (-not $context) {
        Write-LabLog -Message 'MDCA: no Microsoft Graph context found. Connect-MgGraph required.' -Level Warning
        return $false
    }

    $grantedScopes = @($context.Scopes)
    $requiredScopes = @('Policy.ReadWrite.ConditionalAccess', 'Policy.Read.All')
    $missingScopes = @($requiredScopes | Where-Object { $_ -notin $grantedScopes })

    if ($missingScopes.Count -gt 0) {
        Write-LabLog -Message "MDCA: missing Graph scopes: $($missingScopes -join ', '). Reconnect with required scopes." -Level Warning
        return $false
    }
    return $true
}

# ─── MDCA REST API Helper ────────────────────────────────────────────────────

function Invoke-MdcaApi {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)] [string]$PortalUrl,
        [Parameter(Mandatory)] [string]$Method,
        [Parameter(Mandatory)] [string]$Path,
        [Parameter()] [hashtable]$Body
    )

    $uri = "$($PortalUrl.TrimEnd('/'))/api/$($script:MdcaApiVersion)/$($Path.TrimStart('/'))"

    $params = @{
        Method  = $Method
        Uri     = $uri
        Headers = @{ 'Content-Type' = 'application/json' }
    }

    if ($Body) {
        $params['Body'] = ($Body | ConvertTo-Json -Depth 10)
    }

    try {
        $response = Invoke-MgGraphRequest @params -ErrorAction Stop
        return $response
    }
    catch {
        Write-LabLog -Message "MDCA API $Method $Path failed: $($_.Exception.Message)" -Level Warning
        return $null
    }
}

# ─── Portal URL Auto-Discovery ────────────────────────────────────────────────

function Resolve-MdcaPortalUrl {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    try {
        $context = Get-MgContext -ErrorAction SilentlyContinue
        if (-not $context -or [string]::IsNullOrWhiteSpace($context.TenantId)) { return '' }

        $tenantId = [string]$context.TenantId

        # Try tenant-ID-based URL first (most reliable)
        $candidateUrls = @(
            "https://$tenantId.portal.cloudappsecurity.com"
            "https://$tenantId.us.portal.cloudappsecurity.com"
        )

        # Try to get the tenant's primary domain for a domain-based URL
        try {
            $org = Get-MgOrganization -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($org -and $org.VerifiedDomains) {
                $primaryDomain = ($org.VerifiedDomains | Where-Object { $_.IsDefault -eq $true }).Name
                if ($primaryDomain) {
                    $tenantName = ($primaryDomain -split '\.')[0]
                    $candidateUrls = @("https://$tenantName.portal.cloudappsecurity.com") + $candidateUrls
                }
            }
        }
        catch { $null = $_ }

        # Validate each candidate with a lightweight request
        foreach ($url in $candidateUrls) {
            try {
                $testUri = "$url/api/v1/alerts/?`$top=1"
                $null = Invoke-MgGraphRequest -Method GET -Uri $testUri -ErrorAction Stop
                Write-LabLog -Message "MDCA: auto-discovered portal URL: $url" -Level Success
                return $url
            }
            catch {
                # Try next candidate
                continue
            }
        }

        Write-LabLog -Message 'MDCA: portal URL auto-discovery failed — set workloads.mdca.portalUrl manually.' -Level Warning
        return ''
    }
    catch {
        Write-LabLog -Message "MDCA: portal URL discovery error: $($_.Exception.Message)" -Level Warning
        return ''
    }
}

# ─── Agent App ID Resolution ─────────────────────────────────────────────────

function Resolve-AgentAppIds {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter()] [PSCustomObject]$FoundryManifest,
        [Parameter()] [string]$Prefix
    )

    $appIds = [System.Collections.Generic.List[string]]::new()

    # Try manifest first (bot service app registrations)
    if ($FoundryManifest -and $FoundryManifest.PSObject.Properties['botServices'] -and $FoundryManifest.botServices.PSObject.Properties['bots']) {
        foreach ($bot in @($FoundryManifest.botServices.bots)) {
            if ($bot.PSObject.Properties['appClientId'] -and -not [string]::IsNullOrWhiteSpace([string]$bot.appClientId)) {
                $appIds.Add([string]$bot.appClientId)
            }
        }
    }

    # Fallback: look up Entra apps by prefix
    if ($appIds.Count -eq 0 -and -not [string]::IsNullOrWhiteSpace($Prefix)) {
        try {
            $apps = Get-MgApplication -Filter "startswith(displayName, '$Prefix-')" -Property 'AppId,DisplayName' -ErrorAction SilentlyContinue
            foreach ($app in @($apps)) {
                if ($app.DisplayName -match '-Bot$') {
                    $appIds.Add([string]$app.AppId)
                }
            }
        }
        catch {
            Write-LabLog -Message "MDCA: could not look up agent apps by prefix: $($_.Exception.Message)" -Level Warning
        }
    }

    return @($appIds)
}

# ─── Session Policy (CA + CAAC) ──────────────────────────────────────────────

function New-MdcaSessionPolicy {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [string]$SessionControlType,
        [Parameter()] [string]$Description,
        [Parameter()] [string[]]$TargetAppIds
    )

    # Check if already exists
    $existing = Get-MgIdentityConditionalAccessPolicy -Filter "displayName eq '$Name'" -ErrorAction SilentlyContinue |
        Select-Object -First 1

    if ($existing) {
        Write-LabLog -Message "MDCA session policy already exists: $Name" -Level Info
        return @{ name = $Name; id = $existing.Id; type = 'session'; sessionControlType = $SessionControlType; status = 'existing' }
    }

    # Map session control type
    $caacType = switch ($SessionControlType) {
        'monitorOnly'    { 'monitorOnly' }
        'blockDownloads' { 'blockDownloads' }
        default          { 'monitorOnly' }
    }

    # Build CA policy with CAAC session controls
    $conditions = @{
        Applications = @{ IncludeApplications = if ($TargetAppIds -and $TargetAppIds.Count -gt 0) { @($TargetAppIds) } else { @('All') } }
        Users        = @{ IncludeUsers = @('All') }
    }

    $bodyParams = @{
        DisplayName     = $Name
        State           = 'enabledForReportingButNotEnforced'
        Conditions      = $conditions
        GrantControls   = @{ Operator = 'OR'; BuiltInControls = @('mfa') }
        SessionControls = @{
            CloudAppSecurity = @{
                IsEnabled            = $true
                CloudAppSecurityType = $caacType
            }
        }
    }

    if (-not $PSCmdlet.ShouldProcess($Name, "Create MDCA session policy (CAAC: $caacType)")) {
        return @{ name = $Name; id = $null; type = 'session'; sessionControlType = $SessionControlType; status = 'whatif' }
    }

    try {
        $created = New-MgIdentityConditionalAccessPolicy -BodyParameter $bodyParams -ErrorAction Stop
        $descNote = if ($Description) { " — $Description" } else { '' }
        Write-LabLog -Message "MDCA: created session policy: $Name (CAAC: $caacType, state: report-only)$descNote" -Level Success
        return @{ name = $Name; id = $created.Id; type = 'session'; sessionControlType = $SessionControlType; status = 'created' }
    }
    catch {
        Write-LabLog -Message "MDCA: error creating session policy ${Name}: $($_.Exception.Message)" -Level Warning
        return @{ name = $Name; id = $null; type = 'session'; sessionControlType = $SessionControlType; status = 'failed' }
    }
}

# ─── Activity Policy (MDCA REST API) ─────────────────────────────────────────

function New-MdcaActivityPolicy {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [string]$PortalUrl,
        [Parameter()] [string]$Description,
        [Parameter()] [string]$Severity = 'MEDIUM'
    )

    # Check existing via MDCA API
    $existingPolicies = Invoke-MdcaApi -PortalUrl $PortalUrl -Method GET -Path 'policies/'
    if ($existingPolicies -and $existingPolicies.data) {
        $match = $existingPolicies.data | Where-Object { $_.name -eq $Name } | Select-Object -First 1
        if ($match) {
            Write-LabLog -Message "MDCA activity policy already exists: $Name" -Level Info
            return @{ name = $Name; id = [string]$match._id; type = 'activity'; status = 'existing' }
        }
    }

    $policyBody = @{
        name        = $Name
        description = if ($Description) { $Description } else { '' }
        policyType  = 'POLICY_ACTIVITY'
        severity    = $Severity.ToUpper()
        enabled     = $true
        filters     = @{
            source = @{ service = @(20940) }  # Azure resource (Foundry agents)
        }
    }

    if (-not $PSCmdlet.ShouldProcess($Name, "Create MDCA activity policy (severity: $Severity)")) {
        return @{ name = $Name; id = $null; type = 'activity'; status = 'whatif' }
    }

    $result = Invoke-MdcaApi -PortalUrl $PortalUrl -Method POST -Path 'policies/' -Body $policyBody
    if ($result -and $result._id) {
        Write-LabLog -Message "MDCA: created activity policy: $Name" -Level Success
        return @{ name = $Name; id = [string]$result._id; type = 'activity'; status = 'created' }
    }
    else {
        Write-LabLog -Message "MDCA: failed to create activity policy: $Name" -Level Warning
        return @{ name = $Name; id = $null; type = 'activity'; status = 'failed' }
    }
}

# ─── OAuth App Tagging ────────────────────────────────────────────────────────

function Set-AgentAppTags {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([System.Collections.Generic.List[hashtable]])]
    param(
        [Parameter(Mandatory)] [string[]]$AppIds,
        [Parameter()] [string]$Tag = 'AI Agent'
    )

    $tagged = [System.Collections.Generic.List[hashtable]]::new()

    foreach ($appId in $AppIds) {
        try {
            $sp = Get-MgServicePrincipal -Filter "appId eq '$appId'" -Property 'Id,DisplayName,Tags' -ErrorAction SilentlyContinue |
                Select-Object -First 1

            if (-not $sp) {
                Write-LabLog -Message "MDCA: service principal not found for appId $appId" -Level Warning
                continue
            }

            $currentTags = @($sp.Tags)
            if ($Tag -in $currentTags) {
                Write-LabLog -Message "MDCA: SP '$($sp.DisplayName)' already tagged '$Tag'" -Level Info
                $tagged.Add(@{ displayName = $sp.DisplayName; appId = $appId; servicePrincipalId = $sp.Id; status = 'existing' })
                continue
            }

            if (-not $PSCmdlet.ShouldProcess("SP '$($sp.DisplayName)'", "Add tag '$Tag'")) {
                $tagged.Add(@{ displayName = $sp.DisplayName; appId = $appId; servicePrincipalId = $sp.Id; status = 'whatif' })
                continue
            }

            $newTags = @($currentTags) + @($Tag)
            Update-MgServicePrincipal -ServicePrincipalId $sp.Id -Tags $newTags -ErrorAction Stop
            Write-LabLog -Message "MDCA: tagged SP '$($sp.DisplayName)' with '$Tag'" -Level Success
            $tagged.Add(@{ displayName = $sp.DisplayName; appId = $appId; servicePrincipalId = $sp.Id; status = 'created' })
        }
        catch {
            Write-LabLog -Message "MDCA: error tagging SP for appId ${appId}: $($_.Exception.Message)" -Level Warning
        }
    }

    return $tagged
}

function Remove-AgentAppTags {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter()] [array]$TaggedServicePrincipals,
        [Parameter()] [string]$Tag = 'AI Agent'
    )

    foreach ($entry in @($TaggedServicePrincipals)) {
        $spId = if ($entry -is [hashtable]) { $entry['servicePrincipalId'] }
                elseif ($entry.PSObject.Properties['servicePrincipalId']) { [string]$entry.servicePrincipalId }
                else { $null }
        $displayName = if ($entry -is [hashtable]) { $entry['displayName'] }
                       elseif ($entry.PSObject.Properties['displayName']) { [string]$entry.displayName }
                       else { 'unknown' }

        if (-not $spId) { continue }

        try {
            $sp = Get-MgServicePrincipal -ServicePrincipalId $spId -Property 'Tags' -ErrorAction SilentlyContinue
            if (-not $sp) { continue }

            $currentTags = @($sp.Tags)
            if ($Tag -notin $currentTags) { continue }

            if (-not $PSCmdlet.ShouldProcess("SP '$displayName'", "Remove tag '$Tag'")) { continue }

            $newTags = @($currentTags | Where-Object { $_ -ne $Tag })
            Update-MgServicePrincipal -ServicePrincipalId $spId -Tags $newTags -ErrorAction Stop
            Write-LabLog -Message "MDCA: removed tag '$Tag' from SP '$displayName'" -Level Success
        }
        catch {
            Write-LabLog -Message "MDCA: error removing tag from SP ${displayName}: $($_.Exception.Message)" -Level Warning
        }
    }
}

# ─── Deploy ──────────────────────────────────────────────────────────────────

function Deploy-MDCA {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Config,

        [Parameter()]
        [PSCustomObject]$FoundryManifest
    )

    $prefix    = [string]$Config.prefix
    $mdcaConf  = $Config.workloads.mdca
    $portalUrl = if ($mdcaConf.PSObject.Properties['portalUrl'] -and -not [string]::IsNullOrWhiteSpace([string]$mdcaConf.portalUrl)) {
                     [string]$mdcaConf.portalUrl
                 } else { '' }

    # Auto-discover portal URL if not configured
    if ([string]::IsNullOrWhiteSpace($portalUrl)) {
        $portalUrl = Resolve-MdcaPortalUrl
    }

    $result = @{
        caPolicies              = @()
        mdcaPolicies            = @()
        taggedServicePrincipals = @()
    }

    # Validate Graph scopes
    if (-not (Test-MdcaGraphScopes)) {
        Write-LabLog -Message 'MDCA: skipping all policies due to missing Graph scopes.' -Level Warning
        return $result
    }

    # Resolve agent app IDs for session policy targeting and SP tagging
    $agentAppIds = Resolve-AgentAppIds -FoundryManifest $FoundryManifest -Prefix $prefix
    if ($agentAppIds.Count -eq 0) {
        Write-LabLog -Message 'MDCA: no agent app IDs found — session policies will target all apps, SP tagging skipped.' -Level Warning
    }

    $caPolicies    = [System.Collections.Generic.List[hashtable]]::new()
    $mdcaPolicies  = [System.Collections.Generic.List[hashtable]]::new()
    $taggedSPs     = [System.Collections.Generic.List[hashtable]]::new()

    foreach ($policy in @($mdcaConf.policies)) {
        $name = "$prefix-$($policy.name)"
        $type = [string]$policy.type

        switch ($type) {
            'session' {
                $sessionType = if ($policy.PSObject.Properties['sessionControlType']) { [string]$policy.sessionControlType } else { 'monitorOnly' }
                $description = if ($policy.PSObject.Properties['description']) { [string]$policy.description } else { '' }
                $policyResult = New-MdcaSessionPolicy -Name $name -SessionControlType $sessionType -Description $description -TargetAppIds $agentAppIds -WhatIf:$WhatIfPreference
                $caPolicies.Add($policyResult)
            }
            'activity' {
                if ([string]::IsNullOrWhiteSpace($portalUrl)) {
                    Write-LabLog -Message "MDCA: skipping activity policy '$name' — portalUrl not configured. Set workloads.mdca.portalUrl to enable." -Level Warning
                    $mdcaPolicies.Add(@{ name = $name; id = $null; type = 'activity'; status = 'skipped' })
                    continue
                }
                $severity = if ($policy.PSObject.Properties['severity']) { [string]$policy.severity } else { 'medium' }
                $description = if ($policy.PSObject.Properties['description']) { [string]$policy.description } else { '' }
                $policyResult = New-MdcaActivityPolicy -Name $name -PortalUrl $portalUrl -Description $description -Severity $severity -WhatIf:$WhatIfPreference
                $mdcaPolicies.Add($policyResult)
            }
            'appGovernance' {
                # Tag service principals first (works without portalUrl)
                if ($agentAppIds.Count -gt 0) {
                    $tagResults = Set-AgentAppTags -AppIds $agentAppIds -WhatIf:$WhatIfPreference
                    foreach ($t in @($tagResults)) { $taggedSPs.Add($t) }
                }

                # App governance policy requires portalUrl
                if ([string]::IsNullOrWhiteSpace($portalUrl)) {
                    Write-LabLog -Message "MDCA: skipping app governance policy '$name' — portalUrl not configured. SP tagging completed via Graph." -Level Warning
                    $mdcaPolicies.Add(@{ name = $name; id = $null; type = 'appGovernance'; status = 'skipped' })
                    continue
                }

                $severity = if ($policy.PSObject.Properties['severity']) { [string]$policy.severity } else { 'high' }
                $description = if ($policy.PSObject.Properties['description']) { [string]$policy.description } else { '' }
                $govBody = @{
                    name        = $name
                    description = $description
                    policyType  = 'POLICY_APP_GOVERNANCE'
                    severity    = $severity.ToUpper()
                    enabled     = $true
                    filters     = @{ tag = @{ eq = @('AI Agent') } }
                }

                if (-not $PSCmdlet.ShouldProcess($name, "Create MDCA app governance policy")) {
                    $mdcaPolicies.Add(@{ name = $name; id = $null; type = 'appGovernance'; status = 'whatif' })
                    continue
                }

                $govResult = Invoke-MdcaApi -PortalUrl $portalUrl -Method POST -Path 'policies/' -Body $govBody
                if ($govResult -and $govResult._id) {
                    Write-LabLog -Message "MDCA: created app governance policy: $name" -Level Success
                    $mdcaPolicies.Add(@{ name = $name; id = [string]$govResult._id; type = 'appGovernance'; status = 'created' })
                }
                else {
                    Write-LabLog -Message "MDCA: failed to create app governance policy: $name" -Level Warning
                    $mdcaPolicies.Add(@{ name = $name; id = $null; type = 'appGovernance'; status = 'failed' })
                }
            }
            default {
                Write-LabLog -Message "MDCA: unknown policy type '$type' for '$name' — skipping." -Level Warning
            }
        }
    }

    $result.caPolicies              = @($caPolicies)
    $result.mdcaPolicies            = @($mdcaPolicies)
    $result.taggedServicePrincipals = @($taggedSPs)

    $totalCreated = @($caPolicies | Where-Object { $_.status -eq 'created' }).Count + @($mdcaPolicies | Where-Object { $_.status -eq 'created' }).Count
    Write-LabLog -Message "MDCA: $totalCreated policy/policies created, $($taggedSPs.Count) service principal(s) tagged." -Level Success
    return $result
}

# ─── Remove ──────────────────────────────────────────────────────────────────

function Remove-MDCA {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Config,

        [Parameter()]
        [PSCustomObject]$Manifest
    )

    $prefix    = [string]$Config.prefix
    $mdcaConf  = $Config.workloads.mdca
    $portalUrl = if ($mdcaConf.PSObject.Properties['portalUrl'] -and -not [string]::IsNullOrWhiteSpace([string]$mdcaConf.portalUrl)) {
                     [string]$mdcaConf.portalUrl
                 } else { '' }

    # ── Remove CA-based session policies ─────────────────────────────────────

    $caPolicies = @()
    if ($Manifest -and $Manifest.PSObject.Properties['caPolicies']) {
        $caPolicies = @($Manifest.caPolicies)
    }

    # Manifest-first removal
    if ($caPolicies.Count -gt 0) {
        foreach ($caPolicy in $caPolicies) {
            $name = if ($caPolicy -is [hashtable]) { $caPolicy['name'] } elseif ($caPolicy.PSObject.Properties['name']) { [string]$caPolicy.name } else { 'unknown' }
            $id   = if ($caPolicy -is [hashtable]) { $caPolicy['id'] } elseif ($caPolicy.PSObject.Properties['id']) { [string]$caPolicy.id } else { $null }

            if (-not $id) { continue }

            try {
                $existing = Get-MgIdentityConditionalAccessPolicy -ConditionalAccessPolicyId $id -ErrorAction SilentlyContinue
                if (-not $existing) {
                    Write-LabLog -Message "MDCA: CA policy not found by ID, skipping: $name" -Level Warning
                    continue
                }
                if ($PSCmdlet.ShouldProcess($name, 'Remove MDCA session CA policy')) {
                    Remove-MgIdentityConditionalAccessPolicy -ConditionalAccessPolicyId $id -ErrorAction Stop
                    Write-LabLog -Message "MDCA: removed session CA policy: $name" -Level Success
                }
            }
            catch {
                Write-LabLog -Message "MDCA: error removing CA policy ${name}: $($_.Exception.Message)" -Level Warning
            }
        }
    }
    else {
        # Fallback: prefix-based lookup
        foreach ($policy in @($mdcaConf.policies | Where-Object { $_.type -eq 'session' })) {
            $name = "$prefix-$($policy.name)"
            try {
                $existing = Get-MgIdentityConditionalAccessPolicy -Filter "displayName eq '$name'" -ErrorAction SilentlyContinue |
                    Select-Object -First 1
                if (-not $existing) { continue }
                if ($PSCmdlet.ShouldProcess($name, 'Remove MDCA session CA policy')) {
                    Remove-MgIdentityConditionalAccessPolicy -ConditionalAccessPolicyId $existing.Id -ErrorAction Stop
                    Write-LabLog -Message "MDCA: removed session CA policy: $name" -Level Success
                }
            }
            catch {
                Write-LabLog -Message "MDCA: error removing CA policy ${name}: $($_.Exception.Message)" -Level Warning
            }
        }
    }

    # ── Remove MDCA REST API policies ────────────────────────────────────────

    $mdcaPolicies = @()
    if ($Manifest -and $Manifest.PSObject.Properties['mdcaPolicies']) {
        $mdcaPolicies = @($Manifest.mdcaPolicies | Where-Object {
            $id = if ($_ -is [hashtable]) { $_['id'] } elseif ($_.PSObject.Properties['id']) { $_.id } else { $null }
            -not [string]::IsNullOrWhiteSpace($id)
        })
    }

    if ($mdcaPolicies.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($portalUrl)) {
        foreach ($mdcaPolicy in $mdcaPolicies) {
            $name = if ($mdcaPolicy -is [hashtable]) { $mdcaPolicy['name'] } elseif ($mdcaPolicy.PSObject.Properties['name']) { [string]$mdcaPolicy.name } else { 'unknown' }
            $id   = if ($mdcaPolicy -is [hashtable]) { $mdcaPolicy['id'] } elseif ($mdcaPolicy.PSObject.Properties['id']) { [string]$mdcaPolicy.id } else { $null }

            if (-not $id) { continue }

            if ($PSCmdlet.ShouldProcess($name, 'Remove MDCA policy')) {
                $null = Invoke-MdcaApi -PortalUrl $portalUrl -Method DELETE -Path "policies/$id"
                Write-LabLog -Message "MDCA: removed policy: $name" -Level Success
            }
        }
    }

    # ── Remove SP tags ───────────────────────────────────────────────────────

    $taggedSPs = @()
    if ($Manifest -and $Manifest.PSObject.Properties['taggedServicePrincipals']) {
        $taggedSPs = @($Manifest.taggedServicePrincipals)
    }

    if ($taggedSPs.Count -gt 0) {
        Remove-AgentAppTags -TaggedServicePrincipals $taggedSPs -WhatIf:$WhatIfPreference
    }

    Write-LabLog -Message "MDCA: removal complete for prefix '$prefix'." -Level Success
}

# ─── Exports ─────────────────────────────────────────────────────────────────

Export-ModuleMember -Function @(
    'Deploy-MDCA'
    'Remove-MDCA'
)
