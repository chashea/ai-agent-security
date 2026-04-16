#Requires -Version 7.0

<#
.SYNOPSIS
    Agent identity management — managed identity RBAC for Foundry agents.
.DESCRIPTION
    Auto-derives Azure RBAC role assignments from each agent's tool definitions
    and assigns them to the Foundry account's system-assigned managed identity.
    The Foundry account MI is the single principal that agents execute under.
#>

# Import FoundryInfra for ARM helpers (Invoke-ArmGet, Invoke-ArmPut, Invoke-ArmDelete, Get-FoundryArmToken)
$script:InfraPath = if ($PSScriptRoot) { Join-Path $PSScriptRoot 'FoundryInfra.psm1' }
                    else { Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'FoundryInfra.psm1' }
if (Test-Path $script:InfraPath) { Import-Module $script:InfraPath -Force }

$script:AuthApiVersion = '2022-04-01'

# ─── Tool-to-RBAC Mapping ────────────────────────────────────────────────────

<#
.SYNOPSIS
    Derives deduplicated RBAC role requirements from agent tool definitions.
.DESCRIPTION
    Inspects all agents' tools arrays and maps tool types to minimum Azure RBAC
    roles. Always includes the baseline Cognitive Services User role on the
    Foundry account. Deduplicates by (roleDefinitionId, scopeType).
#>
function Get-ToolRoleRequirements {
    [CmdletBinding()]
    [OutputType([System.Collections.Generic.List[hashtable]])]
    param(
        [Parameter()]
        [array]$Agents = @()
    )

    # Role definition IDs (built-in Azure RBAC)
    $roleIds = @{
        CognitiveServicesUser     = 'a97b65f3-24c7-4388-baec-2e87135dc908'
        SearchIndexDataReader     = '1407120a-92aa-4202-b7e9-c0e197c71c8f'
        StorageBlobDataReader     = '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1'
        StorageBlobDataContributor = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
        WebsiteContributor        = 'de139f84-1756-47ae-9be6-808fbbe84772'
    }

    # Tool type -> list of { roleName, roleDefinitionId, scopeType }
    $toolMapping = @{
        'azure_ai_search' = @(
            @{ roleName = 'Search Index Data Reader';     roleDefinitionId = $roleIds.SearchIndexDataReader;     scopeType = 'aiSearch' }
        )
        'file_search' = @(
            @{ roleName = 'Storage Blob Data Reader';     roleDefinitionId = $roleIds.StorageBlobDataReader;     scopeType = 'storage' }
        )
        'code_interpreter' = @(
            @{ roleName = 'Storage Blob Data Contributor'; roleDefinitionId = $roleIds.StorageBlobDataContributor; scopeType = 'storage' }
        )
        'azure_function' = @(
            @{ roleName = 'Website Contributor';          roleDefinitionId = $roleIds.WebsiteContributor;        scopeType = 'functionApp' }
        )
    }

    # Baseline: Cognitive Services User on the Foundry account (always required)
    $requirements = [System.Collections.Generic.List[hashtable]]::new()
    $requirements.Add(@{
        roleName         = 'Cognitive Services User'
        roleDefinitionId = $roleIds.CognitiveServicesUser
        scopeType        = 'foundryAccount'
    })

    # Dedup key set
    $seen = [System.Collections.Generic.HashSet[string]]::new()
    [void]$seen.Add("$($roleIds.CognitiveServicesUser)|foundryAccount")

    foreach ($agent in $Agents) {
        $tools = if ($agent.PSObject.Properties['tools']) { $agent.tools } else { @() }
        foreach ($tool in $tools) {
            $toolType = if ($tool -is [string]) { $tool } elseif ($tool.PSObject.Properties['type']) { [string]$tool.type } else { continue }
            $mappings = $toolMapping[$toolType]
            if (-not $mappings) { continue }
            foreach ($m in $mappings) {
                $key = "$($m.roleDefinitionId)|$($m.scopeType)"
                if ($seen.Add($key)) {
                    $requirements.Add($m)
                }
            }
        }
    }

    return , @($requirements)
}

# ─── Scope Resolution ────────────────────────────────────────────────────────

function Resolve-RoleScope {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string]$ScopeType,
        [Parameter(Mandatory)] [string]$SubscriptionId,
        [Parameter(Mandatory)] [string]$ResourceGroup,
        [Parameter(Mandatory)] [PSCustomObject]$FoundryManifest
    )

    $rgPath = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup"

    switch ($ScopeType) {
        'foundryAccount' {
            if ($FoundryManifest.accountId) { return [string]$FoundryManifest.accountId }
            $accountName = if ($FoundryManifest.PSObject.Properties['accountName']) { [string]$FoundryManifest.accountName } else { $null }
            if ($accountName) { return "$rgPath/providers/Microsoft.CognitiveServices/accounts/$accountName" }
            return $null
        }
        'aiSearch' {
            $endpoint = if ($FoundryManifest.PSObject.Properties['aiSearchEndpoint']) { [string]$FoundryManifest.aiSearchEndpoint } else { $null }
            if ($endpoint -match 'https://([^.]+)\.') {
                $searchName = $Matches[1]
                return "$rgPath/providers/Microsoft.Search/searchServices/$searchName"
            }
            return $null
        }
        'storage' {
            $subClean = $SubscriptionId -replace '-', ''
            $subSuffix = $subClean.Substring($subClean.Length - 8, 8).ToLower()
            return "$rgPath/providers/Microsoft.Storage/storageAccounts/pvfoundrybot$subSuffix"
        }
        'functionApp' {
            $subClean = $SubscriptionId -replace '-', ''
            $subSuffix = $subClean.Substring($subClean.Length - 8, 8).ToLower()
            return "$rgPath/providers/Microsoft.Web/sites/pvfoundry-bot-$subSuffix"
        }
        default { return $null }
    }
}

# ─── Graph App Role Assignments ──────────────────────────────────────────────

<#
.SYNOPSIS
    Grants Microsoft Graph application permissions to the Foundry account's
    system-assigned managed identity.
.DESCRIPTION
    Each requested Graph application permission (e.g., User.Read.All) is
    resolved to an AppRole on the Graph service principal and assigned to
    the Foundry MI via Microsoft Graph PowerShell. Idempotent — skips
    permissions already assigned. Returns an array of hashtables describing
    each grant, suitable for the manifest.
.NOTES
    Requires the caller to already be connected to Microsoft Graph with
    AppRoleAssignment.ReadWrite.All + Application.Read.All scopes (Deploy.ps1
    handles this as part of its connect step when graphPermissions are
    configured).
#>
function Grant-AgentIdentityGraphPermissions {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([System.Collections.Generic.List[hashtable]])]
    param(
        [Parameter(Mandatory)] [string]$PrincipalId,
        [Parameter(Mandatory)] [string[]]$Permissions
    )

    $grants = [System.Collections.Generic.List[hashtable]]::new()

    if (-not $Permissions -or $Permissions.Count -eq 0) {
        return , @($grants)
    }

    # Resolve Graph SP (appId is a well-known constant).
    $graphAppId = '00000003-0000-0000-c000-000000000000'
    try {
        $graphSpn = Get-MgServicePrincipal -Filter "appId eq '$graphAppId'" -ErrorAction Stop
    }
    catch {
        Write-LabLog -Message "AgentIdentity/Graph: could not resolve Microsoft Graph service principal: $($_.Exception.Message)" -Level Warning
        return , @($grants)
    }
    if (-not $graphSpn) {
        Write-LabLog -Message 'AgentIdentity/Graph: Microsoft Graph service principal not found in tenant.' -Level Warning
        return , @($grants)
    }

    # Existing assignments on the Foundry MI (for idempotency).
    try {
        $existing = Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $PrincipalId -ErrorAction Stop
    }
    catch {
        Write-LabLog -Message "AgentIdentity/Graph: could not enumerate existing app-role assignments on ${PrincipalId}: $($_.Exception.Message)" -Level Warning
        $existing = @()
    }
    $existingRoleIds = @($existing | Select-Object -ExpandProperty AppRoleId)

    foreach ($permName in $Permissions) {
        $appRole = $graphSpn.AppRoles | Where-Object {
            $_.Value -eq $permName -and $_.AllowedMemberTypes -contains 'Application'
        } | Select-Object -First 1

        if (-not $appRole) {
            Write-LabLog -Message "AgentIdentity/Graph: app role '$permName' not found on Microsoft Graph — skipping." -Level Warning
            continue
        }

        if ($appRole.Id -in $existingRoleIds) {
            Write-LabLog -Message "AgentIdentity/Graph: $permName already assigned — skipping." -Level Info
            $existingAssignment = $existing | Where-Object { $_.AppRoleId -eq $appRole.Id } | Select-Object -First 1
            $grants.Add(@{
                permission       = $permName
                appRoleId        = [string]$appRole.Id
                assignmentId     = if ($existingAssignment) { [string]$existingAssignment.Id } else { $null }
                resourceId       = [string]$graphSpn.Id
                status           = 'existing'
            })
            continue
        }

        if (-not $PSCmdlet.ShouldProcess("principal $PrincipalId", "Grant Graph permission '$permName'")) {
            $grants.Add(@{
                permission   = $permName
                appRoleId    = [string]$appRole.Id
                assignmentId = $null
                resourceId   = [string]$graphSpn.Id
                status       = 'whatif'
            })
            continue
        }

        try {
            $body = @{
                principalId = $PrincipalId
                resourceId  = $graphSpn.Id
                appRoleId   = $appRole.Id
            }
            $result = New-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $PrincipalId -BodyParameter $body -ErrorAction Stop
            Write-LabLog -Message "AgentIdentity/Graph: assigned $permName to principal $PrincipalId" -Level Success
            $grants.Add(@{
                permission   = $permName
                appRoleId    = [string]$appRole.Id
                assignmentId = if ($result) { [string]$result.Id } else { $null }
                resourceId   = [string]$graphSpn.Id
                status       = 'created'
            })
        }
        catch {
            Write-LabLog -Message "AgentIdentity/Graph: failed to assign ${permName}: $($_.Exception.Message)" -Level Warning
            $grants.Add(@{
                permission   = $permName
                appRoleId    = [string]$appRole.Id
                assignmentId = $null
                resourceId   = [string]$graphSpn.Id
                status       = 'failed'
                error        = [string]$_.Exception.Message
            })
        }
    }

    return , @($grants)
}

function Revoke-AgentIdentityGraphPermissions {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string]$PrincipalId,
        [Parameter(Mandatory)] [array]$Grants
    )

    foreach ($grant in $Grants) {
        $assignmentId = if ($grant -is [hashtable]) { $grant['assignmentId'] }
                        elseif ($grant.PSObject.Properties['assignmentId']) { [string]$grant.assignmentId }
                        else { $null }
        $permName = if ($grant -is [hashtable]) { $grant['permission'] }
                    elseif ($grant.PSObject.Properties['permission']) { [string]$grant.permission }
                    else { 'unknown' }

        if (-not $assignmentId) {
            Write-LabLog -Message "AgentIdentity/Graph: skipping $permName — no assignmentId in manifest." -Level Warning
            continue
        }
        if (-not $PSCmdlet.ShouldProcess("principal $PrincipalId", "Revoke Graph permission '$permName'")) { continue }

        try {
            Remove-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $PrincipalId -AppRoleAssignmentId $assignmentId -ErrorAction Stop
            Write-LabLog -Message "AgentIdentity/Graph: revoked $permName ($assignmentId)" -Level Success
        }
        catch {
            Write-LabLog -Message "AgentIdentity/Graph: failed to revoke ${permName}: $($_.Exception.Message)" -Level Warning
        }
    }
}

# ─── Deploy ──────────────────────────────────────────────────────────────────

function Deploy-AgentIdentity {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Config,

        [Parameter()]
        [PSCustomObject]$FoundryManifest
    )

    $prefix = [string]$Config.prefix
    $fw     = $Config.workloads.foundry
    $ai     = $Config.workloads.agentIdentity

    $result = @{
        principalId         = $null
        principalType       = 'ServicePrincipal'
        identitySource      = 'foundryAccount'
        roleAssignments     = @()
        skippedTools        = @()
        graphPermissions    = @()
    }

    # Check if auto-derive is enabled (default: true)
    $autoDerive = if ($ai.PSObject.Properties['autoDerive']) { [bool]$ai.autoDerive } else { $true }

    if (-not $FoundryManifest) {
        Write-LabLog -Message "AgentIdentity: no Foundry manifest provided — skipping RBAC assignments." -Level Warning
        return $result
    }

    $principalId = if ($FoundryManifest.PSObject.Properties['accountPrincipalId']) { [string]$FoundryManifest.accountPrincipalId } else { $null }
    if ([string]::IsNullOrWhiteSpace($principalId)) {
        Write-LabLog -Message "AgentIdentity: Foundry account has no managed identity (accountPrincipalId is empty). Enable system-assigned MI on the Foundry account." -Level Warning
        return $result
    }
    $result.principalId = $principalId

    $subscriptionId = [string]$FoundryManifest.subscriptionId
    $resourceGroup  = [string]$FoundryManifest.resourceGroup

    # Derive role requirements from agent tools
    $agents = if ($fw.PSObject.Properties['agents']) { @($fw.agents) } else { @() }
    if ($autoDerive) {
        $requirements = Get-ToolRoleRequirements -Agents $agents
    }
    else {
        # Baseline only when auto-derive is off
        $requirements = [System.Collections.Generic.List[hashtable]]::new()
        $requirements.Add(@{
            roleName         = 'Cognitive Services User'
            roleDefinitionId = 'a97b65f3-24c7-4388-baec-2e87135dc908'
            scopeType        = 'foundryAccount'
        })
    }

    # Merge additional roles from config
    $additionalRoles = if ($ai.PSObject.Properties['additionalRoles']) { @($ai.additionalRoles) } else { @() }
    foreach ($extra in $additionalRoles) {
        if ($extra.PSObject.Properties['roleDefinitionId'] -and $extra.PSObject.Properties['scopeType']) {
            $requirements.Add(@{
                roleName         = if ($extra.PSObject.Properties['roleName']) { [string]$extra.roleName } else { 'Custom' }
                roleDefinitionId = [string]$extra.roleDefinitionId
                scopeType        = [string]$extra.scopeType
            })
        }
    }

    # Track skipped tools (tools with no RBAC mapping)
    $skippedSet = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($agent in $agents) {
        $tools = if ($agent.PSObject.Properties['tools']) { $agent.tools } else { @() }
        foreach ($tool in $tools) {
            $toolType = if ($tool -is [string]) { $tool } elseif ($tool.PSObject.Properties['type']) { [string]$tool.type } else { continue }
            if ($toolType -in @('openapi', 'mcp', 'a2a', 'function', 'sharepoint_grounding')) {
                [void]$skippedSet.Add($toolType)
            }
        }
    }
    $result.skippedTools = @($skippedSet | Sort-Object)

    if (-not $PSCmdlet.ShouldProcess("RBAC for Foundry MI '$principalId' (prefix: $prefix)", 'Assign roles')) {
        Write-LabLog -Message "AgentIdentity: WhatIf — would assign $($requirements.Count) role(s) to principal $principalId" -Level Info
        foreach ($req in $requirements) {
            Write-LabLog -Message "  WhatIf: $($req.roleName) on $($req.scopeType)" -Level Info
        }
        return $result
    }

    # Get ARM token for role assignment operations
    $armToken = Get-FoundryArmToken

    $assignedRoles = [System.Collections.Generic.List[hashtable]]::new()

    foreach ($req in $requirements) {
        $scope = Resolve-RoleScope -ScopeType $req.scopeType -SubscriptionId $subscriptionId `
                                   -ResourceGroup $resourceGroup -FoundryManifest $FoundryManifest
        if (-not $scope) {
            Write-LabLog -Message "AgentIdentity: could not resolve scope for '$($req.scopeType)' — skipping $($req.roleName)" -Level Warning
            continue
        }

        $roleDefId = "/subscriptions/$subscriptionId/providers/Microsoft.Authorization/roleDefinitions/$($req.roleDefinitionId)"
        $assignmentId = [guid]::NewGuid().ToString()
        $assignmentUri = "https://management.azure.com$scope/providers/Microsoft.Authorization/roleAssignments/$assignmentId`?api-version=$($script:AuthApiVersion)"

        # Check if assignment already exists (idempotent). ARM only supports
        # 'atScope()', 'principalId eq', or 'assignedTo()' filters — combining
        # fields is not supported, so filter by principalId server-side and
        # match roleDefinitionId client-side.
        $existingUri = "https://management.azure.com$scope/providers/Microsoft.Authorization/roleAssignments?api-version=$($script:AuthApiVersion)&`$filter=principalId eq '$principalId'"
        $existing = Invoke-ArmGet -Uri $existingUri -Token $armToken
        $existingMatch = $null
        if ($existing -and $existing.value) {
            $existingMatch = $existing.value | Where-Object {
                [string]$_.properties.roleDefinitionId -eq $roleDefId
            } | Select-Object -First 1
        }
        if ($existingMatch) {
            Write-LabLog -Message "AgentIdentity: $($req.roleName) already assigned on $($req.scopeType) — skipping" -Level Info
            $assignedRoles.Add(@{
                id               = [string]$existingMatch.id
                roleName         = $req.roleName
                roleDefinitionId = $req.roleDefinitionId
                scope            = $scope
                status           = 'existing'
            })
            continue
        }

        # Create role assignment
        $body = @{
            properties = @{
                roleDefinitionId = $roleDefId
                principalId      = $principalId
                principalType    = 'ServicePrincipal'
            }
        } | ConvertTo-Json -Depth 5

        $assignResult = Invoke-LabRetry -ScriptBlock {
            Invoke-ArmPut -Uri $assignmentUri -Body $body -Token $armToken
        } -MaxAttempts 3 -DelaySeconds 5

        $finalId = if ($assignResult -and $assignResult.id) { [string]$assignResult.id } else { "$scope/providers/Microsoft.Authorization/roleAssignments/$assignmentId" }
        Write-LabLog -Message "AgentIdentity: assigned $($req.roleName) on $($req.scopeType)" -Level Success

        $assignedRoles.Add(@{
            id               = $finalId
            roleName         = $req.roleName
            roleDefinitionId = $req.roleDefinitionId
            scope            = $scope
            status           = 'created'
        })
    }

    $result.roleAssignments = @($assignedRoles)
    Write-LabLog -Message "AgentIdentity: $($assignedRoles.Count) role assignment(s) configured for principal $principalId" -Level Success

    # Optional: grant Microsoft Graph application permissions to the Foundry MI.
    # Opt-in via workloads.agentIdentity.graphPermissions = ["User.Read.All", ...].
    $graphPerms = @()
    if ($ai.PSObject.Properties['graphPermissions']) {
        $graphPerms = @($ai.graphPermissions | Where-Object { $_ -and -not [string]::IsNullOrWhiteSpace($_) })
    }
    if ($graphPerms.Count -gt 0) {
        # Verify Graph SDK modules are loaded — Deploy.ps1 already connects,
        # but when the workload is invoked in isolation (e.g., tests, reruns)
        # we skip with a clear warning rather than crashing.
        if (-not (Get-Command Get-MgServicePrincipal -ErrorAction SilentlyContinue)) {
            Write-LabLog -Message "AgentIdentity: graphPermissions configured but Microsoft.Graph SDK not available — skipping Graph grants. Run Deploy.ps1 which connects Graph for you." -Level Warning
        }
        else {
            $grants = Grant-AgentIdentityGraphPermissions -PrincipalId $principalId -Permissions $graphPerms
            $result.graphPermissions = @($grants)
            $created = @($grants | Where-Object { $_.status -eq 'created' }).Count
            $existing = @($grants | Where-Object { $_.status -eq 'existing' }).Count
            Write-LabLog -Message "AgentIdentity: Graph permissions — $created assigned, $existing already present (of $($graphPerms.Count) requested)" -Level Success
        }
    }

    return $result
}

# ─── Remove ──────────────────────────────────────────────────────────────────

function Remove-AgentIdentity {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Config,

        [Parameter()]
        [PSCustomObject]$Manifest
    )

    $prefix = [string]$Config.prefix

    # Extract role assignments from manifest
    $roleAssignments = @()
    if ($Manifest -and $Manifest.PSObject.Properties['roleAssignments']) {
        $roleAssignments = @($Manifest.roleAssignments)
    }

    if ($roleAssignments.Count -eq 0) {
        Write-LabLog -Message "AgentIdentity: no role assignments in manifest for prefix '$prefix' — nothing to remove." -Level Info
        return
    }

    if (-not $PSCmdlet.ShouldProcess("$($roleAssignments.Count) RBAC assignment(s) for prefix '$prefix'", 'Remove')) {
        return
    }

    $armToken = Get-FoundryArmToken

    foreach ($assignment in $roleAssignments) {
        $assignmentId = if ($assignment -is [hashtable]) { $assignment['id'] }
                        elseif ($assignment.PSObject.Properties['id']) { [string]$assignment.id }
                        else { $null }
        $roleName = if ($assignment -is [hashtable]) { $assignment['roleName'] }
                    elseif ($assignment.PSObject.Properties['roleName']) { [string]$assignment.roleName }
                    else { 'unknown' }

        if (-not $assignmentId) {
            Write-LabLog -Message "AgentIdentity: skipping assignment with no ID ($roleName)" -Level Warning
            continue
        }

        $deleteUri = "https://management.azure.com$assignmentId`?api-version=$($script:AuthApiVersion)"
        Invoke-ArmDelete -Uri $deleteUri -Token $armToken
        Write-LabLog -Message "AgentIdentity: removed $roleName ($assignmentId)" -Level Success
    }

    Write-LabLog -Message "AgentIdentity: removed $($roleAssignments.Count) role assignment(s) for prefix '$prefix'" -Level Success

    # Revoke any Graph permission grants recorded in the manifest.
    $graphGrants = @()
    if ($Manifest -and $Manifest.PSObject.Properties['graphPermissions']) {
        $graphGrants = @($Manifest.graphPermissions)
    }
    if ($graphGrants.Count -gt 0) {
        $principalId = if ($Manifest.PSObject.Properties['principalId']) { [string]$Manifest.principalId } else { $null }
        if (-not $principalId) {
            Write-LabLog -Message "AgentIdentity: manifest has graphPermissions but no principalId — cannot revoke." -Level Warning
        }
        elseif (-not (Get-Command Remove-MgServicePrincipalAppRoleAssignment -ErrorAction SilentlyContinue)) {
            Write-LabLog -Message "AgentIdentity: Microsoft.Graph SDK not available — skipping Graph permission revocations." -Level Warning
        }
        else {
            Revoke-AgentIdentityGraphPermissions -PrincipalId $principalId -Grants $graphGrants
        }
    }
}

# ─── Exports ─────────────────────────────────────────────────────────────────

Export-ModuleMember -Function @(
    'Deploy-AgentIdentity'
    'Remove-AgentIdentity'
    'Get-ToolRoleRequirements'
    'Grant-AgentIdentityGraphPermissions'
    'Revoke-AgentIdentityGraphPermissions'
)
