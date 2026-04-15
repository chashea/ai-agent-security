#Requires -Version 7.0

<#
.SYNOPSIS
    Publishes Foundry applications as Microsoft Agent 365 digital workers.
.DESCRIPTION
    Wraps the Foundry /microsoft365/publish REST endpoint used by the upstream
    FoundryA365 sample (microsoft-foundry/foundry-samples samples/csharp/FoundryA365).
    Submits a digital worker request per Foundry application; the request lands
    in the Microsoft 365 admin center at
    https://admin.cloud.microsoft/?#/agents/all/requested and a tenant admin
    must approve it before the agent appears in the Agent 365 registry.

    This module does NOT create Foundry applications, bot services, Entra app
    registrations, or agent runtimes. Those must already exist — Deploy-Foundry
    (Steps 5 and 6) provisions them. Each publish request reuses the per-agent
    bot msaAppId captured in the Foundry deployment manifest as the
    digital worker botId.

    Preview / opt-in: Microsoft has committed to auto-registering Foundry apps
    into Agent 365, but that capability is not live as of 2026-04. Until it is,
    this path is the only way to push existing Foundry apps into the A365 registry.
#>

$script:A365PublishApiVersion = 'v2.0'

function Publish-FoundryAgentAsDigitalWorker {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [string]$Location,
        [Parameter(Mandatory)] [string]$SubscriptionId,
        [Parameter(Mandatory)] [string]$ResourceGroup,
        [Parameter(Mandatory)] [string]$AccountName,
        [Parameter(Mandatory)] [string]$ProjectName,
        [Parameter(Mandatory)] [string]$ApplicationName,
        [Parameter(Mandatory)] [string]$BotId,
        [Parameter()]          [string]$AppVersion          = '1.0.0',
        [Parameter()]          [string]$ShortDescription    = 'Foundry agent digital worker',
        [Parameter()]          [string]$FullDescription     = 'Foundry agent published to Microsoft Agent 365 as a digital worker.',
        [Parameter()]          [string]$DeveloperName       = 'AI Agent Security Lab',
        [Parameter()]          [string]$DeveloperWebsiteUrl = 'https://github.com/chashea/ai-agent-security',
        [Parameter()]          [string]$PrivacyUrl          = 'https://privacy.microsoft.com',
        [Parameter()]          [string]$TermsOfUseUrl       = 'https://www.microsoft.com/legal/terms-of-use'
    )

    $workspace = "$AccountName@$ProjectName@AML"
    $uri = "https://$Location.api.azureml.ms/agent-asset/$script:A365PublishApiVersion/" +
           "subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/" +
           "providers/Microsoft.MachineLearningServices/workspaces/$workspace/microsoft365/publish"

    $bodyObj = [ordered]@{
        botId                  = $BotId
        publishAsDigitalWorker = $true
        appPublishScope        = 'Tenant'
        subscriptionId         = $SubscriptionId
        agentName              = $ApplicationName
        appVersion             = $AppVersion
        shortDescription       = $ShortDescription
        fullDescription        = $FullDescription
        developerName          = $DeveloperName
        developerWebsiteUrl    = $DeveloperWebsiteUrl
        privacyUrl             = $PrivacyUrl
        termsOfUseUrl          = $TermsOfUseUrl
        useAgenticUserTemplate = $true
        agenticUserTemplate    = [ordered]@{
            Id                       = 'digitalWorkerTemplate'
            File                     = 'agenticUserTemplateManifest.json'
            SchemaVersion            = '0.1.0-preview'
            AgentIdentityBlueprintId = $BotId
            CommunicationProtocol    = 'activityProtocol'
        }
    }
    $bodyJson = $bodyObj | ConvertTo-Json -Depth 10

    if (-not $PSCmdlet.ShouldProcess($ApplicationName, 'Publish as Agent 365 digital worker')) {
        return [pscustomobject]@{
            applicationName = $ApplicationName
            botId           = $BotId
            appVersion      = $AppVersion
            status          = 'whatif'
            uri             = $uri
        }
    }

    $token   = Get-FoundryDataToken
    $headers = @{
        'Authorization' = "Bearer $token"
        'Content-Type'  = 'application/json'
        'Accept'        = 'application/json'
    }

    try {
        $resp = Invoke-LabRetry -ScriptBlock {
            $r = Invoke-WebRequest -Uri $uri -Method Post -Headers $headers -Body $bodyJson `
                                   -SkipHttpErrorCheck -ErrorAction Stop
            $sc = [int]$r.StatusCode
            if ($sc -eq 429 -or $sc -eq 503) {
                throw "Transient HTTP $sc from Agent 365 publish for '$ApplicationName'"
            }
            $r
        } -MaxAttempts 3 -DelaySeconds 10 -OperationName "Agent 365 publish ($ApplicationName)"
        $status = [int]$resp.StatusCode

        if ($status -ge 400) {
            # "version already exists" mirrors upstream sample handling — non-fatal.
            $errBody = try { $resp.Content | ConvertFrom-Json } catch { $null }
            if ($errBody -and $errBody.PSObject.Properties['error'] -and $errBody.error -and
                $errBody.error.PSObject.Properties['code'] -and
                $errBody.error.code -eq 'UserError' -and
                $errBody.error.PSObject.Properties['message'] -and
                $errBody.error.message -like '*version already exists*') {
                Write-LabLog -Message "Digital worker already published for '$ApplicationName' at v$AppVersion — skipping." -Level Info
                return [pscustomobject]@{
                    applicationName = $ApplicationName
                    botId           = $BotId
                    appVersion      = $AppVersion
                    status          = 'already-published'
                }
            }
            throw "Agent 365 publish failed for '$ApplicationName' (HTTP $status): $($resp.Content)"
        }

        $parsed = try { $resp.Content | ConvertFrom-Json } catch { $null }
        Write-LabLog -Message "Agent 365 publish submitted for '$ApplicationName' (botId $BotId, v$AppVersion). Tenant admin must approve at https://admin.cloud.microsoft/?#/agents/all/requested" -Level Success
        return [pscustomobject]@{
            applicationName = $ApplicationName
            botId           = $BotId
            appVersion      = $AppVersion
            status          = 'requested'
            response        = $parsed
        }
    }
    catch {
        Write-LabLog -Message "Agent 365 publish error for '$ApplicationName': $($_.Exception.Message)" -Level Warning
        return [pscustomobject]@{
            applicationName = $ApplicationName
            botId           = $BotId
            appVersion      = $AppVersion
            status          = 'failed'
            error           = $_.Exception.Message
        }
    }
}

function Publish-FoundryAgentsAsDigitalWorkers {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory)] [PSCustomObject]$Config,
        [Parameter(Mandatory)] [PSCustomObject]$FoundryManifest
    )

    $fw   = $Config.workloads.foundry
    $a365 = if ($fw.PSObject.Properties['agent365']) { $fw.agent365 } else { $null }

    if (-not $a365 -or -not $a365.PSObject.Properties['enabled'] -or -not [bool]$a365.enabled) {
        Write-LabLog -Message 'Agent 365 digital worker publishing disabled (workloads.foundry.agent365.enabled != true).' -Level Info
        return @()
    }

    $agents = @($FoundryManifest.agents)
    if ($agents.Count -eq 0) {
        Write-LabLog -Message 'No Foundry agents in manifest — skipping Agent 365 publish.' -Level Warning
        return @()
    }

    $subscriptionId = [string]$FoundryManifest.subscriptionId
    $resourceGroup  = [string]$FoundryManifest.resourceGroup
    $location       = [string]$FoundryManifest.location
    $accountName    = [string]$fw.accountName
    $projectName    = [string]$fw.projectName

    # Digital worker publish requires a botId. Reuse each agent's bot MSA app id
    # from the Foundry deployment manifest (bot services stage). Upstream sample
    # uses an Entra agent-identity blueprint id; the Foundry /publish endpoint
    # treats it opaquely as the Activity Protocol bot routing id.
    $botIdByName = @{}
    if ($FoundryManifest.PSObject.Properties['botServices'] -and
        $FoundryManifest.botServices -and
        $FoundryManifest.botServices.PSObject.Properties['bots']) {
        foreach ($b in @($FoundryManifest.botServices.bots)) {
            $agentName = [string]$b.botName -replace '-Bot$',''
            $botIdByName[$agentName] = [string]$b.appClientId
        }
    }

    $appVersion = if ($a365.PSObject.Properties['appVersion'])          { [string]$a365.appVersion }          else { '1.0.0' }
    $shortDesc  = if ($a365.PSObject.Properties['shortDescription'])    { [string]$a365.shortDescription }    else { 'Foundry agent digital worker' }
    $fullDesc   = if ($a365.PSObject.Properties['fullDescription'])     { [string]$a365.fullDescription }     else { 'Foundry agent published to Microsoft Agent 365 as a digital worker.' }
    $devName    = if ($a365.PSObject.Properties['developerName'])       { [string]$a365.developerName }       else { [string]$Config.labName }
    $devUrl     = if ($a365.PSObject.Properties['developerWebsiteUrl']) { [string]$a365.developerWebsiteUrl } else { 'https://github.com/chashea/ai-agent-security' }

    $results = [System.Collections.Generic.List[object]]::new()
    foreach ($agent in $agents) {
        $appName = [string]$agent.name
        $botId   = $botIdByName[$appName]
        if (-not $botId) {
            Write-LabLog -Message "No bot id found for '$appName' in manifest — skipping Agent 365 publish. (Bot Services must be deployed first.)" -Level Warning
            $results.Add([pscustomobject]@{ applicationName = $appName; status = 'skipped-no-botid' })
            continue
        }

        $result = Publish-FoundryAgentAsDigitalWorker `
            -Location            $location `
            -SubscriptionId      $subscriptionId `
            -ResourceGroup       $resourceGroup `
            -AccountName         $accountName `
            -ProjectName         $projectName `
            -ApplicationName     $appName `
            -BotId               $botId `
            -AppVersion          $appVersion `
            -ShortDescription    $shortDesc `
            -FullDescription     $fullDesc `
            -DeveloperName       $devName `
            -DeveloperWebsiteUrl $devUrl `
            -WhatIf:$WhatIfPreference
        $results.Add($result)
    }

    return $results.ToArray()
}

function Deploy-Agent365 {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)] [PSCustomObject]$Config,
        [Parameter(Mandatory)] [PSCustomObject]$FoundryManifest
    )

    $results = Publish-FoundryAgentsAsDigitalWorkers -Config $Config -FoundryManifest $FoundryManifest -WhatIf:$WhatIfPreference
    return [PSCustomObject]@{ agent365 = @($results) }
}

function Remove-Agent365 {
    [CmdletBinding(SupportsShouldProcess)]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Manifest',
        Justification = 'Module contract requires the parameter; no removal API exists.')]
    param(
        [Parameter(Mandatory)] [PSCustomObject]$Config,
        [PSCustomObject]$Manifest
    )

    if ($PSCmdlet.ShouldProcess($Config.prefix, 'Remove Agent 365 digital workers')) {
        Write-LabLog -Message 'Agent 365 digital worker removal is handled via the M365 admin center (no API available).' -Level Info
    }
}

Export-ModuleMember -Function @(
    'Publish-FoundryAgentAsDigitalWorker',
    'Publish-FoundryAgentsAsDigitalWorkers',
    'Deploy-Agent365',
    'Remove-Agent365'
)
