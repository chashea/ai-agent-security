#Requires -Version 7.0

<#
.SYNOPSIS
    Foundry workload orchestrator for ai-agent-security.
.DESCRIPTION
    Thin orchestrator that coordinates three layers:
    1. Bicep templates (infra/) for ARM infrastructure
    2. Python SDK scripts (scripts/) for agent CRUD, tools, knowledge, evaluations
    3. PowerShell (FoundryInfra.psm1) for Bot Services, Teams packaging, and catalog

    Deployment flow:
    Step 1: Bicep (ARM infra + eval infra + embeddings model)
    Step 2: Project connections (foundry_tools.py)
    Step 3: Knowledge base upload + vector stores (foundry_knowledge.py)
    Step 4: Build tool definitions (foundry_tools.py)
    Step 5: Create agents WITH tools (foundry_agents.py)
    Step 6: Teams packages + Bot Services + Teams catalog
    Step 7: Post-deploy evaluations (foundry_evals.py)
#>

$script:AgentApiVersion = '2025-05-15-preview'
$script:AppApiVersion   = '2025-10-01-preview'
$script:EvalApiVersion  = '2025-11-15-preview'

# Import infrastructure module
$infraPath = if ($PSScriptRoot) { Join-Path $PSScriptRoot 'FoundryInfra.psm1' }
             else { Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'FoundryInfra.psm1' }
if (Test-Path $infraPath) { Import-Module $infraPath -Force }

# ─── Python Invocation Helper ─────────────────────────────────────────────────

function Invoke-FoundryPython {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)] [string]$ScriptName,
        [Parameter(Mandatory)] [string]$Action,
        [Parameter(Mandatory)] [hashtable]$InputData,
        [Parameter()] [int]$JsonDepth = 20
    )

    $scriptPath = Join-Path $PSScriptRoot '..' 'scripts' $ScriptName
    $inputFile  = [System.IO.Path]::GetTempFileName()
    if (-not $IsWindows) {
        chmod 600 $inputFile 2>$null
    }
    $InputData  | ConvertTo-Json -Depth $JsonDepth | Set-Content -Path $inputFile -Encoding UTF8

    $pythonCmd = if (Get-Command 'python3.12' -ErrorAction SilentlyContinue) { 'python3.12' } else { 'python3' }

    try {
        Write-LabLog -Message "Invoking: $pythonCmd $ScriptName --action $Action" -Level Info
        $rawOutput = & $pythonCmd $scriptPath --action $Action --config $inputFile 2>&1

        $stdoutLines = @()
        foreach ($line in $rawOutput) {
            if ($line -is [System.Management.Automation.ErrorRecord]) {
                Write-LabLog -Message "  [Python] $($line.ToString())" -Level Info
            }
            else {
                $stdoutLines += [string]$line
            }
        }

        if ($LASTEXITCODE -ne 0) {
            throw "$ScriptName --action $Action failed (exit $LASTEXITCODE). Check logs above."
        }

        $jsonOutput = $stdoutLines -join "`n"
        return ($jsonOutput | ConvertFrom-Json)
    }
    finally {
        Remove-Item $inputFile -Force -ErrorAction SilentlyContinue
    }
}

# ─── Deploy-Foundry ───────────────────────────────────────────────────────────

function Deploy-Foundry {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Config
    )

    $fw              = $Config.workloads.foundry
    $subscriptionId  = [string]$fw.subscriptionId
    $resourceGroup   = [string]$fw.resourceGroup
    $accountName     = [string]$fw.accountName
    $projectName     = [string]$fw.projectName
    $modelDeployName = [string]$fw.modelDeploymentName

    # Validate required config fields
    if ([string]::IsNullOrWhiteSpace($subscriptionId) -or $subscriptionId -eq 'YOUR_SUBSCRIPTION_ID') {
        throw 'foundry.subscriptionId must be set to a real Azure subscription ID before deploying.'
    }
    foreach ($field in @('resourceGroup', 'location', 'accountName', 'projectName', 'modelDeploymentName')) {
        if ([string]::IsNullOrWhiteSpace([string]$fw.$field)) {
            throw "foundry.$field is required but not set in the config."
        }
    }

    $manifest = [PSCustomObject]@{
        subscriptionId            = $subscriptionId
        resourceGroup             = $resourceGroup
        location                  = [string]$fw.location
        accountId                 = $null
        accountPrincipalId        = $null
        projectId                 = $null
        projectEndpoint           = $null
        modelDeploymentName       = $modelDeployName
        aiSearchEndpoint          = $null
        purviewIntegrationEnabled = $false
        agents                    = @()
    }

    if (-not $PSCmdlet.ShouldProcess("Foundry lab '$($Config.prefix)'", 'Deploy Foundry account, project, agents, and evaluations')) {
        return $manifest
    }

    Set-AzContext -SubscriptionId $subscriptionId -ErrorAction Stop | Out-Null

    # ── Step 1: Deploy ARM infrastructure via Bicep ───────────────────────────
    Write-LabStep -StepName 'Foundry Bicep' -Description 'Deploying Foundry ARM infrastructure (account, model, project, AI Search, Bing, App Insights)'

    $bicepResult = Deploy-FoundryBicep -Config $Config
    $manifest.accountId          = $bicepResult.accountId
    $manifest.accountPrincipalId = $bicepResult.accountPrincipalId
    $manifest.projectId          = $bicepResult.projectId
    $manifest.projectEndpoint    = $bicepResult.projectEndpoint
    if ($bicepResult.PSObject.Properties['aiSearchEndpoint']) {
        $manifest.aiSearchEndpoint = $bicepResult.aiSearchEndpoint
    }
    if ([string]::IsNullOrWhiteSpace($manifest.aiSearchEndpoint) -and
        $fw.PSObject.Properties['connections'] -and $fw.connections -and
        $fw.connections.PSObject.Properties['aiSearch'] -and
        $fw.connections.aiSearch.PSObject.Properties['endpoint']) {
        $manifest.aiSearchEndpoint = [string]$fw.connections.aiSearch.endpoint
    }

    # Deploy Defender for Cloud posture (if enabled)
    $defenderPosture = if ($fw.PSObject.Properties['defenderPosture']) { [bool]$fw.defenderPosture } else { $false }
    if ($defenderPosture) {
        Write-LabLog -Message 'Deploying Defender for Cloud posture (MDC pricing tiers)' -Level Info
        $defenderBicep = Join-Path $PSScriptRoot '..' 'infra' 'defender-posture.bicep'
        if (Test-Path $defenderBicep) {
            az deployment sub create `
                --location $([string]$fw.location) `
                --template-file $defenderBicep `
                --subscription $subscriptionId `
                --output none 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) {
                Write-LabLog -Message 'Defender for Cloud posture enabled (Storage, AppServices, KeyVaults, ARM)' -Level Success
            }
            else {
                Write-LabLog -Message 'Defender for Cloud posture deployment failed — continuing without MDC.' -Level Warning
            }
        }
    }

    # Deploy built-in Azure AI governance policies (security baseline, NIST AI RMF,
    # EU AI Act). Assignments live at subscription scope so they surface in
    # Compliance blade of Defender for Cloud.
    $assignPolicies = if ($fw.PSObject.Properties['assignBuiltInPolicies']) {
        [bool]$fw.assignBuiltInPolicies
    } else { $true }
    if ($assignPolicies) {
        $policyBicep = Join-Path $PSScriptRoot '..' 'infra' 'foundry-builtin-policies.bicep'
        if (Test-Path $policyBicep) {
            Write-LabLog -Message 'Assigning built-in AI governance policies (security baseline, NIST AI RMF, EU AI Act)' -Level Info
            az deployment sub create `
                --location $([string]$fw.location) `
                --template-file $policyBicep `
                --subscription $subscriptionId `
                --output none 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) {
                Write-LabLog -Message 'Built-in AI policy assignments applied.' -Level Success
            }
            else {
                Write-LabLog -Message 'Built-in AI policy assignment failed — continuing (non-fatal).' -Level Warning
            }
        }
    }

    # Enable Purview Data Security on the Foundry subscription (prerequisite for
    # Purview policies to see Foundry interactions). See
    # docs/foundry-purview-integration.md §1.
    $purviewDataSecurityEnabled = $false
    if ($fw.PSObject.Properties['purviewDataSecurity'] -and $fw.purviewDataSecurity -and [bool]$fw.purviewDataSecurity.enable) {
        Write-LabStep -StepName 'PurviewDataSecurity' -Description 'Enabling Purview Data Security on the Foundry subscription'
        $purviewDataSecurityEnabled = Enable-FoundryPurviewDataSecurity -SubscriptionId $subscriptionId
    }
    else {
        Write-LabLog -Message 'foundry.purviewDataSecurity.enable is not set — skipping subscription-level Purview Data Security toggle. Purview policies will NOT see Foundry interactions until this is enabled manually.' -Level Warning
    }
    $manifest.purviewIntegrationEnabled = $purviewDataSecurityEnabled

    # Surface the user security context requirement early so reviewers see it in logs
    if ($fw.PSObject.Properties['userSecurityContext'] -and $fw.userSecurityContext -and [bool]$fw.userSecurityContext.enabled) {
        Write-LabLog -Message 'foundry.userSecurityContext.enabled=true: Azure OpenAI calls MUST include user_security_context (or an Entra user token) for Purview DLP/IRM/CC policies to fire. See docs/foundry-purview-integration.md §3.' -Level Info
    }

    $projectEndpoint = [string]$bicepResult.projectEndpoint
    $prefix          = [string]$Config.prefix

    # Wait for the data-plane endpoint to warm up. Freshly-created Foundry accounts
    # return SSL EOF / handshake failures on `services.ai.azure.com` for ~60-120s
    # after the control-plane PUT succeeds. Poll with az rest until we get any
    # non-SSL response, up to 4 minutes.
    Write-LabStep -StepName 'Foundry Warmup' -Description 'Waiting for Foundry data-plane endpoint to warm up'
    $warmupUri = "$projectEndpoint/agents?api-version=$($script:AgentApiVersion)"
    $warmupDeadline = (Get-Date).AddSeconds(240)
    $warmupReady = $false
    $warmupAttempt = 0
    while ((Get-Date) -lt $warmupDeadline -and -not $warmupReady) {
        $warmupAttempt++
        try {
            $null = az rest --method get --uri $warmupUri --resource 'https://ai.azure.com' 2>&1
            if ($LASTEXITCODE -eq 0) {
                $warmupReady = $true
                Write-LabLog -Message "Foundry data-plane endpoint is warm (attempt $warmupAttempt)." -Level Success
                break
            }
        }
        catch {
            $null = $_
        }
        Write-LabLog -Message "Foundry data-plane endpoint not ready (attempt $warmupAttempt) — waiting 15s..." -Level Info
        Start-Sleep -Seconds 15
    }
    if (-not $warmupReady) {
        Write-LabLog -Message 'Foundry data-plane endpoint did not warm up within 4 minutes. Proceeding anyway — Python script may still succeed or retry.' -Level Warning
    }

    # Common Python input base
    $pythonBase = [ordered]@{
        projectEndpoint = $projectEndpoint
        accountName     = $accountName
        projectName     = $projectName
        subscriptionId  = $subscriptionId
        resourceGroup   = $resourceGroup
        prefix          = $prefix
        agentApiVersion = $script:AgentApiVersion
        appApiVersion   = $script:AppApiVersion
        armApiVersion   = '2026-01-15-preview'
    }

    # ── Step 2: Set up project connections ────────────────────────────────────
    $connectionIds = @{}
    if ($fw.PSObject.Properties['connections'] -and $fw.connections) {
        Write-LabStep -StepName 'Connections' -Description 'Setting up project connections (AI Search, Bing, Blob Storage)'

        $connInput = [ordered]@{} + $pythonBase
        $connInput['connections'] = @{}

        # Build connection configs with endpoints from Bicep outputs
        if ($fw.connections.PSObject.Properties['aiSearch']) {
            $searchEndpoint = if ($bicepResult.PSObject.Properties['aiSearchEndpoint']) { [string]$bicepResult.aiSearchEndpoint } else { '' }
            if ([string]::IsNullOrWhiteSpace($searchEndpoint) -and $fw.connections.aiSearch.PSObject.Properties['endpoint']) {
                $searchEndpoint = [string]$fw.connections.aiSearch.endpoint
            }
            $connInput['connections']['aiSearch'] = @{
                endpoint  = $searchEndpoint
                indexName = [string]$fw.connections.aiSearch.indexName
            }
        }
        if ($fw.connections.PSObject.Properties['bingSearch']) {
            $bingCfg = $fw.connections.bingSearch
            $bingPayload = @{}

            # If user specified provision=true and no resourceId, create a
            # Microsoft.Bing/accounts resource in the Foundry RG using the
            # Foundry account's naming base.
            $shouldProvision = $false
            if ($bingCfg.PSObject.Properties['provision']) { $shouldProvision = [bool]$bingCfg.provision }
            $existingResourceId = $null
            if ($bingCfg.PSObject.Properties['resourceId']) { $existingResourceId = [string]$bingCfg.resourceId }

            if ($shouldProvision -and [string]::IsNullOrWhiteSpace($existingResourceId)) {
                $bingName = if ($bingCfg.PSObject.Properties['name'] -and -not [string]::IsNullOrWhiteSpace([string]$bingCfg.name)) {
                    [string]$bingCfg.name
                } else {
                    "${accountName}-bing"
                }
                $bingSku = if ($bingCfg.PSObject.Properties['sku'] -and -not [string]::IsNullOrWhiteSpace([string]$bingCfg.sku)) { [string]$bingCfg.sku } else { 'G1' }
                $bingResult = Deploy-BingGroundingAccount -SubscriptionId $subscriptionId -ResourceGroup $resourceGroup -AccountName $bingName -Sku $bingSku
                if ($bingResult -and $bingResult.resourceId) {
                    $existingResourceId = [string]$bingResult.resourceId
                }
            }

            if ($existingResourceId) { $bingPayload['resourceId'] = $existingResourceId }
            if ($bingCfg.PSObject.Properties['endpoint']) { $bingPayload['endpoint'] = [string]$bingCfg.endpoint }
            $connInput['connections']['bingSearch'] = $bingPayload
        }
        if ($fw.connections.PSObject.Properties['blobStorage']) {
            $storageEndpoint = "https://pvfoundrybot$($subscriptionId.Replace('-','').Substring(24,8).ToLower()).blob.core.windows.net"
            $connInput['connections']['blobStorage'] = @{
                endpoint = $storageEndpoint
                containerName = if ($fw.connections.blobStorage.PSObject.Properties['containerName']) { [string]$fw.connections.blobStorage.containerName } else { 'aisec-vectorstores' }
            }
        }
        if ($fw.connections.PSObject.Properties['sharePoint']) {
            $connInput['connections']['sharePoint'] = @{
                siteUrl = [string]$fw.connections.sharePoint.siteUrl
            }
        }
        if ($fw.connections.PSObject.Properties['appInsights']) {
            $aiCfg = $fw.connections.appInsights
            $aiPayload = @{}
            if ($aiCfg.PSObject.Properties['resourceId']) { $aiPayload['resourceId'] = [string]$aiCfg.resourceId }
            if ($aiCfg.PSObject.Properties['connectionString']) { $aiPayload['connectionString'] = [string]$aiCfg.connectionString }
            if ($aiPayload.Count -gt 0) {
                $connInput['connections']['appInsights'] = $aiPayload
            }
        }

        try {
            $connResult  = Invoke-FoundryPython -ScriptName 'foundry_tools.py' -Action 'setup-connections' -InputData $connInput
            $connectionIds = if ($connResult.PSObject.Properties['connections']) { $connResult.connections } else { @{} }
            Write-LabLog -Message "Created $(@($connectionIds.PSObject.Properties).Count) project connection(s)." -Level Success
        }
        catch { Write-LabLog -Message "Connection setup error: $($_.Exception.Message)" -Level Warning }
    }

    # ── Step 3: Upload knowledge base + create vector stores ─────────────────
    $vectorStores = @{}
    if ($fw.PSObject.Properties['knowledgeBase'] -and $fw.knowledgeBase) {
        Write-LabStep -StepName 'Knowledge Base' -Description 'Uploading demo docs and creating vector stores'

        $kbInput = [ordered]@{} + $pythonBase
        # Convert PSCustomObject to hashtable for knowledgeBase
        $kbMap = @{}
        foreach ($prop in $fw.knowledgeBase.PSObject.Properties) {
            $kbMap[$prop.Name] = @($prop.Value)
        }
        $kbInput['knowledgeBase'] = $kbMap

        try {
            $kbResult     = Invoke-FoundryPython -ScriptName 'foundry_knowledge.py' -Action 'upload' -InputData $kbInput
            $vectorStores = if ($kbResult.PSObject.Properties['vectorStores']) { $kbResult.vectorStores } else { @{} }
            $vsCount = @($vectorStores.PSObject.Properties).Count
            Write-LabLog -Message "Created $vsCount vector store(s)." -Level Success
        }
        catch { Write-LabLog -Message "Knowledge base upload error: $($_.Exception.Message)" -Level Warning }
    }

    # ── Step 4: Build tool definitions per agent ─────────────────────────────
    $toolDefinitions = @{}
    $hasTools = $fw.agents | Where-Object { $_.PSObject.Properties['tools'] -and $_.tools }
    if ($hasTools) {
        Write-LabStep -StepName 'Tool Definitions' -Description 'Building agent tool definitions'

        $toolInput = [ordered]@{
            agents = @($fw.agents | ForEach-Object {
                $agentObj = [ordered]@{ name = [string]$_.name; tools = @() }
                if ($_.PSObject.Properties['tools'] -and $_.tools) {
                    $agentObj['tools'] = @($_.tools)
                }
                $agentObj
            })
            connectionIds  = $connectionIds
            vectorStores   = $vectorStores
            agentsManifest = @()
            projectEndpoint = $projectEndpoint
        }

        try {
            $toolResult      = Invoke-FoundryPython -ScriptName 'foundry_tools.py' -Action 'build-tools' -InputData $toolInput
            $toolDefinitions = if ($toolResult.PSObject.Properties['toolDefinitions']) { $toolResult.toolDefinitions } else { @{} }
            $toolCount = @($toolDefinitions.PSObject.Properties).Count
            Write-LabLog -Message "Built tool definitions for $toolCount agent(s)." -Level Success
        }
        catch { Write-LabLog -Message "Tool definition build error: $($_.Exception.Message)" -Level Warning }
    }

    # ── Step 5: Create agents with tools via Python SDK ──────────────────────
    Write-LabStep -StepName 'Foundry Agents' -Description 'Creating agents with tools via Python SDK'

    $agentInput = [ordered]@{} + $pythonBase
    $agentInput['agents'] = @($fw.agents | ForEach-Object {
        [ordered]@{
            name         = [string]$_.name
            model        = [string]$_.model
            instructions = [string]$_.instructions
            description  = if ($_.PSObject.Properties['description']) { [string]$_.description } else { $null }
        }
    })
    $agentInput['toolDefinitions'] = $toolDefinitions
    $agentInput['userSecurityContextEnabled'] = [bool](
        $fw.PSObject.Properties['userSecurityContext'] -and
        $fw.userSecurityContext -and
        [bool]$fw.userSecurityContext.enabled
    )

    try {
        $agentManifest = Invoke-FoundryPython -ScriptName 'foundry_agents.py' -Action 'deploy' -InputData $agentInput

        $manifest.purviewIntegrationEnabled = [bool]$agentManifest.purviewIntegrationEnabled
        $manifest.agents = @($agentManifest.agents | ForEach-Object {
            $agentObj = [PSCustomObject]@{
                id      = [string]$_.id
                name    = [string]$_.name
                model   = [string]$_.model
                baseUrl = if ($_.PSObject.Properties['baseUrl']) { [string]$_.baseUrl } else { $null }
            }
            if ($_.PSObject.Properties['toolCount']) {
                $agentObj | Add-Member -NotePropertyName 'toolCount' -NotePropertyValue ([int]$_.toolCount) -Force
            }
            $agentObj
        })

        Write-LabLog -Message "Created $($manifest.agents.Count) agent(s)." -Level Success
    }
    catch {
        Write-LabLog -Message "Agent creation error: $($_.Exception.Message)" -Level Warning
    }

    # Store vector stores in manifest for cleanup
    if ($vectorStores -and @($vectorStores.PSObject.Properties).Count -gt 0) {
        $manifest | Add-Member -NotePropertyName 'vectorStores' -NotePropertyValue $vectorStores -Force
    }

    # ── Step 5b: Refresh tool definitions with a2a baseUrls ──────────────────
    # The first build-tools pass runs before agents exist, so `a2a` is always
    # skipped (it needs baseUrls). Now that agents have been deployed and
    # published we have baseUrls — rebuild the tool definitions with the
    # populated manifest and re-apply them via delete-and-recreate so a2a_preview
    # actually lands on the agents.
    #
    # TEMPORARILY DISABLED (2026-04-13): a2a_preview schema is unstable in the
    # current preview API and rejects every shape we've tried. Re-enable once
    # foundry_tools.py build_tool_definitions emits a valid a2a payload.
    $needsA2aRefresh = $false
    $haveBaseUrls = @($manifest.agents | Where-Object { $_.baseUrl }).Count -gt 0
    if ($needsA2aRefresh -and $haveBaseUrls) {
        Write-LabStep -StepName 'Tool Refresh' -Description 'Re-applying tool definitions with a2a baseUrls'

        $refreshInput = [ordered]@{
            agents = @($fw.agents | ForEach-Object {
                $agentObj = [ordered]@{ name = [string]$_.name; tools = @() }
                if ($_.PSObject.Properties['tools'] -and $_.tools) {
                    $agentObj['tools'] = @($_.tools)
                }
                $agentObj
            })
            connectionIds   = $connectionIds
            vectorStores    = $vectorStores
            agentsManifest  = @($manifest.agents | ForEach-Object {
                [ordered]@{
                    name        = [string]$_.name
                    baseUrl     = [string]$_.baseUrl
                    description = ''
                }
            })
            projectEndpoint = $projectEndpoint
        }

        try {
            $refreshResult     = Invoke-FoundryPython -ScriptName 'foundry_tools.py' -Action 'build-tools' -InputData $refreshInput
            $refreshedTools    = if ($refreshResult.PSObject.Properties['toolDefinitions']) { $refreshResult.toolDefinitions } else { @{} }

            $updateInput = [ordered]@{} + $pythonBase
            $updateInput['agents'] = @($fw.agents | ForEach-Object {
                [ordered]@{
                    name         = [string]$_.name
                    model        = [string]$_.model
                    instructions = [string]$_.instructions
                    description  = if ($_.PSObject.Properties['description']) { [string]$_.description } else { $null }
                }
            })
            $updateInput['toolDefinitions'] = $refreshedTools
            $updateInput['userSecurityContextEnabled'] = [bool](
                $fw.PSObject.Properties['userSecurityContext'] -and
                $fw.userSecurityContext -and
                [bool]$fw.userSecurityContext.enabled
            )

            $refreshManifest = Invoke-FoundryPython -ScriptName 'foundry_agents.py' -Action 'deploy' -InputData $updateInput
            # Update baseUrls from refreshed deploy (unchanged for existing apps)
            foreach ($ra in $refreshManifest.agents) {
                $match = $manifest.agents | Where-Object { $_.name -eq [string]$ra.name } | Select-Object -First 1
                if ($match -and $ra.PSObject.Properties['toolCount']) {
                    $match | Add-Member -NotePropertyName 'toolCount' -NotePropertyValue ([int]$ra.toolCount) -Force
                }
            }
            Write-LabLog -Message 'Tool refresh complete (a2a baseUrls applied).' -Level Success
        }
        catch { Write-LabLog -Message "Tool refresh error: $($_.Exception.Message)" -Level Warning }
    }

    # ── Step 6: Teams packages + Bot Services + Teams catalog ────────────────
    Write-LabStep -StepName 'Teams Packages' -Description 'Generating Teams declarative agent packages'

    $tenantId    = [string](Get-AzContext).Tenant.Id
    $packagesDir = Join-Path $PWD 'packages' 'foundry'
    if (-not (Test-Path $packagesDir)) { New-Item -ItemType Directory -Path $packagesDir -Force | Out-Null }

    foreach ($agent in $manifest.agents) {
        $agentName   = [string]$agent.name
        $agentConfig = $fw.agents | Where-Object { "$prefix-$($_.name)" -eq $agentName } | Select-Object -First 1
        if (-not $agentConfig) { continue }
        try {
            $zipPath = New-FoundryAgentPackage -Agent $agent -Prefix $prefix `
                -AgentConfig $agentConfig -OutputDir $packagesDir -TenantId $tenantId
            $agent | Add-Member -NotePropertyName 'packagePath' -NotePropertyValue $zipPath -Force
            Write-LabLog -Message "Package: $zipPath" -Level Success
        }
        catch { Write-LabLog -Message "Error generating package for '$agentName': $($_.Exception.Message)" -Level Warning }
    }

    # Bot Services (optional)
    $botServiceCfg = $fw.PSObject.Properties['botService'] ? $fw.botService : $null
    if ($botServiceCfg -and $botServiceCfg.PSObject.Properties['enabled'] -and [bool]$botServiceCfg.enabled) {
        Write-LabStep -StepName 'Bot Services' -Description 'Deploying Bot Services for Foundry agents'
        $armToken = Get-FoundryArmToken
        try {
            $botManifest = Deploy-BotServices -Config $Config -Agents $manifest.agents `
                -ArmToken $armToken -SubscriptionId $subscriptionId -ResourceGroup $resourceGroup
            $manifest | Add-Member -NotePropertyName 'botServices' -NotePropertyValue $botManifest -Force
        }
        catch { Write-LabLog -Message "Bot Services deployment error: $($_.Exception.Message)" -Level Warning }
    }

    # Teams catalog
    Write-LabStep -StepName 'Teams Catalog' -Description 'Publishing to Teams app catalog'
    $publishedApps = Publish-TeamsApps -Config $Config -Agents $manifest.agents
    if ($publishedApps -and @($publishedApps).Count -gt 0) {
        $manifest | Add-Member -NotePropertyName 'teamsApps' -NotePropertyValue $publishedApps -Force
    }

    # ── Step 6.5: Agent 365 digital worker publishing (opt-in) ───────────────
    $a365Cfg = if ($fw.PSObject.Properties['agent365']) { $fw.agent365 } else { $null }
    if ($a365Cfg -and $a365Cfg.PSObject.Properties['enabled'] -and [bool]$a365Cfg.enabled) {
        Write-LabStep -StepName 'Agent 365' -Description 'Publishing Foundry agents as Agent 365 digital workers'
        try {
            $a365Results = Publish-FoundryAgentsAsDigitalWorkers -Config $Config -FoundryManifest $manifest
            if ($a365Results -and @($a365Results).Count -gt 0) {
                $manifest | Add-Member -NotePropertyName 'agent365' -NotePropertyValue $a365Results -Force
            }
        }
        catch { Write-LabLog -Message "Agent 365 publish error: $($_.Exception.Message)" -Level Warning }
    }

    # ── Step 7: Post-deploy evaluations ──────────────────────────────────────
    if ($fw.PSObject.Properties['evaluations'] -and $fw.evaluations) {
        Write-LabStep -StepName 'Evaluations' -Description 'Running post-deploy evaluations (prompt optimization, batch eval, continuous eval)'

        $evalInput = [ordered]@{} + $pythonBase
        $evalInput['evalApiVersion'] = $script:EvalApiVersion
        $evalInput['modelDeploymentName'] = $modelDeployName
        $evalInput['agents'] = @($manifest.agents | ForEach-Object {
            [ordered]@{
                id   = [string]$_.id
                name = [string]$_.name
            }
        })

        # Add agent instructions for prompt optimization
        foreach ($evalAgent in $evalInput['agents']) {
            $cfgAgent = $fw.agents | Where-Object { "$prefix-$($_.name)" -eq $evalAgent.name } | Select-Object -First 1
            if ($cfgAgent) {
                $evalAgent['instructions'] = [string]$cfgAgent.instructions
            }
        }

        # Convert evaluations config to hashtable
        $evalCfg = @{}
        foreach ($prop in $fw.evaluations.PSObject.Properties) {
            $evalCfg[$prop.Name] = $prop.Value
        }
        $evalInput['evaluations'] = $evalCfg

        try {
            $evalResult = Invoke-FoundryPython -ScriptName 'foundry_evals.py' -Action 'evaluate' -InputData $evalInput
            $manifest | Add-Member -NotePropertyName 'evaluations' -NotePropertyValue $evalResult -Force
            Write-LabLog -Message 'Post-deploy evaluations complete.' -Level Success
        }
        catch { Write-LabLog -Message "Evaluation error: $($_.Exception.Message)" -Level Warning }
    }

    # ── Step 8: AI Red Teaming ───────────────────────────────────────────────
    if ($fw.PSObject.Properties['redTeaming'] -and $fw.redTeaming -and $fw.redTeaming.enabled -eq $true) {
        $rtModeSet = $fw.redTeaming.PSObject.Properties['mode'] -and -not [string]::IsNullOrWhiteSpace([string]$fw.redTeaming.mode)
        $rtMode = if ($rtModeSet) { [string]$fw.redTeaming.mode } else { 'local' }
        if (-not $rtModeSet) {
            Write-LabLog -Message "redTeaming.mode not set in config — defaulting to 'local'. Set workloads.foundry.redTeaming.mode to 'cloud' for managed Foundry red-team runs." -Level Warning
        }
        if ($rtMode -notin @('cloud', 'local')) {
            Write-LabLog -Message "redTeaming.mode '$rtMode' is not recognized — must be 'cloud' or 'local'. Skipping red-team step." -Level Warning
        }
        else {
            $rtAction = if ($rtMode -eq 'cloud') { 'cloud-scan' } else { 'scan' }
            Write-LabStep -StepName 'AI Red Teaming' -Description "Running AI Red Teaming Agent ($rtMode mode) against deployed agents"

        $rtInput = [ordered]@{} + $pythonBase
        $rtInput['agentApiVersion'] = $script:AgentApiVersion
        $rtInput['modelDeploymentName'] = $modelDeployName
        $rtInput['location'] = $fw.location
        $rtInput['agents'] = @($manifest.agents | ForEach-Object {
            [ordered]@{
                id      = [string]$_.id
                name    = [string]$_.name
                version = [string]($_.PSObject.Properties['version'] ? $_.version : '1')
            }
        })

        # Convert redTeaming config to hashtable
        $rtCfg = @{}
        foreach ($prop in $fw.redTeaming.PSObject.Properties) {
            $rtCfg[$prop.Name] = $prop.Value
        }
        $rtInput['redTeaming'] = $rtCfg

        try {
            $rtResult = Invoke-FoundryPython -ScriptName 'foundry_redteam.py' -Action $rtAction -InputData $rtInput
            $manifest | Add-Member -NotePropertyName 'redTeaming' -NotePropertyValue $rtResult -Force
            Write-LabLog -Message 'AI Red Teaming complete.' -Level Success
        }
        catch { Write-LabLog -Message "Red Teaming error: $($_.Exception.Message)" -Level Warning }
        }
    }

    return $manifest
}

# ─── Remove-Foundry ───────────────────────────────────────────────────────────

function Remove-Foundry {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Config,

        [Parameter()]
        [PSCustomObject]$Manifest
    )

    $fw = $Config.workloads.foundry

    $subscriptionId = if ($Manifest -and $Manifest.PSObject.Properties['subscriptionId']) {
        [string]$Manifest.subscriptionId
    } else { [string]$fw.subscriptionId }

    $resourceGroup = if ($Manifest -and $Manifest.PSObject.Properties['resourceGroup']) {
        [string]$Manifest.resourceGroup
    } else { [string]$fw.resourceGroup }

    $accountName     = [string]$fw.accountName
    $projectName     = [string]$fw.projectName

    $projectEndpoint = if ($Manifest -and $Manifest.PSObject.Properties['projectEndpoint'] -and
        -not [string]::IsNullOrWhiteSpace([string]$Manifest.projectEndpoint)) {
        [string]$Manifest.projectEndpoint
    } else { "https://$accountName.services.ai.azure.com/api/projects/$projectName" }

    if ([string]::IsNullOrWhiteSpace($subscriptionId) -or $subscriptionId -eq 'YOUR_SUBSCRIPTION_ID') {
        Write-LabLog -Message 'foundry.subscriptionId not configured — skipping Foundry teardown.' -Level Warning
        return
    }

    if (-not $PSCmdlet.ShouldProcess("Foundry lab '$($Config.prefix)'", 'Remove Foundry agents, project, and account')) {
        return
    }

    Set-AzContext -SubscriptionId $subscriptionId -ErrorAction Stop | Out-Null
    $armToken = Get-FoundryArmToken

    # ── 1. Remove Teams catalog apps ─────────────────────────────────────────
    if ($Manifest -and $Manifest.PSObject.Properties['teamsApps'] -and $Manifest.teamsApps) {
        $tenantId = [string](Get-AzContext).Tenant.Id
        Remove-TeamsApps -TeamsApps @($Manifest.teamsApps) -TenantId $tenantId
    }

    # ── 2. Remove Bot Services ───────────────────────────────────────────────
    $botServiceCfg = $fw.PSObject.Properties['botService'] ? $fw.botService : $null
    if ($botServiceCfg -and $botServiceCfg.PSObject.Properties['enabled'] -and [bool]$botServiceCfg.enabled) {
        $botManifestData = if ($Manifest -and $Manifest.PSObject.Properties['botServices']) { $Manifest.botServices } else { $null }
        try {
            Remove-BotServices -Config $Config -BotManifest $botManifestData `
                -ArmToken $armToken -SubscriptionId $subscriptionId -ResourceGroup $resourceGroup
        }
        catch { Write-LabLog -Message "Bot Services removal error: $($_.Exception.Message)" -Level Warning }
    }

    # ── 3. Clean up vector stores ────────────────────────────────────────────
    if ($Manifest -and $Manifest.PSObject.Properties['vectorStores'] -and $Manifest.vectorStores) {
        try {
            $vsCleanup = @{
                projectEndpoint = $projectEndpoint
                agentApiVersion = $script:AgentApiVersion
                vectorStores    = @{}
            }
            foreach ($prop in $Manifest.vectorStores.PSObject.Properties) {
                $vsCleanup.vectorStores[$prop.Name] = [string]$prop.Value
            }
            Invoke-FoundryPython -ScriptName 'foundry_knowledge.py' -Action 'cleanup' -InputData $vsCleanup | Out-Null
            Write-LabLog -Message 'Vector stores cleaned up.' -Level Success
        }
        catch { Write-LabLog -Message "Vector store cleanup error: $($_.Exception.Message)" -Level Warning }
    }

    # ── 4. Remove agents via Python SDK ──────────────────────────────────────
    $agentsToRemove = @()
    if ($Manifest -and $Manifest.PSObject.Properties['agents'] -and $Manifest.agents) {
        $agentsToRemove = @($Manifest.agents)
    }
    else {
        Write-LabLog -Message 'No agent manifest available — delete agents manually in the Foundry portal.' -Level Warning
    }

    if ($agentsToRemove.Count -gt 0) {
        try {
            $removeInput = [ordered]@{
                projectEndpoint = $projectEndpoint
                accountName     = $accountName
                projectName     = $projectName
                subscriptionId  = $subscriptionId
                resourceGroup   = $resourceGroup
                agents          = @($agentsToRemove | ForEach-Object {
                    [ordered]@{ id = [string]$_.id; name = [string]$_.name }
                })
                agentApiVersion = $script:AgentApiVersion
                appApiVersion   = $script:AppApiVersion
            }
            Invoke-FoundryPython -ScriptName 'foundry_agents.py' -Action 'remove' -InputData $removeInput | Out-Null
            Write-LabLog -Message 'Agent removal complete.' -Level Success
        }
        catch { Write-LabLog -Message "Agent removal error: $($_.Exception.Message)" -Level Warning }
    }

    # ── 5. Remove ARM infrastructure via Bicep teardown ──────────────────────
    Remove-FoundryBicep -Config $Config -Manifest $Manifest -ArmToken $armToken

    # ── 6. Remove Grounding with Bing Search account (if we provisioned it) ──
    $bingCfg = $null
    if ($fw.PSObject.Properties['connections'] -and $fw.connections -and $fw.connections.PSObject.Properties['bingSearch']) {
        $bingCfg = $fw.connections.bingSearch
    }
    if ($bingCfg -and $bingCfg.PSObject.Properties['provision'] -and [bool]$bingCfg.provision) {
        $bingName = if ($bingCfg.PSObject.Properties['name'] -and -not [string]::IsNullOrWhiteSpace([string]$bingCfg.name)) {
            [string]$bingCfg.name
        } else { "${accountName}-bing" }
        try {
            Remove-BingGroundingAccount -SubscriptionId $subscriptionId -ResourceGroup $resourceGroup -AccountName $bingName
        }
        catch { Write-LabLog -Message "Bing Grounding removal error: $($_.Exception.Message)" -Level Warning }
    }
}

Export-ModuleMember -Function @(
    'Deploy-Foundry'
    'Remove-Foundry'
)
