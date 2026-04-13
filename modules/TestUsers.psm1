#Requires -Version 7.0

<#
.SYNOPSIS
    Test users and groups workload module for purview-lab-deployer.
#>

function Deploy-TestUsers {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Config
    )

    $createdUpns = [System.Collections.Generic.List[string]]::new()
    $createdGroups = [System.Collections.Generic.List[string]]::new()

    $graphContext = Get-MgContext
    if (-not $graphContext -or [string]::IsNullOrWhiteSpace($graphContext.Account)) {
        throw 'Microsoft Graph context is not available for Deploy-TestUsers.'
    }

    $mode = if ($Config.workloads.testUsers.PSObject.Properties['mode']) {
        $Config.workloads.testUsers.mode
    } else { 'create' }

    if ($mode -eq 'existing') {
        # --- Validate existing users ---
        Write-LabLog -Message "TestUsers mode: existing — validating pre-existing Entra ID users" -Level Info
        $missingUsers = [System.Collections.Generic.List[string]]::new()

        foreach ($user in $Config.workloads.testUsers.users) {
            # Accept either 'upn' or 'identity' — config.json uses 'identity' for
            # existing-mode validation, whereas create-mode uses mailNickname + domain.
            $upn = $null
            if ($user.PSObject.Properties['upn'] -and -not [string]::IsNullOrWhiteSpace([string]$user.upn)) {
                $upn = [string]$user.upn
            }
            elseif ($user.PSObject.Properties['identity'] -and -not [string]::IsNullOrWhiteSpace([string]$user.identity)) {
                $upn = [string]$user.identity
            }
            if ([string]::IsNullOrWhiteSpace($upn)) {
                throw "Each user entry must have an 'upn' or 'identity' property when testUsers.mode is 'existing'."
            }

            $existing = Get-LabUserByIdentity -Identity $upn -DefaultDomain $Config.domain
            if ($existing) {
                $resolvedUpn = [string]$existing.UserPrincipalName
                Write-LabLog -Message "Validated existing user: $resolvedUpn" -Level Success
                $createdUpns.Add($resolvedUpn)
            }
            else {
                $missingUsers.Add($upn)
            }
        }

        if ($missingUsers.Count -gt 0) {
            $list = $missingUsers -join ', '
            throw "The following users were not found in Entra ID (mode=existing): $list"
        }
    }
    else {
        # --- Create users ---
        foreach ($user in $Config.workloads.testUsers.users) {
            $upn = "$($user.mailNickname)@$($Config.domain)"

            $existing = Get-LabUserByIdentity -Identity $upn -DefaultDomain $Config.domain
            if ($existing) {
                $existingUpn = [string]$existing.UserPrincipalName
                Write-LabLog -Message "User already exists: $existingUpn" -Level Info
                $createdUpns.Add($existingUpn)
                continue
            }

            if ($PSCmdlet.ShouldProcess($upn, 'Create user')) {
                $password = "PVLab-$((New-Guid).ToString().Substring(0,8))!"
                $passwordProfile = @{
                    ForceChangePasswordNextSignIn = $true
                    Password                     = $password
                }

                $params = @{
                    DisplayName       = $user.displayName
                    MailNickname      = $user.mailNickname
                    UserPrincipalName = $upn
                    Department        = $user.department
                    JobTitle          = $user.jobTitle
                    UsageLocation     = $user.usageLocation
                    AccountEnabled    = $true
                    PasswordProfile   = $passwordProfile
                }

                New-MgUser @params -ErrorAction Stop | Out-Null
                $resolvedUser = Invoke-LabRetry -MaxAttempts 6 -DelaySeconds 5 -OperationName "confirm user '$upn'" -ScriptBlock {
                    $found = Get-LabUserByIdentity -Identity $upn -DefaultDomain $Config.domain
                    if (-not $found) {
                        throw "User '$upn' not yet available in Microsoft Graph."
                    }
                    return $found
                }

                $resolvedUpn = [string]$resolvedUser.UserPrincipalName
                Write-LabLog -Message "Created user: $resolvedUpn" -Level Success
                $createdUpns.Add($resolvedUpn)
            }
        }

        # --- License assignment (create mode only) ---
        $skus = Get-MgSubscribedSku -ErrorAction Stop
        $mailboxSku = $skus | Where-Object {
            $_.PrepaidUnits.Enabled -gt $_.ConsumedUnits -and
            ($_.ServicePlans | Where-Object {
                $_.ServicePlanName -match 'EXCHANGE_S_' -and
                $_.ProvisioningStatus -ne 'Disabled'
            })
        } | Sort-Object { $_.PrepaidUnits.Enabled - $_.ConsumedUnits } -Descending | Select-Object -First 1

        if ($mailboxSku) {
            Write-LabLog -Message "Auto-detected license SKU with Exchange mailbox: $($mailboxSku.SkuPartNumber) ($($mailboxSku.SkuId)) — $($mailboxSku.PrepaidUnits.Enabled - $mailboxSku.ConsumedUnits) available" -Level Info

            foreach ($upn in $createdUpns) {
                $userObj = Get-MgUser -Filter "userPrincipalName eq '$upn'" -Property Id,AssignedLicenses -ErrorAction SilentlyContinue
                if (-not $userObj) { continue }

                $alreadyLicensed = $userObj.AssignedLicenses | Where-Object { $_.SkuId -eq $mailboxSku.SkuId }
                if ($alreadyLicensed) {
                    Write-LabLog -Message "License already assigned to $upn" -Level Info
                    continue
                }

                if ($PSCmdlet.ShouldProcess($upn, "Assign license $($mailboxSku.SkuPartNumber)")) {
                    Set-MgUserLicense -UserId $userObj.Id -AddLicenses @(@{ SkuId = $mailboxSku.SkuId }) -RemoveLicenses @() -ErrorAction Stop | Out-Null
                    Write-LabLog -Message "Assigned license $($mailboxSku.SkuPartNumber) to $upn" -Level Success
                }
            }
        }
        else {
            Write-LabLog -Message 'No SKU with Exchange Online mailbox service plan found. Users will not have mailboxes until licensed manually.' -Level Warning
        }
    }

    # --- Groups (both modes) ---
    foreach ($group in $Config.workloads.testUsers.groups) {
        $groupName = $group.displayName
        $mailNickname = $groupName -replace '[^a-zA-Z0-9-]', ''

        $existing = Get-MgGroup -Filter "displayName eq '$groupName'" -ErrorAction Stop
        if ($existing) {
            Write-LabLog -Message "Group already exists: $groupName" -Level Info
            $createdGroups.Add($groupName)
            continue
        }

        if ($PSCmdlet.ShouldProcess($groupName, 'Create group')) {
            $newGroup = New-MgGroup -DisplayName $groupName `
                -SecurityEnabled:$true `
                -MailEnabled:$false `
                -MailNickname $mailNickname `
                -ErrorAction Stop

            Write-LabLog -Message "Created group: $groupName" -Level Success

            foreach ($memberNickname in $group.members) {
                $memberUser = Get-LabUserByIdentity -Identity $memberNickname -DefaultDomain $Config.domain
                if ($memberUser) {
                    $memberUpn = [string]$memberUser.UserPrincipalName
                    New-MgGroupMember -GroupId $newGroup.Id `
                        -DirectoryObjectId $memberUser.Id `
                        -ErrorAction Stop
                    Write-LabLog -Message "Added $memberUpn to group $groupName" -Level Info
                }
                else {
                    Write-LabLog -Message "Member not found, skipping: $memberNickname@$($Config.domain)" -Level Warning
                }
            }

            $createdGroups.Add($groupName)
        }
    }

    return @{
        users  = $createdUpns.ToArray()
        groups = $createdGroups.ToArray()
    }
}

function Remove-TestUsers {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Config,

        [Parameter()]
        [PSCustomObject]$Manifest  # Reserved for manifest-based removal
    )

    $targetGroups = @()
    $targetUsers = @()

    $graphContext = Get-MgContext
    if (-not $graphContext -or [string]::IsNullOrWhiteSpace($graphContext.Account)) {
        throw 'Microsoft Graph context is not available for Remove-TestUsers.'
    }

    $mode = if ($Config.workloads.testUsers.PSObject.Properties['mode']) {
        $Config.workloads.testUsers.mode
    } else { 'create' }

    if ($Manifest) {
        foreach ($groupName in @($Manifest.groups)) {
            if (-not [string]::IsNullOrWhiteSpace($groupName)) {
                $targetGroups += [string]$groupName
            }
        }
        if ($mode -eq 'create') {
            foreach ($upn in @($Manifest.users)) {
                if (-not [string]::IsNullOrWhiteSpace($upn)) {
                    $targetUsers += [string]$upn
                }
            }
        }
    }

    if ($targetGroups.Count -eq 0) {
        foreach ($group in $Config.workloads.testUsers.groups) {
            $targetGroups += [string]$group.displayName
        }
    }

    if ($mode -eq 'create' -and $targetUsers.Count -eq 0) {
        foreach ($user in $Config.workloads.testUsers.users) {
            $targetUsers += "$($user.mailNickname)@$($Config.domain)"
        }
    }

    $targetGroups = @($targetGroups | Sort-Object -Unique)
    $targetUsers = @($targetUsers | Sort-Object -Unique)

    # Remove groups first (reverse dependency order)
    foreach ($groupName in $targetGroups) {

        try {
            $existing = Get-MgGroup -Filter "displayName eq '$groupName'" -ErrorAction Stop
        }
        catch {
            Write-LabLog -Message "Failed to query group '$groupName': $($_.Exception.Message)" -Level Warning
            continue
        }

        if (-not $existing) {
            Write-LabLog -Message "Group not found, skipping: $groupName" -Level Warning
            continue
        }

        if ($PSCmdlet.ShouldProcess($groupName, 'Remove group')) {
            try {
                Remove-MgGroup -GroupId $existing.Id -ErrorAction Stop
                Write-LabLog -Message "Removed group: $groupName" -Level Success
            }
            catch {
                Write-LabLog -Message "Failed to remove group '$groupName': $($_.Exception.Message)" -Level Warning
            }
        }
    }

    if ($mode -eq 'existing') {
        Write-LabLog -Message 'TestUsers mode is existing — skipping user deletion (users are not managed by this lab).' -Level Info
        return
    }

    # Remove users (create mode only)
    foreach ($upn in $targetUsers) {
        $existing = Get-MgUser -Filter "userPrincipalName eq '$upn'" -ErrorAction Stop
        if (-not $existing) {
            Write-LabLog -Message "User not found, skipping: $upn" -Level Warning
            continue
        }

        if ($PSCmdlet.ShouldProcess($upn, 'Remove user')) {
            Remove-MgUser -UserId $existing.Id -ErrorAction Stop
            Write-LabLog -Message "Removed user: $upn" -Level Success
        }
    }
}

Export-ModuleMember -Function @(
    'Deploy-TestUsers'
    'Remove-TestUsers'
)
