#Requires -Version 7.0

<#
.SYNOPSIS
    AI Gateway workload module for ai-agent-security.
.DESCRIPTION
    Deploys an APIM-based AI Gateway in front of the Foundry AOAI endpoint.
    Mirrors the Foundry portal "Add AI Gateway" flow with a documented Bicep:

        - APIM v2 (Basic v2 by default)
        - Foundry AOAI exposed as an APIM API with
          llm-token-limit + llm-emit-token-metric policies
        - System-assigned MI with Cognitive Services OpenAI User on Foundry
        - App Insights logger (when workloads.foundry creates App Insights)
        - Starter subscription for smoke testing

    Returns a manifest hashtable with the APIM resource ID, gateway URL,
    starter subscription key, and the OpenAI path so downstream consumers
    (and teardown) have stable identifiers.

    See docs/ai-gateway.md for usage and infra/ai-gateway.bicep for the
    template body.
#>

# ─── Deploy-AIGateway ────────────────────────────────────────────────────────

function Deploy-AIGateway {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Config,

        [Parameter()]
        [PSCustomObject]$FoundryManifest
    )

    $ag = if ($Config.workloads.PSObject.Properties['aiGateway']) { $Config.workloads.aiGateway } else { $null }
    if (-not $ag -or -not $ag.enabled) {
        Write-LabLog -Message 'AIGateway workload is disabled in config, skipping.' -Level Info
        return $null
    }

    $foundryCfg = $Config.workloads.foundry
    $subscriptionId = [string]$foundryCfg.subscriptionId
    $resourceGroup  = [string]$foundryCfg.resourceGroup
    $location       = if ($ag.PSObject.Properties['location']) { [string]$ag.location } else { [string]$foundryCfg.location }
    $foundryAccount = [string]$foundryCfg.accountName

    $apimName       = if ($ag.PSObject.Properties['name'] -and -not [string]::IsNullOrWhiteSpace([string]$ag.name)) {
        [string]$ag.name
    } else {
        "$($Config.prefix.ToLower())-aigw"
    }
    $skuName        = if ($ag.PSObject.Properties['sku']) { [string]$ag.sku } else { 'BasicV2' }
    $skuCapacity    = if ($ag.PSObject.Properties['capacity']) { [int]$ag.capacity } else { 1 }
    $publisherEmail = if ($ag.PSObject.Properties['publisherEmail']) { [string]$ag.publisherEmail } else { 'admin@contoso.com' }
    $publisherName  = if ($ag.PSObject.Properties['publisherName']) { [string]$ag.publisherName } else { "$($Config.prefix) AI Gateway" }
    $tokensPerMinute = if ($ag.PSObject.Properties['tokensPerMinute']) { [int]$ag.tokensPerMinute } else { 1000 }
    $monthlyQuota   = if ($ag.PSObject.Properties['monthlyTokenQuota']) { [int]$ag.monthlyTokenQuota } else { 0 }
    $apiName        = if ($ag.PSObject.Properties['openaiApiName']) { [string]$ag.openaiApiName } else { 'aoai' }
    $apiPath        = if ($ag.PSObject.Properties['openaiApiPath']) { [string]$ag.openaiApiPath } else { 'openai' }
    $apiVersion     = if ($ag.PSObject.Properties['openaiApiVersion']) { [string]$ag.openaiApiVersion } else { '2024-10-21' }

    # App Insights resource ID: prefer FoundryManifest (live deploy output),
    # fall back to config-driven resource name lookup.
    $appInsightsId = ''
    if ($FoundryManifest -and $FoundryManifest.PSObject.Properties['appInsightsResourceId']) {
        $appInsightsId = [string]$FoundryManifest.appInsightsResourceId
    }
    elseif ($ag.PSObject.Properties['appInsightsResourceId']) {
        $appInsightsId = [string]$ag.appInsightsResourceId
    }
    elseif (-not [string]::IsNullOrWhiteSpace($foundryAccount)) {
        # Follow Foundry infra's convention: App Insights name = <prefix>-appinsights
        $aiCandidate = "$($Config.prefix.ToLower())-appinsights"
        $appInsightsId = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.Insights/components/$aiCandidate"
    }

    $bicepPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'infra/ai-gateway.bicep'
    if (-not (Test-Path $bicepPath)) {
        throw "AIGateway Bicep not found at $bicepPath"
    }

    $deploymentName = "aisec-aigateway-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    $params = @{
        apimName          = $apimName
        location          = $location
        skuName           = $skuName
        skuCapacity       = $skuCapacity
        publisherEmail    = $publisherEmail
        publisherName     = $publisherName
        foundryAccountName = $foundryAccount
        appInsightsResourceId = $appInsightsId
        tokensPerMinute   = $tokensPerMinute
        monthlyTokenQuota = $monthlyQuota
        openaiApiName     = $apiName
        openaiApiPath     = $apiPath
        openaiApiVersion  = $apiVersion
    }

    if ($PSCmdlet.ShouldProcess("$apimName in $resourceGroup", "Deploy-AIGateway (Bicep)")) {
        Write-LabStep -StepName 'AIGateway' -Description "Deploying $apimName (SKU $skuName) — APIM first-time provision takes 15-45 minutes"

        # Pass-through to az deployment group create. az CLI is already the
        # standard for Bicep deploys in this repo (see FoundryInfra.psm1).
        $paramArgs = @()
        foreach ($k in $params.Keys) {
            $paramArgs += "$k=$($params[$k])"
        }

        $output = & az deployment group create `
            --name $deploymentName `
            --resource-group $resourceGroup `
            --subscription $subscriptionId `
            --template-file $bicepPath `
            --parameters $paramArgs `
            --query 'properties.outputs' `
            -o json 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "AI Gateway Bicep deploy failed: $output"
        }
        # az CLI prints Bicep upgrade warnings to stderr; 2>&1 merges them into
        # $output. Strip any prefix before the first '{' or '[' before parsing.
        $outputText = ($output | Out-String)
        $jsonStart  = $outputText.IndexOfAny([char[]]@('{','['))
        if ($jsonStart -lt 0) {
            throw "AI Gateway Bicep deploy returned no JSON output. Raw: $outputText"
        }
        $outputs = $outputText.Substring($jsonStart) | ConvertFrom-Json

        # Fetch the starter subscription's primary key (not exposed as a Bicep
        # output — must be read via data-plane listSecrets).
        $subKey = $null
        $keyResult = & az rest --method POST `
            --uri "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.ApiManagement/service/$apimName/subscriptions/aisec-demo/listSecrets?api-version=2024-06-01-preview" `
            --subscription $subscriptionId `
            --query 'primaryKey' -o tsv 2>&1
        # az rest can emit Python deprecation / bicep upgrade warnings on stderr
        # that get merged into $keyResult via 2>&1. Pick the first non-warning,
        # non-empty line as the key.
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace("$keyResult")) {
            $candidateKey = @($keyResult) | Where-Object {
                $line = [string]$_
                $line -and
                -not $line.StartsWith('WARNING', [StringComparison]::OrdinalIgnoreCase) -and
                -not $line.StartsWith('ERROR', [StringComparison]::OrdinalIgnoreCase) -and
                -not $line.Contains('SyntaxWarning')
            } | Select-Object -First 1
            if ($candidateKey) {
                $subKey = [string]$candidateKey
            }
        }
        if ([string]::IsNullOrWhiteSpace($subKey)) {
            Write-LabLog -Message "Could not fetch starter subscription key: $keyResult" -Level Warning
        }

        $manifest = @{
            apimName              = $outputs.apimName.value
            apimResourceId        = $outputs.apimResourceId.value
            apimPrincipalId       = $outputs.apimPrincipalId.value
            gatewayUrl            = $outputs.gatewayUrl.value
            openaiPath            = $outputs.openaiPath.value
            starterSubscriptionId = $outputs.starterSubscriptionId.value
            starterSubscriptionKey = $subKey
            foundryAccount        = $foundryAccount
            skuName               = $skuName
            tokensPerMinute       = $tokensPerMinute
            monthlyTokenQuota     = $monthlyQuota
        }

        Write-LabLog -Message "AI Gateway deployed: $($manifest.gatewayUrl)/$apiPath" -Level Success
        Write-LabLog -Message "Test with: curl -H 'Ocp-Apim-Subscription-Key: <key>' '$($manifest.gatewayUrl)/$apiPath/deployments/<deployment>/chat/completions?api-version=$apiVersion' -d '{...}'" -Level Info
        return $manifest
    }
    return $null
}

# ─── Remove-AIGateway ────────────────────────────────────────────────────────

function Remove-AIGateway {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Config,

        [Parameter()]
        [PSCustomObject]$Manifest
    )

    $ag = if ($Config.workloads.PSObject.Properties['aiGateway']) { $Config.workloads.aiGateway } else { $null }
    if (-not $ag -or -not $ag.enabled) {
        Write-LabLog -Message 'AIGateway workload is disabled in config, skipping removal.' -Level Info
        return
    }

    $foundryCfg = $Config.workloads.foundry
    $subscriptionId = [string]$foundryCfg.subscriptionId
    $resourceGroup  = [string]$foundryCfg.resourceGroup

    $apimName = if ($Manifest -and $Manifest.PSObject.Properties['apimName']) {
        [string]$Manifest.apimName
    }
    elseif ($ag.PSObject.Properties['name'] -and -not [string]::IsNullOrWhiteSpace([string]$ag.name)) {
        [string]$ag.name
    }
    else {
        "$($Config.prefix.ToLower())-aigw"
    }

    if ([string]::IsNullOrWhiteSpace($apimName)) {
        Write-LabLog -Message 'AI Gateway: no APIM name available — cannot remove.' -Level Warning
        return
    }

    if ($PSCmdlet.ShouldProcess("$apimName in $resourceGroup", 'Remove-AIGateway')) {
        Write-LabStep -StepName 'AIGateway' -Description "Removing $apimName — APIM deletion can take 15-30 minutes"

        $null = & az apim show --name $apimName --resource-group $resourceGroup --subscription $subscriptionId --query 'id' -o tsv 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-LabLog -Message "AI Gateway $apimName not found (already removed or never created)." -Level Info
            return
        }

        $delResult = & az apim delete --name $apimName --resource-group $resourceGroup --subscription $subscriptionId --yes --no-wait 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-LabLog -Message "AI Gateway $apimName deletion initiated (async)." -Level Success
        }
        else {
            Write-LabLog -Message "AI Gateway deletion failed: $delResult" -Level Warning
        }
    }
}

Export-ModuleMember -Function Deploy-AIGateway, Remove-AIGateway
