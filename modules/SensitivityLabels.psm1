#Requires -Version 7.0

<#
.SYNOPSIS
    Sensitivity labels and auto-labeling policy module for purview-lab-deployer.
#>

function Resolve-LabLabelIdentity {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$Prefix,

        [Parameter(Mandatory)]
        [string]$ConfiguredLabelName
    )

    $trimmed = $ConfiguredLabelName.Trim()
    if ([string]::IsNullOrWhiteSpace($trimmed)) {
        throw 'Configured label name cannot be empty.'
    }

    if ($trimmed.StartsWith("$Prefix-", [System.StringComparison]::OrdinalIgnoreCase)) {
        return ($trimmed -replace ' ', '-')
    }

    $parts = @($trimmed -split '\\|/|>')
    $normalizedParts = @()
    foreach ($part in $parts) {
        $candidate = $part.Trim()
        if (-not [string]::IsNullOrWhiteSpace($candidate)) {
            $normalizedParts += $candidate
        }
    }

    if ($normalizedParts.Count -eq 0) {
        throw "Configured label name '$ConfiguredLabelName' is invalid."
    }

    return ("$Prefix-$($normalizedParts -join '-')" -replace ' ', '-')
}

function Set-LabLabelPublication {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [string]$Prefix,

        [Parameter(Mandatory)]
        [string[]]$LabelIdentities
    )

    $requestedLabels = @($LabelIdentities | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
    if ($requestedLabels.Count -eq 0) {
        return $null
    }

    $publishableLabelSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($labelIdentity in $requestedLabels) {
        # Look up by identity first, then fall back to display name (handles timestamped internal names)
        $labelObject = $null
        try {
            $labelObject = Get-Label -Identity $labelIdentity -ErrorAction Stop
            if ($labelObject.Mode -eq 'PendingDeletion') { $labelObject = $null }
        }
        catch { $null = $_ }

        if (-not $labelObject) {
            try {
                $labelObject = Get-Label -ErrorAction Stop | Where-Object { $_.DisplayName -eq $labelIdentity -and $_.Mode -ne 'PendingDeletion' } | Select-Object -First 1
            }
            catch { $null = $_ }
        }

        if (-not $labelObject) {
            Write-LabLog "Skipping publication target '$labelIdentity' because the label was not found." -Level Warning
            continue
        }

        $isLabelGroup = $false
        if (($labelObject.PSObject.Properties.Name -contains 'IsLabelGroup') -and $labelObject.IsLabelGroup) {
            $isLabelGroup = $true
        }

        if ($isLabelGroup) {
            Write-LabLog "Skipping non-publishable label group: $labelIdentity" -Level Warning
            continue
        }

        # Use GUID for reliable identity resolution (handles timestamped internal names)
        $resolvedLabelIdentity = if ($labelObject.Guid) {
            [string]$labelObject.Guid
        }
        elseif (($labelObject.PSObject.Properties.Name -contains 'Name') -and -not [string]::IsNullOrWhiteSpace([string]$labelObject.Name)) {
            [string]$labelObject.Name
        }
        else {
            [string]$labelIdentity
        }

        $null = $publishableLabelSet.Add($resolvedLabelIdentity)
    }

    $uniqueLabels = [string[]]@($publishableLabelSet | Sort-Object -Unique)
    if ($uniqueLabels.Count -eq 0) {
        Write-LabLog 'No publishable labels found after filtering out unavailable/non-publishable entries.' -Level Warning
        return $null
    }

    $policyName = "$Prefix-Sensitivity-Labels-Publish"
    $ruleName = "$policyName-rule"
    $newLabelPolicyCommand = Get-Command -Name New-LabelPolicy -ErrorAction Stop
    $setLabelPolicyCommand = Get-Command -Name Set-LabelPolicy -ErrorAction Stop
    $newLabelParameterName = if ($newLabelPolicyCommand.Parameters.ContainsKey('Labels')) {
        'Labels'
    }
    elseif ($newLabelPolicyCommand.Parameters.ContainsKey('ScopedLabels')) {
        'ScopedLabels'
    }
    elseif ($newLabelPolicyCommand.Parameters.ContainsKey('AddLabels')) {
        'AddLabels'
    }
    else {
        $null
    }

    $createLocationParams = @{}
    if ($newLabelPolicyCommand.Parameters.ContainsKey('ExchangeLocation')) {
        $createLocationParams['ExchangeLocation'] = 'All'
    }
    if ($newLabelPolicyCommand.Parameters.ContainsKey('ModernGroupLocation')) {
        $createLocationParams['ModernGroupLocation'] = 'All'
    }
    elseif ($newLabelPolicyCommand.Parameters.ContainsKey('UnifiedGroupLocation')) {
        $createLocationParams['UnifiedGroupLocation'] = 'All'
    }

    if ($createLocationParams.Count -eq 0) {
        throw 'Unable to determine supported label policy location parameters for New-LabelPolicy.'
    }

    $existingPolicy = $null
    try {
        $existingPolicy = Get-LabelPolicy -Identity $policyName -ErrorAction Stop
    }
    catch {
        $null = $_
    }

    if ($existingPolicy) {
        if ($PSCmdlet.ShouldProcess($policyName, 'Update label publication policy')) {
            $normalizePolicyLabels = {
                param([object[]]$RawValues)
                $normalized = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
                foreach ($raw in @($RawValues)) {
                    if ($null -eq $raw) {
                        continue
                    }

                    $candidate = $null
                    if ($raw -is [string]) {
                        $candidate = [string]$raw
                    }
                    elseif (($raw.PSObject.Properties.Name -contains 'Name') -and -not [string]::IsNullOrWhiteSpace([string]$raw.Name)) {
                        $candidate = [string]$raw.Name
                    }
                    elseif (($raw.PSObject.Properties.Name -contains 'DisplayName') -and -not [string]::IsNullOrWhiteSpace([string]$raw.DisplayName)) {
                        $candidate = [string]$raw.DisplayName
                    }
                    else {
                        $candidate = [string]$raw
                    }

                    $candidate = $candidate.Trim()
                    if ([string]::IsNullOrWhiteSpace($candidate)) {
                        continue
                    }

                    if ($candidate -match '^(?<label>.+?)\s+[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
                        $candidate = $Matches['label'].Trim()
                    }

                    if (-not [string]::IsNullOrWhiteSpace($candidate)) {
                        $null = $normalized.Add($candidate)
                    }
                }
                return [string[]]@($normalized)
            }

            $setParams = @{
                Identity    = $policyName
                ErrorAction = 'Stop'
            }
            $hasSetUpdates = $false
            $existingPolicyLabels = @()
            foreach ($propName in @('Labels', 'ScopedLabels')) {
                if (($existingPolicy.PSObject.Properties.Name -contains $propName) -and $null -ne $existingPolicy.$propName) {
                    $existingPolicyLabels = & $normalizePolicyLabels $existingPolicy.$propName
                    break
                }
            }

            $existingLabelGroups = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            foreach ($policyLabel in @($existingPolicyLabels)) {
                try {
                    $existingLabel = Get-Label -Identity $policyLabel -ErrorAction Stop
                    if (($existingLabel.PSObject.Properties.Name -contains 'IsLabelGroup') -and $existingLabel.IsLabelGroup) {
                        $labelName = if (($existingLabel.PSObject.Properties.Name -contains 'Name') -and -not [string]::IsNullOrWhiteSpace([string]$existingLabel.Name)) {
                            [string]$existingLabel.Name
                        }
                        else {
                            [string]$policyLabel
                        }

                        if (-not [string]::IsNullOrWhiteSpace($labelName)) {
                            $null = $existingLabelGroups.Add($labelName.Trim())
                        }
                    }
                }
                catch {
                    $null = $_
                }
            }

            $effectiveLabels = [string[]]@((@($uniqueLabels) + @($existingLabelGroups)) | Sort-Object -Unique)
            if (($existingLabelGroups.Count -gt 0) -and ($effectiveLabels.Count -gt $uniqueLabels.Count)) {
                Write-LabLog "Preserving existing label group assignments on publication policy '$policyName' to avoid unsupported unpublish operations." -Level Info
            }

            if ($setLabelPolicyCommand.Parameters.ContainsKey('Labels')) {
                $setParams['Labels'] = $effectiveLabels
                $hasSetUpdates = $true
            }
            elseif ($setLabelPolicyCommand.Parameters.ContainsKey('ScopedLabels')) {
                $setParams['ScopedLabels'] = $effectiveLabels
                $hasSetUpdates = $true
            }
            else {
                $labelsToAdd = @($effectiveLabels | Where-Object { $_ -notin $existingPolicyLabels })
                $labelsToRemove = @($existingPolicyLabels | Where-Object { $_ -notin $effectiveLabels })
                if ($setLabelPolicyCommand.Parameters.ContainsKey('AddLabels') -and $labelsToAdd.Count -gt 0) {
                    $setParams['AddLabels'] = $labelsToAdd
                    $hasSetUpdates = $true
                }
                if ($setLabelPolicyCommand.Parameters.ContainsKey('RemoveLabels') -and $labelsToRemove.Count -gt 0) {
                    $setParams['RemoveLabels'] = $labelsToRemove
                    $hasSetUpdates = $true
                }
            }

            foreach ($entry in $createLocationParams.GetEnumerator()) {
                if ($setLabelPolicyCommand.Parameters.ContainsKey($entry.Key)) {
                    $setParams[$entry.Key] = $entry.Value
                    $hasSetUpdates = $true
                }
                else {
                    $addParamName = "Add$($entry.Key)"
                    if ($setLabelPolicyCommand.Parameters.ContainsKey($addParamName)) {
                        $setParams[$addParamName] = $entry.Value
                        $hasSetUpdates = $true
                    }
                }
            }

            if ($hasSetUpdates) {
                try {
                    Set-LabelPolicy @setParams | Out-Null
                    Write-LabLog "Updated label publication policy: $policyName" -Level Success
                }
                catch {
                    # LabelAlreadyPublishedException is benign — it means the labels are
                    # already published (by this or another policy) and there's nothing to
                    # do. Log as Info and continue rather than failing the workload.
                    if ($_.Exception.Message -match 'LabelAlreadyPublishedException|already published') {
                        Write-LabLog "Label publication policy '$policyName' — labels already published (idempotent no-op)." -Level Info
                    }
                    else {
                        throw
                    }
                }
            }
            else {
                Write-LabLog "No supported Set-LabelPolicy parameters were available to update labels/locations for: $policyName" -Level Warning
            }
        }
    }
    else {
        if ($PSCmdlet.ShouldProcess($policyName, 'Create label publication policy')) {
            $newParams = @{
                Name        = $policyName
                Comment     = 'Created by purview-lab-deployer'
                ErrorAction = 'Stop'
            }
            if ($newLabelParameterName) {
                $newParams[$newLabelParameterName] = $uniqueLabels
            }
            else {
                throw "New-LabelPolicy does not support a label-assignment parameter (Labels/ScopedLabels/AddLabels) in this environment."
            }
            foreach ($entry in $createLocationParams.GetEnumerator()) {
                $newParams[$entry.Key] = $entry.Value
            }
            New-LabelPolicy @newParams | Out-Null
            Write-LabLog "Created label publication policy: $policyName" -Level Success
        }
    }

    $getLabelPolicyRuleCommand = Get-Command -Name Get-LabelPolicyRule -ErrorAction SilentlyContinue
    $newLabelPolicyRuleCommand = Get-Command -Name New-LabelPolicyRule -ErrorAction SilentlyContinue

    if (-not $getLabelPolicyRuleCommand -or -not $newLabelPolicyRuleCommand) {
        Write-LabLog "Label policy rule cmdlets are unavailable in this environment. Publication will continue with policy '$policyName' only." -Level Warning
        return [PSCustomObject]@{
            name     = $policyName
            ruleName = $null
            labels   = $uniqueLabels
        }
    }

    $existingRule = $null
    try {
        $existingRule = Get-LabelPolicyRule -Identity $ruleName -ErrorAction Stop
    }
    catch {
        $null = $_
    }

    if (-not $existingRule) {
        if ($PSCmdlet.ShouldProcess($ruleName, 'Create label publication rule')) {
            New-LabelPolicyRule -Name $ruleName -Policy $policyName -ErrorAction Stop | Out-Null
            Write-LabLog "Created label publication rule: $ruleName" -Level Success
        }
    }

    return [PSCustomObject]@{
        name   = $policyName
        ruleName = $ruleName
        labels = $uniqueLabels
    }
}

function Publish-SensitivityLabels {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Config
    )

    if (-not $Config.workloads -or -not $Config.workloads.sensitivityLabels -or -not $Config.workloads.sensitivityLabels.enabled) {
        Write-LabLog 'Sensitivity labels workload is disabled in config. Skipping label publication.' -Level Warning
        return $null
    }

    $labelsToPublish = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($label in @($Config.workloads.sensitivityLabels.labels)) {
        $parentIdentity = "$($Config.prefix)-$($label.name)"
        try {
            Get-Label -Identity $parentIdentity -ErrorAction Stop | Out-Null
            $null = $labelsToPublish.Add($parentIdentity)
        }
        catch {
            Write-LabLog "Label not found, cannot publish yet: $parentIdentity" -Level Warning
        }

        foreach ($sublabel in @($label.sublabels)) {
            $sublabelIdentity = "$($Config.prefix)-$($label.name)-$($sublabel.name)" -replace ' ', '-'
            try {
                Get-Label -Identity $sublabelIdentity -ErrorAction Stop | Out-Null
                $null = $labelsToPublish.Add($sublabelIdentity)
            }
            catch {
                Write-LabLog "Sublabel not found, cannot publish yet: $sublabelIdentity" -Level Warning
            }
        }
    }

    if ($labelsToPublish.Count -eq 0) {
        Write-LabLog 'No existing labels were found to publish.' -Level Warning
        return [PSCustomObject]@{
            publicationPolicy = $null
            publishedLabels   = @()
        }
    }

    $publicationPolicy = Set-LabLabelPublication -Prefix $Config.prefix -LabelIdentities ([string[]]@($labelsToPublish)) -WhatIf:$WhatIfPreference
    return [PSCustomObject]@{
        publicationPolicy = $publicationPolicy
        publishedLabels   = ([string[]]@($labelsToPublish | Sort-Object))
    }
}

function Deploy-SensitivityLabels {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Config
    )

    $manifest = [ordered]@{
        labels           = @()
        autoLabelPolicies = @()
        publicationPolicy = $null
    }

    $labelConfig = $Config.workloads.sensitivityLabels
    $unavailableLabels = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $labelsToPublish = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $newLabelCommand = Get-Command -Name New-Label -ErrorAction Stop
    $supportsIsLabelGroup = $newLabelCommand.Parameters.ContainsKey('IsLabelGroup')
    if (-not $supportsIsLabelGroup) {
        Write-LabLog "New-Label does not support -IsLabelGroup in this environment. Creating parent labels without explicit label-group flag." -Level Warning
    }

    # --- Deploy parent labels and sublabels ---
    foreach ($label in $labelConfig.labels) {
        $parentName = "$($Config.prefix)-$($label.name)"

        # Look up by identity; if PendingDeletion, search for an active duplicate
        $existingLabel = $null
        try {
            $candidates = @(Get-Label -ErrorAction Stop | Where-Object { $_.DisplayName -eq $parentName })
            $existingLabel = $candidates | Where-Object { $_.Mode -ne 'PendingDeletion' } | Select-Object -First 1
            if (-not $existingLabel -and ($candidates | Where-Object { $_.Mode -eq 'PendingDeletion' })) {
                Write-LabLog "Label '$parentName' exists only in PendingDeletion state. Will create a new instance." -Level Warning
            }
        }
        catch {
            $null = $_ # Label does not exist
        }

        if ($existingLabel) {
            Write-LabLog "Label already exists: $parentName (IsLabelGroup=$($existingLabel.IsLabelGroup))" -Level Info
            $null = $labelsToPublish.Add($parentName)
        }
        else {
            if ($PSCmdlet.ShouldProcess($parentName, 'Create sensitivity label group')) {
                # Use a unique internal name to avoid collisions with PendingDeletion ghosts (max 64 chars)
                $suffix = (Get-Date -Format 'yyyyMMddHHmm')
                $maxBase = 64 - $suffix.Length - 1
                $baseName = if ($parentName.Length -gt $maxBase) { $parentName.Substring(0, $maxBase) } else { $parentName }
                $internalName = "$baseName-$suffix"
                $parentParams = @{
                    Name        = $internalName
                    DisplayName = $parentName
                    Tooltip     = $label.tooltip
                    Comment     = 'Created by purview-lab-deployer'
                    ErrorAction = 'Stop'
                }
                if ($supportsIsLabelGroup) {
                    $parentParams['IsLabelGroup'] = $true
                }
                New-Label @parentParams | Out-Null

                Write-LabLog "Created label group: $parentName" -Level Success
                $null = $labelsToPublish.Add($parentName)
            }
        }

        $parentEntry = [ordered]@{
            name      = $parentName
            sublabels = @()
        }

        # Get parent label ID for sublabel creation (prefer active over PendingDeletion)
        $parentLabel = $null
        try {
            $parentLabel = Get-Label -ErrorAction Stop | Where-Object { $_.DisplayName -eq $parentName -and $_.Mode -ne 'PendingDeletion' } | Select-Object -First 1
        }
        catch { $null = $_ }
        if (-not $parentLabel) {
            Write-LabLog "Could not retrieve active parent label $parentName for sublabel creation" -Level Warning
            $null = $unavailableLabels.Add($parentName)
        }

        foreach ($sublabel in $label.sublabels) {
            $sublabelIdentity = "$($Config.prefix)-$($label.name)-$($sublabel.name)" -replace ' ', '-'
            $sublabelDisplay = "$($Config.prefix)-$($label.name)-$($sublabel.name)"

            $sublabelExists = $false
            try {
                $sublabelMatch = Get-Label -ErrorAction Stop | Where-Object { $_.DisplayName -eq $sublabelDisplay -and $_.Mode -ne 'PendingDeletion' } | Select-Object -First 1
                if ($sublabelMatch) {
                    $sublabelExists = $true
                    Write-LabLog "Sublabel already exists: $sublabelIdentity" -Level Info
                }
                else {
                    Write-LabLog "Sublabel not found, will create: $sublabelIdentity" -Level Info
                }
            }
            catch {
                Write-LabLog "Sublabel not found, will create: $sublabelIdentity" -Level Info
            }

            if (-not $sublabelExists -and $null -ne $parentLabel) {
                if ($PSCmdlet.ShouldProcess($sublabelIdentity, 'Create sensitivity sublabel')) {
                    try {
                        $suffix = (Get-Date -Format 'yyyyMMddHHmm')
                        $maxBase = 64 - $suffix.Length - 1
                        $baseName = if ($sublabelIdentity.Length -gt $maxBase) { $sublabelIdentity.Substring(0, $maxBase) } else { $sublabelIdentity }
                        $sublabelInternalName = "$baseName-$suffix"
                        New-Label `
                            -Name $sublabelInternalName `
                            -DisplayName $sublabelDisplay `
                            -ParentId $parentLabel.Guid `
                            -Tooltip $sublabel.tooltip `
                            -ContentType "File,Email" `
                            -ErrorAction Stop | Out-Null
                        $newSublabel = Get-Label -ErrorAction Stop | Where-Object { $_.DisplayName -eq $sublabelDisplay -and $_.Mode -ne 'PendingDeletion' } | Select-Object -First 1

                        Write-LabLog "Created sublabel: $sublabelIdentity" -Level Success
                        $null = $labelsToPublish.Add($sublabelDisplay)

                        # Apply encryption settings using GUID for reliable identity
                        $sublabelId = if ($newSublabel) { $newSublabel.Guid } else { $sublabelInternalName }
                        if ($sublabel.encryption) {
                            Set-Label -Identity $sublabelId `
                                -EncryptionEnabled $true `
                                -EncryptionProtectionType 'Template' `
                                -ErrorAction Stop | Out-Null

                            Write-LabLog "Enabled encryption on sublabel: $sublabelIdentity" -Level Success
                        }

                        # Apply content marking settings
                        if ($sublabel.contentMarking) {
                            $markingParams = @{
                                Identity = $sublabelId
                            }

                            if ($sublabel.contentMarking.headerText) {
                                $markingParams['ApplyContentMarkingHeaderEnabled'] = $true
                                $markingParams['ApplyContentMarkingHeaderText'] = $sublabel.contentMarking.headerText
                                $markingParams['ApplyContentMarkingHeaderFontSize'] = 10
                                $markingParams['ApplyContentMarkingHeaderFontColor'] = '#000000'
                                $markingParams['ApplyContentMarkingHeaderAlignment'] = 'Center'
                            }

                            if ($sublabel.contentMarking.footerText) {
                                $markingParams['ApplyContentMarkingFooterEnabled'] = $true
                                $markingParams['ApplyContentMarkingFooterText'] = $sublabel.contentMarking.footerText
                                $markingParams['ApplyContentMarkingFooterFontSize'] = 8
                                $markingParams['ApplyContentMarkingFooterFontColor'] = '#000000'
                            }

                            Set-Label @markingParams -ErrorAction Stop | Out-Null
                            Write-LabLog "Applied content marking on sublabel: $sublabelIdentity" -Level Success
                        }
                    }
                    catch {
                        Write-LabLog "Failed to create sublabel $sublabelIdentity`: $_" -Level Error
                        throw
                    }
                }
            }
            elseif ($sublabelExists) {
                $null = $labelsToPublish.Add($sublabelDisplay)
            }
            elseif ($null -eq $parentLabel) {
                $null = $unavailableLabels.Add($sublabelIdentity)
            }

            $parentEntry.sublabels += $sublabelIdentity
        }

        $manifest.labels += [PSCustomObject]$parentEntry
    }

    # Ensure created/existing labels are published.
    if ($labelsToPublish.Count -gt 0) {
        $publicationPolicy = Set-LabLabelPublication -Prefix $Config.prefix -LabelIdentities ([string[]]@($labelsToPublish)) -WhatIf:$WhatIfPreference
        if ($publicationPolicy) {
            $manifest.publicationPolicy = $publicationPolicy
        }
    }

    # --- Deploy auto-labeling policies ---
    foreach ($policy in $labelConfig.autoLabelPolicies) {
        $policyName = "$($Config.prefix)-$($policy.name)"

        $policyExists = $false
        try {
            Get-AutoSensitivityLabelPolicy -Identity $policyName -ErrorAction Stop | Out-Null
            $policyExists = $true
            Write-LabLog "Auto-label policy already exists: $policyName" -Level Info
        }
        catch {
            Write-LabLog "Auto-label policy not found, will create: $policyName" -Level Info
        }

        if (-not $policyExists) {
            if ($PSCmdlet.ShouldProcess($policyName, 'Create auto-sensitivity label policy')) {
                # Resolve the target label identity with prefix and normalized separators.
                $targetLabel = Resolve-LabLabelIdentity -Prefix $Config.prefix -ConfiguredLabelName $policy.labelName

                if ($unavailableLabels.Contains($targetLabel)) {
                    Write-LabLog "Skipping auto-label policy '$policyName' because target label '$targetLabel' is unavailable in this run." -Level Warning
                    continue
                }

                try {
                    Invoke-LabRetry -MaxAttempts 12 -DelaySeconds 30 -OperationName "wait for label '$targetLabel'" -ScriptBlock {
                        Get-Label -Identity $targetLabel -ErrorAction Stop | Out-Null
                    }
                }
                catch {
                    Write-LabLog "Skipping auto-label policy '$policyName': target label '$targetLabel' not found after 12 attempts (6 min)." -Level Warning
                    continue
                }

                $policyParams = @{
                    Name                 = $policyName
                    ApplySensitivityLabel = $targetLabel
                }

                foreach ($location in $policy.locations) {
                    switch ($location) {
                        'Exchange'   { $policyParams['ExchangeLocation'] = 'All' }
                        'SharePoint' { $policyParams['SharePointLocation'] = 'All' }
                        'OneDrive'   { $policyParams['OneDriveLocation'] = 'All' }
                    }
                }

                New-AutoSensitivityLabelPolicy @policyParams | Out-Null
                Write-LabLog "Created auto-label policy: $policyName" -Level Success

                # Create rule with sensitive information types
                $ruleName = "$policyName-rule"
                $sitArray = @()
                foreach ($sit in $policy.sensitiveInfoTypes) {
                    $sitArray += @{
                        Name           = $sit
                        MinCount       = 1
                        MaxConfidence  = 100
                        MinConfidence  = 75
                    }
                }

                New-AutoSensitivityLabelRule `
                    -Policy $policyName `
                    -Name $ruleName `
                    -ContentContainsSensitiveInformation $sitArray | Out-Null

                Write-LabLog "Created auto-label rule: $ruleName" -Level Success
            }
        }

        $manifest.autoLabelPolicies += [ordered]@{
            name     = $policyName
            ruleName = "$policyName-rule"
        }
    }

    return [PSCustomObject]$manifest
}

function Remove-SensitivityLabels {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Config,

        [Parameter()]
        [PSCustomObject]$Manifest  # Reserved for manifest-based removal
    )

    $targetAutoLabelPolicies = @()
    $targetLabels = @()
    $targetPublicationPolicy = [PSCustomObject]@{
        name     = "$($Config.prefix)-Sensitivity-Labels-Publish"
        ruleName = "$($Config.prefix)-Sensitivity-Labels-Publish-rule"
    }

    if ($Manifest) {
        foreach ($manifestPolicy in @($Manifest.autoLabelPolicies)) {
            if ($manifestPolicy -is [string]) {
                $targetAutoLabelPolicies += [PSCustomObject]@{
                    name     = [string]$manifestPolicy
                    ruleName = "$manifestPolicy-rule"
                }
            }
            elseif ($manifestPolicy.name) {
                $targetAutoLabelPolicies += [PSCustomObject]@{
                    name     = [string]$manifestPolicy.name
                    ruleName = [string]$manifestPolicy.ruleName
                }
            }
        }

        foreach ($manifestLabel in @($Manifest.labels)) {
            if ($manifestLabel.name) {
                $targetLabels += [PSCustomObject]@{
                    name      = [string]$manifestLabel.name
                    sublabels = @($manifestLabel.sublabels)
                }
            }
        }

        if ($Manifest.publicationPolicy) {
            if ($Manifest.publicationPolicy.name) {
                $targetPublicationPolicy.name = [string]$Manifest.publicationPolicy.name
            }
            if ($Manifest.publicationPolicy.ruleName) {
                $targetPublicationPolicy.ruleName = [string]$Manifest.publicationPolicy.ruleName
            }
        }
    }

    if ($targetAutoLabelPolicies.Count -eq 0) {
        foreach ($policy in $Config.workloads.sensitivityLabels.autoLabelPolicies) {
            $policyName = "$($Config.prefix)-$($policy.name)"
            $targetAutoLabelPolicies += [PSCustomObject]@{
                name     = $policyName
                ruleName = "$policyName-rule"
            }
        }
    }

    if ($targetLabels.Count -eq 0) {
        foreach ($label in $Config.workloads.sensitivityLabels.labels) {
            $parentName = "$($Config.prefix)-$($label.name)"
            $sublabels = @()
            foreach ($sublabel in @($label.sublabels)) {
                $sublabels += "$($Config.prefix)-$($label.name)-$($sublabel.name)" -replace ' ', '-'
            }

            $targetLabels += [PSCustomObject]@{
                name      = $parentName
                sublabels = $sublabels
            }
        }
    }

    # --- Remove auto-label policies and rules first ---
    foreach ($policy in $targetAutoLabelPolicies) {
        $policyName = $policy.name
        $ruleName = $policy.ruleName

        # Remove rule
        try {
            Get-AutoSensitivityLabelRule -Policy $policyName -ErrorAction Stop | Out-Null
            if ($PSCmdlet.ShouldProcess($ruleName, 'Remove auto-sensitivity label rule')) {
                Remove-AutoSensitivityLabelRule -Identity $ruleName -Confirm:$false -ErrorAction Stop
                Write-LabLog "Removed auto-label rule: $ruleName" -Level Success
            }
        }
        catch {
            Write-LabLog "Auto-label rule not found or already removed: $ruleName" -Level Info
        }

        # Remove policy
        try {
            Get-AutoSensitivityLabelPolicy -Identity $policyName -ErrorAction Stop | Out-Null
            if ($PSCmdlet.ShouldProcess($policyName, 'Remove auto-sensitivity label policy')) {
                Remove-AutoSensitivityLabelPolicy -Identity $policyName -Confirm:$false -ErrorAction Stop
                Write-LabLog "Removed auto-label policy: $policyName" -Level Success
            }
        }
        catch {
            Write-LabLog "Auto-label policy not found or already removed: $policyName" -Level Info
        }
    }

    # Remove label publication policy/rule before label deletion.
    try {
        Get-LabelPolicyRule -Identity $targetPublicationPolicy.ruleName -ErrorAction Stop | Out-Null
        if ($PSCmdlet.ShouldProcess($targetPublicationPolicy.ruleName, 'Remove label publication rule')) {
            Remove-LabelPolicyRule -Identity $targetPublicationPolicy.ruleName -Confirm:$false -ErrorAction Stop
            Write-LabLog "Removed label publication rule: $($targetPublicationPolicy.ruleName)" -Level Success
        }
    }
    catch {
        Write-LabLog "Label publication rule not found or already removed: $($targetPublicationPolicy.ruleName)" -Level Info
    }

    try {
        Get-LabelPolicy -Identity $targetPublicationPolicy.name -ErrorAction Stop | Out-Null
        if ($PSCmdlet.ShouldProcess($targetPublicationPolicy.name, 'Remove label publication policy')) {
            Remove-LabelPolicy -Identity $targetPublicationPolicy.name -Confirm:$false -ErrorAction Stop
            Write-LabLog "Removed label publication policy: $($targetPublicationPolicy.name)" -Level Success
        }
    }
    catch {
        Write-LabLog "Label publication policy not found or already removed: $($targetPublicationPolicy.name)" -Level Info
    }

    # --- Remove sublabels first, then parent labels (reverse order) ---
    $reversedLabels = @($targetLabels)
    [array]::Reverse($reversedLabels)

    foreach ($labelEntry in $reversedLabels) {
        # Remove sublabels
        if ($labelEntry.sublabels) {
            $reversedSublabels = @($labelEntry.sublabels)
            [array]::Reverse($reversedSublabels)

            foreach ($sublabelIdentity in $reversedSublabels) {
                try {
                    Get-Label -Identity $sublabelIdentity -ErrorAction Stop | Out-Null
                    if ($PSCmdlet.ShouldProcess($sublabelIdentity, 'Remove sensitivity sublabel')) {
                        Remove-Label -Identity $sublabelIdentity -Confirm:$false -ErrorAction Stop
                        Write-LabLog "Removed sublabel: $sublabelIdentity" -Level Success
                    }
                }
                catch {
                    Write-LabLog "Sublabel not found or already removed: $sublabelIdentity" -Level Info
                }
            }
        }

        # Remove parent label
        $parentName = $labelEntry.name

        try {
            Get-Label -Identity $parentName -ErrorAction Stop | Out-Null
            if ($PSCmdlet.ShouldProcess($parentName, 'Remove sensitivity label')) {
                Remove-Label -Identity $parentName -Confirm:$false -ErrorAction Stop
                Write-LabLog "Removed label: $parentName" -Level Success
            }
        }
        catch {
            Write-LabLog "Label not found or already removed: $parentName" -Level Info
        }
    }
}

Export-ModuleMember -Function @(
    'Publish-SensitivityLabels'
    'Deploy-SensitivityLabels'
    'Remove-SensitivityLabels'
)
