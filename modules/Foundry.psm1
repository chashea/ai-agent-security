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
        [Parameter()] [int]$JsonDepth = 10
    )

    $scriptPath = Join-Path $PSScriptRoot '..' 'scripts' $ScriptName
    $inputFile  = [System.IO.Path]::GetTempFileName()
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

    $projectEndpoint = [string]$bicepResult.projectEndpoint
    $prefix          = [string]$Config.prefix

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
            $connInput['connections']['aiSearch'] = @{
                endpoint  = $searchEndpoint
                indexName = [string]$fw.connections.aiSearch.indexName
            }
        }
        if ($fw.connections.PSObject.Properties['bingSearch']) {
            $connInput['connections']['bingSearch'] = @{}
        }
        if ($fw.connections.PSObject.Properties['blobStorage']) {
            $storageEndpoint = "https://pvfoundrybot$($subscriptionId.Replace('-','').Substring(24,8).ToLower()).blob.core.windows.net"
            $connInput['connections']['blobStorage'] = @{ endpoint = $storageEndpoint }
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
    $publishedApps = Publish-TeamsApps -Config $Config -Agents $manifest.agents -TenantId $tenantId
    if ($publishedApps -and @($publishedApps).Count -gt 0) {
        $manifest | Add-Member -NotePropertyName 'teamsApps' -NotePropertyValue $publishedApps -Force
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
}

Export-ModuleMember -Function @(
    'Deploy-Foundry'
    'Remove-Foundry'
)
