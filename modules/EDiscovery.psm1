#Requires -Version 7.0

<#
.SYNOPSIS
    eDiscovery Premium workload module for purview-lab-deployer.
    Uses Microsoft Graph API (/v1.0/security/cases/ediscoveryCases).
#>

$script:EDiscBaseUri = '/v1.0/security/cases/ediscoveryCases'

# ── Helpers ──────────────────────────────────────────────────────────────────

function Get-EdiscoveryCaseByName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DisplayName
    )
    $filter = "displayName eq '$($DisplayName -replace "'","''")'"
    $response = Invoke-MgGraphRequest -Method GET -Uri "$($script:EDiscBaseUri)?`$filter=$filter" -ErrorAction Stop
    return ($response.value | Select-Object -First 1)
}

function Wait-LongRunningOperation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$OperationUri,

        [int]$TimeoutSeconds = 120,

        [int]$PollIntervalSeconds = 5
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds $PollIntervalSeconds
        try {
            $op = Invoke-MgGraphRequest -Method GET -Uri $OperationUri -ErrorAction Stop
            if ($op.status -eq 'succeeded' -or $op.status -eq 'completed') {
                return $op
            }
            if ($op.status -eq 'failed') {
                throw "Long-running operation failed: $($op | ConvertTo-Json -Depth 5 -Compress)"
            }
        }
        catch {
            if ($_.Exception.Message -notlike '*failed*') {
                Write-LabLog -Message "Polling operation status: $($_.Exception.Message)" -Level Warning
            }
            else { throw }
        }
    }
    throw "Long-running operation timed out after $TimeoutSeconds seconds: $OperationUri"
}

# ── Deploy ───────────────────────────────────────────────────────────────────

function Deploy-EDiscovery {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Config
    )

    $cases = $Config.workloads.eDiscovery.cases
    $manifestCases = [System.Collections.Generic.List[PSCustomObject]]::new()

    foreach ($case in $cases) {
        $displayName = "$($Config.prefix)-$($case.name)"

        Write-LabLog -Message "Processing eDiscovery Premium case: $displayName" -Level Info

        # ── Resolve custodians ──────────────────────────────────────────
        $resolvedCustodians = [System.Collections.Generic.List[string]]::new()
        $missingCustodians = [System.Collections.Generic.List[string]]::new()

        foreach ($custodianIdentity in $case.custodians) {
            $resolvedUser = Get-LabUserByIdentity -Identity $custodianIdentity -DefaultDomain $Config.domain
            if ($resolvedUser -and -not [string]::IsNullOrWhiteSpace([string]$resolvedUser.UserPrincipalName)) {
                $resolvedCustodians.Add([string]$resolvedUser.UserPrincipalName)
            }
            else {
                $missingCustodians.Add([string]$custodianIdentity)
            }
        }

        if ($missingCustodians.Count -gt 0) {
            $missingSummary = (($missingCustodians | Sort-Object -Unique) -join ', ')
            if ($resolvedCustodians.Count -eq 0) {
                $ctx = Get-MgContext
                if ($ctx -and -not [string]::IsNullOrWhiteSpace($ctx.Account)) {
                    Write-LabLog -Message "eDiscovery case '$displayName': configured custodians not found ($missingSummary). Falling back to current user: $($ctx.Account)" -Level Warning
                    $resolvedCustodians.Add([string]$ctx.Account)
                }
                else {
                    throw "eDiscovery case '$displayName' references custodians not found in Microsoft Graph: $missingSummary"
                }
            }
            else {
                Write-LabLog -Message "eDiscovery case '$displayName': some custodians not found ($missingSummary). Proceeding with resolved custodians." -Level Warning
            }
        }

        $targetCustodians = @($resolvedCustodians | Sort-Object -Unique)

        # ── Case ────────────────────────────────────────────────────────
        $existingCase = Get-EdiscoveryCaseByName -DisplayName $displayName
        $caseId = $null

        if (-not $existingCase) {
            if ($PSCmdlet.ShouldProcess($displayName, 'Create eDiscovery Premium case')) {
                Write-LabLog -Message "Creating eDiscovery Premium case: $displayName" -Level Info
                $caseBody = @{
                    displayName = $displayName
                    description = [string]$case.description
                    externalId  = $Config.prefix
                }
                $created = Invoke-MgGraphRequest -Method POST -Uri $script:EDiscBaseUri `
                    -Body ($caseBody | ConvertTo-Json -Depth 5) `
                    -ContentType 'application/json' -ErrorAction Stop
                $caseId = $created.id
            }
        }
        else {
            Write-LabLog -Message "eDiscovery Premium case already exists: $displayName" -Level Info
            $caseId = $existingCase.id
        }

        $caseUri = "$($script:EDiscBaseUri)/$caseId"
        $manifestCustodians = [System.Collections.Generic.List[PSCustomObject]]::new()
        $manifestSearches = [System.Collections.Generic.List[PSCustomObject]]::new()
        $manifestReviewSets = [System.Collections.Generic.List[PSCustomObject]]::new()

        # ── Custodians ──────────────────────────────────────────────────
        if ($caseId -and $targetCustodians.Count -gt 0) {
            $custodianIds = [System.Collections.Generic.List[string]]::new()

            foreach ($email in $targetCustodians) {
                # Check if custodian already exists on the case
                $custodianFilter = "email eq '$($email -replace "'","''")'"
                $existingCustodian = $null
                try {
                    $custodianResponse = Invoke-MgGraphRequest -Method GET `
                        -Uri "$caseUri/custodians?`$filter=$custodianFilter" -ErrorAction Stop
                    $existingCustodian = $custodianResponse.value | Select-Object -First 1
                }
                catch {
                    $existingCustodian = $null
                }

                if ($existingCustodian) {
                    Write-LabLog -Message "Custodian already exists on case: $email" -Level Info
                    $custodianIds.Add($existingCustodian.id)
                    $manifestCustodians.Add([PSCustomObject]@{ id = $existingCustodian.id; email = $email })
                }
                else {
                    if ($PSCmdlet.ShouldProcess("$email -> $displayName", 'Add eDiscovery custodian')) {
                        try {
                            Write-LabLog -Message "Adding custodian to case: $email" -Level Info
                            $custodianBody = @{ email = $email }
                            $addedCustodian = Invoke-MgGraphRequest -Method POST `
                                -Uri "$caseUri/custodians" `
                                -Body ($custodianBody | ConvertTo-Json -Depth 5) `
                                -ContentType 'application/json' -ErrorAction Stop
                            $custodianIds.Add($addedCustodian.id)
                            $manifestCustodians.Add([PSCustomObject]@{ id = $addedCustodian.id; email = $email })
                        }
                        catch {
                            Write-LabLog -Message "Could not add custodian $email to case $displayName`: $($_.Exception.Message)" -Level Warning
                        }
                    }
                }
            }

            # ── Apply hold to custodians ────────────────────────────────
            if ($custodianIds.Count -gt 0) {
                if ($PSCmdlet.ShouldProcess("$($custodianIds.Count) custodians", 'Apply eDiscovery hold')) {
                    try {
                        Write-LabLog -Message "Applying hold to $($custodianIds.Count) custodians on case: $displayName" -Level Info
                        $holdBody = @{ ids = @($custodianIds) }
                        Invoke-MgGraphRequest -Method POST `
                            -Uri "$caseUri/custodians/applyHold" `
                            -Body ($holdBody | ConvertTo-Json -Depth 5) `
                            -ContentType 'application/json' -ErrorAction Stop | Out-Null
                    }
                    catch {
                        Write-LabLog -Message "Could not apply hold on case $displayName`: $($_.Exception.Message)" -Level Warning
                    }
                }
            }
        }
        elseif ($caseId) {
            Write-LabLog -Message "No custodians resolved for case $displayName. Skipping custodian and hold operations." -Level Warning
        }

        # ── Searches ────────────────────────────────────────────────────
        if ($caseId) {
            # Build search list: explicit searches array takes precedence, fallback to legacy searchQuery
            $searchConfigs = @()
            if ($case.searches -and $case.searches.Count -gt 0) {
                $searchConfigs = @($case.searches)
            }
            elseif (-not [string]::IsNullOrWhiteSpace([string]$case.searchQuery)) {
                $searchConfigs = @(
                    [PSCustomObject]@{
                        name             = "$displayName-Search"
                        contentQuery     = [string]$case.searchQuery
                        dataSourceScopes = 'allCaseCustodians'
                    }
                )
            }

            foreach ($searchDef in $searchConfigs) {
                $searchDisplayName = "$displayName-$($searchDef.name)"
                $searchFilter = "displayName eq '$($searchDisplayName -replace "'","''")'"
                $existingSearch = $null
                try {
                    $searchResponse = Invoke-MgGraphRequest -Method GET `
                        -Uri "$caseUri/searches?`$filter=$searchFilter" -ErrorAction Stop
                    $existingSearch = $searchResponse.value | Select-Object -First 1
                }
                catch {
                    $existingSearch = $null
                }

                if ($existingSearch) {
                    Write-LabLog -Message "eDiscovery search already exists: $searchDisplayName" -Level Info
                    $manifestSearches.Add([PSCustomObject]@{ id = $existingSearch.id; name = $searchDisplayName })
                }
                else {
                    if ($PSCmdlet.ShouldProcess($searchDisplayName, 'Create eDiscovery search')) {
                        try {
                            Write-LabLog -Message "Creating eDiscovery search: $searchDisplayName" -Level Info
                            $scope = if ($searchDef.dataSourceScopes) { [string]$searchDef.dataSourceScopes } else { 'allCaseCustodians' }
                            $searchBody = @{
                                displayName      = $searchDisplayName
                                contentQuery     = [string]$searchDef.contentQuery
                                dataSourceScopes = $scope
                            }
                            $createdSearch = Invoke-MgGraphRequest -Method POST `
                                -Uri "$caseUri/searches" `
                                -Body ($searchBody | ConvertTo-Json -Depth 5) `
                                -ContentType 'application/json' -ErrorAction Stop
                            $manifestSearches.Add([PSCustomObject]@{ id = $createdSearch.id; name = $searchDisplayName })
                        }
                        catch {
                            Write-LabLog -Message "Could not create search $searchDisplayName`: $($_.Exception.Message)" -Level Warning
                        }
                    }
                }
            }
        }

        # ── Review Sets ─────────────────────────────────────────────────
        if ($caseId -and $case.reviewSets -and $case.reviewSets.Count -gt 0) {
            foreach ($rsDef in $case.reviewSets) {
                $rsDisplayName = "$displayName-$($rsDef.name)"
                $rsFilter = "displayName eq '$($rsDisplayName -replace "'","''")'"
                $existingRs = $null
                try {
                    $rsResponse = Invoke-MgGraphRequest -Method GET `
                        -Uri "$caseUri/reviewSets?`$filter=$rsFilter" -ErrorAction Stop
                    $existingRs = $rsResponse.value | Select-Object -First 1
                }
                catch {
                    $existingRs = $null
                }

                $rsId = $null
                if ($existingRs) {
                    Write-LabLog -Message "eDiscovery review set already exists: $rsDisplayName" -Level Info
                    $rsId = $existingRs.id
                }
                else {
                    if ($PSCmdlet.ShouldProcess($rsDisplayName, 'Create eDiscovery review set')) {
                        try {
                            Write-LabLog -Message "Creating eDiscovery review set: $rsDisplayName" -Level Info
                            $rsBody = @{ displayName = $rsDisplayName }
                            $createdRs = Invoke-MgGraphRequest -Method POST `
                                -Uri "$caseUri/reviewSets" `
                                -Body ($rsBody | ConvertTo-Json -Depth 5) `
                                -ContentType 'application/json' -ErrorAction Stop
                            $rsId = $createdRs.id
                        }
                        catch {
                            Write-LabLog -Message "Could not create review set $rsDisplayName`: $($_.Exception.Message)" -Level Warning
                        }
                    }
                }

                $manifestReviewSets.Add([PSCustomObject]@{ id = $rsId; name = $rsDisplayName })

                # ── Add search results to review set ────────────────────
                if ($rsId -and -not [string]::IsNullOrWhiteSpace([string]$rsDef.sourceSearch)) {
                    $sourceSearchName = "$displayName-$($rsDef.sourceSearch)"
                    $linkedSearch = $manifestSearches | Where-Object { $_.name -eq $sourceSearchName } | Select-Object -First 1
                    if ($linkedSearch) {
                        if ($PSCmdlet.ShouldProcess("$sourceSearchName -> $rsDisplayName", 'Add search results to review set')) {
                            try {
                                Write-LabLog -Message "Adding search results from '$sourceSearchName' to review set '$rsDisplayName'" -Level Info
                                $addBody = @{
                                    search = @{ id = $linkedSearch.id }
                                    additionalDataOptions = 'allVersions'
                                }
                                Invoke-MgGraphRequest -Method POST `
                                    -Uri "$caseUri/reviewSets/$rsId/addToReviewSet" `
                                    -Body ($addBody | ConvertTo-Json -Depth 5) `
                                    -ContentType 'application/json' -ErrorAction Stop | Out-Null
                            }
                            catch {
                                Write-LabLog -Message "Could not add search results to review set $rsDisplayName`: $($_.Exception.Message)" -Level Warning
                            }
                        }
                    }
                    else {
                        Write-LabLog -Message "Source search '$sourceSearchName' not found in manifest for review set '$rsDisplayName'. Skipping addToReviewSet." -Level Warning
                    }
                }
            }
        }

        $manifestCases.Add([PSCustomObject]@{
            caseId     = $caseId
            caseName   = $displayName
            custodians = $manifestCustodians.ToArray()
            searches   = $manifestSearches.ToArray()
            reviewSets = $manifestReviewSets.ToArray()
        })
    }

    return [PSCustomObject]@{
        cases = $manifestCases.ToArray()
    }
}

# ── Remove ───────────────────────────────────────────────────────────────────

function Remove-EDiscovery {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Config,

        [Parameter()]
        [PSCustomObject]$Manifest
    )

    $targetCases = @()

    # Build target list from manifest or config
    if ($Manifest -and $Manifest.cases) {
        foreach ($mc in @($Manifest.cases)) {
            if ($mc.caseId -or $mc.caseName) {
                $targetCases += [PSCustomObject]@{
                    caseId   = [string]$mc.caseId
                    caseName = [string]$mc.caseName
                }
            }
        }
    }

    if ($targetCases.Count -eq 0) {
        foreach ($case in $Config.workloads.eDiscovery.cases) {
            $displayName = "$($Config.prefix)-$($case.name)"
            $existing = Get-EdiscoveryCaseByName -DisplayName $displayName
            if ($existing) {
                $targetCases += [PSCustomObject]@{
                    caseId   = $existing.id
                    caseName = $displayName
                }
            }
            else {
                Write-LabLog -Message "eDiscovery Premium case not found for removal: $displayName" -Level Warning
            }
        }
    }

    [array]::Reverse($targetCases)

    foreach ($target in $targetCases) {
        $caseId = $target.caseId
        $displayName = $target.caseName

        # Resolve case ID if only name is available
        if ([string]::IsNullOrWhiteSpace($caseId) -and -not [string]::IsNullOrWhiteSpace($displayName)) {
            $found = Get-EdiscoveryCaseByName -DisplayName $displayName
            if ($found) { $caseId = $found.id }
            else {
                Write-LabLog -Message "eDiscovery Premium case not found: $displayName" -Level Warning
                continue
            }
        }

        $caseUri = "$($script:EDiscBaseUri)/$caseId"
        Write-LabLog -Message "Removing eDiscovery Premium resources for case: $displayName ($caseId)" -Level Info

        # ── Release custodian holds ─────────────────────────────────────
        try {
            $custodiansResp = Invoke-MgGraphRequest -Method GET -Uri "$caseUri/custodians" -ErrorAction Stop
            $custodianIds = @($custodiansResp.value | ForEach-Object { $_.id })
            if ($custodianIds.Count -gt 0) {
                if ($PSCmdlet.ShouldProcess("$($custodianIds.Count) custodians on $displayName", 'Release eDiscovery hold')) {
                    Write-LabLog -Message "Releasing hold on $($custodianIds.Count) custodians" -Level Info
                    $releaseBody = @{ ids = $custodianIds }
                    Invoke-MgGraphRequest -Method POST -Uri "$caseUri/custodians/removeHold" `
                        -Body ($releaseBody | ConvertTo-Json -Depth 5) `
                        -ContentType 'application/json' -ErrorAction Stop | Out-Null
                }
            }
        }
        catch {
            Write-LabLog -Message "Could not release custodian holds for $displayName`: $($_.Exception.Message)" -Level Warning
        }

        # ── Delete review sets ──────────────────────────────────────────
        try {
            $rsResp = Invoke-MgGraphRequest -Method GET -Uri "$caseUri/reviewSets" -ErrorAction Stop
            foreach ($rs in @($rsResp.value)) {
                if ($PSCmdlet.ShouldProcess($rs.displayName, 'Delete eDiscovery review set')) {
                    Write-LabLog -Message "Deleting review set: $($rs.displayName)" -Level Info
                    Invoke-MgGraphRequest -Method DELETE -Uri "$caseUri/reviewSets/$($rs.id)" -ErrorAction Stop | Out-Null
                }
            }
        }
        catch {
            Write-LabLog -Message "Could not delete review sets for $displayName`: $($_.Exception.Message)" -Level Warning
        }

        # ── Delete searches ─────────────────────────────────────────────
        try {
            $searchResp = Invoke-MgGraphRequest -Method GET -Uri "$caseUri/searches" -ErrorAction Stop
            foreach ($search in @($searchResp.value)) {
                if ($PSCmdlet.ShouldProcess($search.displayName, 'Delete eDiscovery search')) {
                    Write-LabLog -Message "Deleting search: $($search.displayName)" -Level Info
                    Invoke-MgGraphRequest -Method DELETE -Uri "$caseUri/searches/$($search.id)" -ErrorAction Stop | Out-Null
                }
            }
        }
        catch {
            Write-LabLog -Message "Could not delete searches for $displayName`: $($_.Exception.Message)" -Level Warning
        }

        # ── Remove custodians ───────────────────────────────────────────
        try {
            $custodiansResp = Invoke-MgGraphRequest -Method GET -Uri "$caseUri/custodians" -ErrorAction Stop
            foreach ($custodian in @($custodiansResp.value)) {
                if ($PSCmdlet.ShouldProcess($custodian.email, 'Remove eDiscovery custodian')) {
                    Write-LabLog -Message "Removing custodian: $($custodian.email)" -Level Info
                    Invoke-MgGraphRequest -Method DELETE -Uri "$caseUri/custodians/$($custodian.id)" -ErrorAction Stop | Out-Null
                }
            }
        }
        catch {
            Write-LabLog -Message "Could not remove custodians for $displayName`: $($_.Exception.Message)" -Level Warning
        }

        # ── Close and delete case ───────────────────────────────────────
        try {
            if ($PSCmdlet.ShouldProcess($displayName, 'Close and delete eDiscovery Premium case')) {
                Write-LabLog -Message "Closing eDiscovery Premium case: $displayName" -Level Info
                Invoke-MgGraphRequest -Method POST -Uri "$caseUri/close" -ErrorAction Stop | Out-Null

                Write-LabLog -Message "Deleting eDiscovery Premium case: $displayName" -Level Info
                Invoke-MgGraphRequest -Method DELETE -Uri $caseUri -ErrorAction Stop | Out-Null
            }
        }
        catch {
            Write-LabLog -Message "Could not close/delete case $displayName`: $($_.Exception.Message)" -Level Warning
        }
    }
}

Export-ModuleMember -Function @(
    'Deploy-EDiscovery'
    'Remove-EDiscovery'
)
