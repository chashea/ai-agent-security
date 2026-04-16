#Requires -Version 7.0

<#
.SYNOPSIS
    Foundry infrastructure module — ARM helpers, Bicep deployment, Bot Services,
    Teams packaging and catalog publishing.
.DESCRIPTION
    Extracted from the monolithic Foundry.psm1. Contains all infrastructure
    operations that cannot be handled by the Python SDK: ARM resource
    provisioning (via Bicep), Bot Services, Entra app registrations,
    Teams declarative agent packages, and Teams app catalog publishing.
#>

$script:ArmApiVersion   = '2026-01-15-preview'
$script:AppApiVersion    = '2025-10-01-preview'
$script:ArmBase          = 'https://management.azure.com'

# ─── Token Helpers ───────────────────────────────────────────────────────────

function Get-FoundryArmToken {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $tok = (Get-AzAccessToken -ResourceUrl 'https://management.azure.com' -ErrorAction Stop).Token
    if ($tok -is [System.Security.SecureString]) { return $tok | ConvertFrom-SecureString -AsPlainText }
    return $tok
}

function Get-FoundryDataToken {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $tok = (Get-AzAccessToken -ResourceUrl 'https://ai.azure.com' -ErrorAction Stop).Token
    if ($tok -is [System.Security.SecureString]) { return $tok | ConvertFrom-SecureString -AsPlainText }
    return $tok
}

function Get-FoundryGraphToken {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $tok = (Get-AzAccessToken -ResourceUrl 'https://graph.microsoft.com' -ErrorAction Stop).Token
    if ($tok -is [System.Security.SecureString]) { return $tok | ConvertFrom-SecureString -AsPlainText }
    return $tok
}

# ─── ARM Helpers ─────────────────────────────────────────────────────────────

function Invoke-ArmGet {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Uri,
        [Parameter(Mandatory)] [string]$Token
    )
    $headers = @{ 'Authorization' = "Bearer $Token" }
    $webResponse = Invoke-WebRequest -Uri $Uri -Method Get -Headers $headers `
        -SkipHttpErrorCheck -ErrorAction Stop
    $statusCode = [int]$webResponse.StatusCode
    if ($statusCode -eq 404) { return $null }
    if ($statusCode -ge 400) { throw "ARM GET failed (HTTP $statusCode): $($webResponse.Content)" }
    return ($webResponse.Content | ConvertFrom-Json)
}

function Invoke-ArmPut {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Uri,
        [Parameter(Mandatory)] [string]$Body,
        [Parameter(Mandatory)] [string]$Token,
        [Parameter()] [switch]$Async
    )
    $headers = @{ 'Authorization' = "Bearer $Token"; 'Content-Type' = 'application/json' }
    $webResponse = Invoke-WebRequest -Uri $Uri -Method Put -Headers $headers -Body $Body `
        -SkipHttpErrorCheck -ErrorAction Stop
    $statusCode = [int]$webResponse.StatusCode
    if ($statusCode -ge 400) { throw "ARM PUT failed (HTTP $statusCode): $($webResponse.Content)" }

    $parsed = if ($webResponse.Content) { try { $webResponse.Content | ConvertFrom-Json } catch { $null } } else { $null }

    if ($Async -and $statusCode -in @(201, 202)) {
        $asyncUrl = $null
        if ($webResponse.Headers['Azure-AsyncOperation']) {
            $asyncUrl = [string]($webResponse.Headers['Azure-AsyncOperation'] | Select-Object -First 1)
        }
        elseif ($webResponse.Headers['Location']) {
            $asyncUrl = [string]($webResponse.Headers['Location'] | Select-Object -First 1)
        }
        if ($asyncUrl) { Wait-ArmAsyncOperation -OperationUrl $asyncUrl -Token $Token }
    }
    return $parsed
}

function Invoke-ArmDelete {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Uri,
        [Parameter(Mandatory)] [string]$Token,
        [Parameter()] [switch]$Async
    )
    $headers = @{ 'Authorization' = "Bearer $Token" }
    $webResponse = Invoke-WebRequest -Uri $Uri -Method Delete -Headers $headers `
        -SkipHttpErrorCheck -ErrorAction Stop
    $statusCode = [int]$webResponse.StatusCode
    if ($statusCode -eq 404) { return }
    if ($statusCode -ge 400) { throw "ARM DELETE failed (HTTP $statusCode): $($webResponse.Content)" }

    if ($Async -and $statusCode -eq 202) {
        $asyncUrl = $null
        if ($webResponse.Headers['Azure-AsyncOperation']) {
            $asyncUrl = [string]($webResponse.Headers['Azure-AsyncOperation'] | Select-Object -First 1)
        }
        elseif ($webResponse.Headers['Location']) {
            $asyncUrl = [string]($webResponse.Headers['Location'] | Select-Object -First 1)
        }
        if ($asyncUrl) { Wait-ArmAsyncOperation -OperationUrl $asyncUrl -Token $Token }
    }
}

function Wait-ArmAsyncOperation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$OperationUrl,
        [Parameter(Mandatory)] [string]$Token
    )
    $headers     = @{ 'Authorization' = "Bearer $Token" }
    $maxAttempts = 40   # 40 x 15s = 10 min
    for ($i = 1; $i -le $maxAttempts; $i++) {
        Start-Sleep -Seconds 15
        $opResponse = Invoke-WebRequest -Uri $OperationUrl -Method Get -Headers $headers `
            -SkipHttpErrorCheck -ErrorAction Stop
        $opBody     = try { $opResponse.Content | ConvertFrom-Json } catch { $null }
        $httpStatus = [int]$opResponse.StatusCode

        if ($httpStatus -in @(200, 204) -and (-not $opBody -or
            (-not $opBody.PSObject.Properties['status'] -and -not $opBody.PSObject.Properties['provisioningState']))) {
            Write-LabLog -Message "ARM async polling... status: Succeeded (HTTP $httpStatus, attempt $i/$maxAttempts)" -Level Info
            return
        }
        $status = if ($opBody) {
            if ($opBody.PSObject.Properties['status']) { [string]$opBody.status }
            elseif ($opBody.PSObject.Properties['provisioningState']) { [string]$opBody.provisioningState }
            else { 'Unknown' }
        } else { 'Unknown' }
        Write-LabLog -Message "ARM async polling... status: $status (attempt $i/$maxAttempts)" -Level Info
        if ($status -eq 'Succeeded') { return }
        if ($status -in @('Failed', 'Canceled')) {
            $errorMsg = if ($opBody -and $opBody.PSObject.Properties['error']) { $opBody.error | ConvertTo-Json -Compress } else { $opResponse.Content }
            throw "ARM async operation $status`: $errorMsg"
        }
    }
    throw "ARM async operation did not complete within $($maxAttempts * 15) seconds."
}

# ─── Bicep Deployment ────────────────────────────────────────────────────────

function Deploy-FoundryBicep {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)] [PSCustomObject]$Config
    )
    <#
    .SYNOPSIS
        Creates the resource group, Foundry account, model deployments, and project via ARM REST, then deploys eval infra Bicep.
    #>

    $fw             = $Config.workloads.foundry
    $subscriptionId = [string]$fw.subscriptionId
    $resourceGroup  = [string]$fw.resourceGroup
    $location       = [string]$fw.location
    $accountName    = [string]$fw.accountName
    $projectName    = [string]$fw.projectName
    $modelDeploy    = [string]$fw.modelDeploymentName

    $projectEndpoint = "https://$accountName.services.ai.azure.com/api/projects/$projectName"

    if (-not $PSCmdlet.ShouldProcess("Foundry core '$resourceGroup'", 'Deploy')) {
        return [PSCustomObject]@{
            accountId          = $null
            projectId          = $null
            projectEndpoint    = $projectEndpoint
            accountName        = $accountName
            accountPrincipalId = $null
        }
    }

    # Re-assert Az context so fresh tokens point at the target subscription
    Set-AzContext -SubscriptionId $subscriptionId -ErrorAction Stop | Out-Null

    $armToken    = Get-FoundryArmToken
    $subPath     = "$($script:ArmBase)/subscriptions/$subscriptionId"
    $rgPath      = "$subPath/resourceGroups/$resourceGroup"
    $accountPath = "$rgPath/providers/Microsoft.CognitiveServices/accounts/$accountName"
    $modelPath   = "$accountPath/deployments/$modelDeploy"
    $projectPath = "$accountPath/projects/$projectName"

    # ── 1. Resource Group ────────────────────────────────────────────────────
    Write-LabLog -Message "Ensuring resource group: $resourceGroup" -Level Info
    $rgUri = "$rgPath`?api-version=2021-04-01"
    $existingRg = Invoke-ArmGet -Uri $rgUri -Token $armToken
    if (-not $existingRg) {
        $rgBody = @{ location = $location } | ConvertTo-Json -Compress
        Invoke-ArmPut -Uri $rgUri -Body $rgBody -Token $armToken | Out-Null
        Write-LabLog -Message "Created resource group: $resourceGroup" -Level Success
    }
    else {
        Write-LabLog -Message "Resource group already exists: $resourceGroup" -Level Info
    }

    # ── 2. Foundry Account (CognitiveServices AIServices) ───────────────────
    Write-LabLog -Message "Ensuring Foundry account: $accountName" -Level Info
    $accountUri      = "$accountPath`?api-version=$($script:ArmApiVersion)"
    $existingAccount = Invoke-ArmGet -Uri $accountUri -Token $armToken
    $accountId       = $null
    $accountPrincipalId = $null

    if ($existingAccount) {
        Write-LabLog -Message "Foundry account already exists: $accountName" -Level Info
        $accountId = [string]$existingAccount.id
        if ($existingAccount.PSObject.Properties['identity'] -and $existingAccount.identity.PSObject.Properties['principalId']) {
            $accountPrincipalId = [string]$existingAccount.identity.principalId
        }
    }
    else {
        $accountBody = @{
            kind       = 'AIServices'
            location   = $location
            sku        = @{ name = 'S0' }
            identity   = @{ type = 'SystemAssigned' }
            properties = @{
                allowProjectManagement = $true
                publicNetworkAccess    = 'Enabled'
                customSubDomainName    = $accountName
                disableLocalAuth       = $false
            }
        } | ConvertTo-Json -Depth 5 -Compress

        $createdAccount = Invoke-ArmPut -Uri $accountUri -Body $accountBody -Token $armToken -Async
        if ($createdAccount -and $createdAccount.PSObject.Properties['id']) {
            $accountId = [string]$createdAccount.id
        }
        # Re-fetch to pick up managed identity principalId populated after async completion
        $refreshed = Invoke-ArmGet -Uri $accountUri -Token $armToken
        if ($refreshed -and $refreshed.PSObject.Properties['identity'] -and $refreshed.identity.PSObject.Properties['principalId']) {
            $accountPrincipalId = [string]$refreshed.identity.principalId
        }
        Write-LabLog -Message "Created Foundry account: $accountName" -Level Success
    }

    # ── 3. Model Deployments ────────────────────────────────────────────────
    Write-LabLog -Message "Ensuring model deployment: $modelDeploy (gpt-4o)" -Level Info
    $modelUri      = "$modelPath`?api-version=$($script:ArmApiVersion)"
    $existingModel = Invoke-ArmGet -Uri $modelUri -Token $armToken
    if ($existingModel) {
        Write-LabLog -Message "Model deployment already exists: $modelDeploy" -Level Info
    }
    else {
        $modelBody = @{
            sku        = @{ name = 'GlobalStandard'; capacity = 10 }
            properties = @{
                model = @{
                    format  = 'OpenAI'
                    name    = 'gpt-4o'
                    version = '2024-11-20'
                }
            }
        } | ConvertTo-Json -Depth 5 -Compress
        Invoke-ArmPut -Uri $modelUri -Body $modelBody -Token $armToken -Async | Out-Null
        Write-LabLog -Message "Created model deployment: $modelDeploy" -Level Success
    }

    $embeddingsModel = if ($fw.PSObject.Properties['embeddingsModel']) { [string]$fw.embeddingsModel } else { 'text-embedding-3-small' }
    $embeddingsUri   = "$accountPath/deployments/$embeddingsModel`?api-version=$($script:ArmApiVersion)"
    $existingEmbed   = Invoke-ArmGet -Uri $embeddingsUri -Token $armToken
    if (-not $existingEmbed) {
        $embedBody = @{
            sku        = @{ name = 'GlobalStandard'; capacity = 10 }
            properties = @{
                model = @{
                    format  = 'OpenAI'
                    name    = $embeddingsModel
                    version = '1'
                }
            }
        } | ConvertTo-Json -Depth 5 -Compress
        Invoke-ArmPut -Uri $embeddingsUri -Body $embedBody -Token $armToken -Async | Out-Null
        Write-LabLog -Message "Created embeddings deployment: $embeddingsModel" -Level Success
    }

    # ── 3b. Guardrails (RAI Policy + Blocklist) ─────────────────────────────
    $guardrailsResult = $null
    $guardrailsCfg = if ($fw.PSObject.Properties['guardrails']) { $fw.guardrails } else { $null }
    if ($guardrailsCfg -and [bool]$guardrailsCfg.enabled) {
        $guardrailsBicep = Join-Path $PSScriptRoot '..' 'infra' 'guardrails.bicep'
        if (Test-Path $guardrailsBicep) {
            $policyName = if ($guardrailsCfg.PSObject.Properties['policyName']) { [string]$guardrailsCfg.policyName } else { "$prefix-strict" }
            $blocklistN = if ($guardrailsCfg.PSObject.Properties['blocklistName']) { [string]$guardrailsCfg.blocklistName } else { "$prefix-sensitive-data" }
            Write-LabLog -Message "Deploying guardrails: policy=$policyName, blocklist=$blocklistN" -Level Info
            $guardrailsOutput = az deployment group create `
                --resource-group $resourceGroup `
                --template-file $guardrailsBicep `
                --parameters accountName=$accountName policyName=$policyName modelDeploymentName=$modelDeploy blocklistName=$blocklistN `
                --subscription $subscriptionId `
                --output json 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-LabLog -Message "Guardrails deployed: policy=$policyName (severity=Low, mode=Blocking)" -Level Success

                $blocklistItems = @(
                    @{ name = 'ssn-pattern';         pattern = '\b\d{3}-\d{2}-\d{4}\b'; isRegex = $true }
                    @{ name = 'credit-card-pattern';  pattern = '\b(?:4\d{3}|5[1-5]\d{2}|3[47]\d{2}|6(?:011|5\d{2}))[-\s]?\d{4}[-\s]?\d{4}[-\s]?\d{3,4}\b'; isRegex = $true }
                    @{ name = 'bank-account-keyword'; pattern = 'my (bank|routing) (account|number) is'; isRegex = $true }
                )
                $armToken = Get-FoundryArmToken
                $blocklistBasePath = "$($script:ArmBase)/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.CognitiveServices/accounts/$accountName/raiBlocklists/$blocklistN/raiBlocklistItems"
                foreach ($item in $blocklistItems) {
                    $itemUri = "$blocklistBasePath/$($item.name)?api-version=2024-10-01"
                    $itemBody = @{ properties = @{ pattern = $item.pattern; isRegex = $item.isRegex } } | ConvertTo-Json -Depth 5 -Compress
                    try {
                        Invoke-ArmPut -Uri $itemUri -Body $itemBody -Token $armToken | Out-Null
                        Write-LabLog -Message "Blocklist item '$($item.name)' created." -Level Info
                    }
                    catch {
                        Write-LabLog -Message "Blocklist item '$($item.name)' failed: $_" -Level Warning
                    }
                }

                $guardrailsResult = @{
                    policyName    = $policyName
                    blocklistName = $blocklistN
                }
            }
            else {
                Write-LabLog -Message "Guardrails deployment failed (non-fatal): $guardrailsOutput" -Level Warning
            }
        }
        else {
            Write-LabLog -Message "Guardrails Bicep template not found at $guardrailsBicep — skipping." -Level Warning
        }
    }
    else {
        Write-LabLog -Message 'Guardrails disabled or not configured — using Microsoft Default policy.' -Level Info
    }

    # ── 4. Foundry Project ──────────────────────────────────────────────────
    Write-LabLog -Message "Ensuring Foundry project: $projectName" -Level Info
    $projectUri      = "$projectPath`?api-version=$($script:ArmApiVersion)"
    $existingProject = Invoke-ArmGet -Uri $projectUri -Token $armToken
    $projectId       = $null

    # Treat Failed project as non-existent — delete and recreate
    if ($existingProject -and
        $existingProject.PSObject.Properties['properties'] -and
        $existingProject.properties.PSObject.Properties['provisioningState'] -and
        [string]$existingProject.properties.provisioningState -eq 'Failed') {
        Write-LabLog -Message "Project '$projectName' is in Failed state — deleting and recreating." -Level Warning
        Invoke-ArmDelete -Uri $projectUri -Token $armToken | Out-Null
        $existingProject = $null
    }

    if ($existingProject -and [string]$existingProject.properties.provisioningState -eq 'Succeeded') {
        Write-LabLog -Message "Foundry project already exists: $projectName" -Level Info
        $projectId = [string]$existingProject.id
    }
    else {
        # NOTE: kind + identity are REQUIRED in the body for the project PUT to succeed
        # under MCAPS-governed tenants. Omitting them returns HTTP 500 InternalServerError.
        $projectBody = @{
            kind       = 'AIServices'
            location   = $location
            identity   = @{ type = 'SystemAssigned' }
            properties = @{
                description = 'AI Agent Security — deployed by ai-agent-security'
                displayName = $projectName
            }
        } | ConvertTo-Json -Depth 5 -Compress

        $createdProject = Invoke-ArmPut -Uri $projectUri -Body $projectBody -Token $armToken -Async
        $projectId = if ($createdProject -and $createdProject.PSObject.Properties['id']) {
            [string]$createdProject.id
        } else { $projectPath }
        Write-LabLog -Message "Created Foundry project: $projectName" -Level Success
    }

    # ── 5. Eval infrastructure (AI Search, App Insights, Log Analytics) ─────
    $aiSearchEndpoint = $null
    $evalBicep = Join-Path $PSScriptRoot '..' 'infra' 'foundry-eval-infra.bicep'
    if (Test-Path $evalBicep) {
        Write-LabLog -Message 'Deploying eval infrastructure (AI Search, App Insights)' -Level Info
        $evalOutput = az deployment group create `
            --resource-group $resourceGroup `
            --template-file $evalBicep `
            --parameters location=$location `
            --subscription $subscriptionId `
            --output json 2>&1

        if ($LASTEXITCODE -eq 0) {
            $evalJson = ($evalOutput | Where-Object { $_ -is [string] -and $_ -notmatch '^(WARNING|ERROR):' }) -join "`n"
            $evalResult = $evalJson | ConvertFrom-Json
            if ($evalResult.properties.outputs -and $evalResult.properties.outputs.PSObject.Properties['aiSearchEndpoint']) {
                $aiSearchEndpoint = [string]$evalResult.properties.outputs.aiSearchEndpoint.value
            }
            Write-LabLog -Message 'Eval infrastructure deployed' -Level Success
        }
        else {
            Write-LabLog -Message "Eval infra deployment failed (non-fatal): $evalOutput" -Level Warning
        }
    }

    $result = [PSCustomObject]@{
        accountId          = $accountId
        projectId          = $projectId
        projectEndpoint    = $projectEndpoint
        accountName        = $accountName
        accountPrincipalId = $accountPrincipalId
        aiSearchEndpoint   = $aiSearchEndpoint
        guardrails         = $guardrailsResult
    }

    Write-LabLog -Message "Foundry infrastructure complete: account=$accountName, project=$projectName" -Level Success
    return $result
}

function Remove-FoundryBicep {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [PSCustomObject]$Config,
        [Parameter()] [PSCustomObject]$Manifest,
        [Parameter(Mandatory)] [string]$ArmToken
    )
    <#
    .SYNOPSIS
        Removes the Foundry project, account, model deployment, and resource group.
    #>

    $fw             = $Config.workloads.foundry
    $subscriptionId = if ($Manifest -and $Manifest.PSObject.Properties['subscriptionId']) { [string]$Manifest.subscriptionId } else { [string]$fw.subscriptionId }
    $resourceGroup  = if ($Manifest -and $Manifest.PSObject.Properties['resourceGroup']) { [string]$Manifest.resourceGroup }  else { [string]$fw.resourceGroup }
    $accountName    = [string]$fw.accountName
    $projectName    = [string]$fw.projectName
    $modelDeploy    = [string]$fw.modelDeploymentName

    if (-not $PSCmdlet.ShouldProcess("Foundry infrastructure '$resourceGroup'", 'Remove')) { return }

    $rgPath      = "$($script:ArmBase)/subscriptions/$subscriptionId/resourceGroups/$resourceGroup"
    $accountPath = "$rgPath/providers/Microsoft.CognitiveServices/accounts/$accountName"

    # Delete project, model, account, then resource group
    foreach ($step in @(
        @{ Name = "project: $projectName";     Uri = "$accountPath/projects/$projectName`?api-version=$($script:ArmApiVersion)" }
        @{ Name = "model: $modelDeploy";        Uri = "$accountPath/deployments/$modelDeploy`?api-version=$($script:ArmApiVersion)" }
        @{ Name = "account: $accountName";       Uri = "$accountPath`?api-version=$($script:ArmApiVersion)" }
        @{ Name = "resource group: $resourceGroup"; Uri = "$rgPath`?api-version=2021-04-01" }
    )) {
        Write-LabLog -Message "Removing $($step.Name)" -Level Info
        try {
            Invoke-ArmDelete -Uri $step.Uri -Token $ArmToken -Async
            Write-LabLog -Message "Removed $($step.Name)" -Level Success
        }
        catch {
            Write-LabLog -Message "Error removing $($step.Name)`: $($_.Exception.Message)" -Level Warning
        }
    }
}

# ─── PNG Writer ──────────────────────────────────────────────────────────────

function Initialize-PngWriter {
    if (-not ([System.Management.Automation.PSTypeName]'Foundry.PngWriter').Type) {
        Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.IO;
using System.IO.Compression;

namespace Foundry {
    public static class PngWriter {
        static uint[] _crcTable;
        static PngWriter() {
            _crcTable = new uint[256];
            for (uint n = 0; n < 256; n++) {
                uint c = n;
                for (int k = 0; k < 8; k++) {
                    if ((c & 1) != 0) c = 0xEDB88320u ^ (c >> 1);
                    else c >>= 1;
                }
                _crcTable[n] = c;
            }
        }
        static uint Crc32(byte[] data, int offset, int length) {
            uint crc = 0xFFFFFFFFu;
            for (int i = offset; i < offset + length; i++)
                crc = _crcTable[(crc ^ data[i]) & 0xFF] ^ (crc >> 8);
            return crc ^ 0xFFFFFFFFu;
        }
        static uint Adler32(byte[] data) {
            uint s1 = 1, s2 = 0;
            foreach (byte b in data) { s1 = (s1 + b) % 65521; s2 = (s2 + s1) % 65521; }
            return (s2 << 16) | s1;
        }
        static byte[] BigEndian4(uint v) {
            return new byte[] { (byte)(v >> 24), (byte)(v >> 16), (byte)(v >> 8), (byte)v };
        }
        static void WriteChunk(Stream out_, byte[] type, byte[] data) {
            byte[] lenBytes = BigEndian4((uint)data.Length);
            out_.Write(lenBytes, 0, 4); out_.Write(type, 0, 4); out_.Write(data, 0, data.Length);
            byte[] crcInput = new byte[4 + data.Length];
            Array.Copy(type, 0, crcInput, 0, 4); Array.Copy(data, 0, crcInput, 4, data.Length);
            byte[] crcBytes = BigEndian4(Crc32(crcInput, 0, crcInput.Length));
            out_.Write(crcBytes, 0, 4);
        }
        static readonly byte[,] FontH = {{1,0,0,0,1},{1,0,0,0,1},{1,1,1,1,1},{1,0,0,0,1},{1,0,0,0,1},{1,0,0,0,1},{1,0,0,0,1}};
        static readonly byte[,] FontF = {{1,1,1,1,1},{1,0,0,0,0},{1,0,0,0,0},{1,1,1,1,0},{1,0,0,0,0},{1,0,0,0,0},{1,0,0,0,0}};
        static readonly byte[,] FontI = {{1,1,1,1,1},{0,0,1,0,0},{0,0,1,0,0},{0,0,1,0,0},{0,0,1,0,0},{0,0,1,0,0},{1,1,1,1,1}};
        static readonly byte[,] FontS = {{0,1,1,1,1},{1,0,0,0,0},{1,0,0,0,0},{0,1,1,1,0},{0,0,0,0,1},{0,0,0,0,1},{1,1,1,1,0}};
        static readonly byte[,] FontA = {{0,0,1,0,0},{0,1,0,1,0},{1,0,0,0,1},{1,1,1,1,1},{1,0,0,0,1},{1,0,0,0,1},{1,0,0,0,1}};
        static byte[,] GetGlyph(char c) {
            switch (char.ToUpper(c)) {
                case 'H': return FontH; case 'F': return FontF;
                case 'I': return FontI; case 'S': return FontS;
                case 'A': return FontA; default: return null;
            }
        }
        public static void Write(string path, int size, byte r, byte g, byte b) {
            WriteIcon(path, size, r, g, b, 0, 0, 0, '\0');
        }
        public static void WriteWithInitial(string path, int size,
            byte bgR, byte bgG, byte bgB, byte fgR, byte fgG, byte fgB, char initial) {
            WriteIcon(path, size, bgR, bgG, bgB, fgR, fgG, fgB, initial);
        }
        static void WriteIcon(string path, int size,
            byte bgR, byte bgG, byte bgB, byte fgR, byte fgG, byte fgB, char initial) {
            byte[,] glyph = (initial != '\0') ? GetGlyph(initial) : null;
            int glyphW = 5, glyphH = 7;
            int scale = (glyph != null) ? Math.Max(1, (int)(size * 0.55 / glyphW)) : 0;
            int letterW = glyphW * scale, letterH = glyphH * scale;
            int offX = (size - letterW) / 2, offY = (size - letterH) / 2;
            int scanline = 1 + size * 3;
            byte[] raw = new byte[size * scanline];
            for (int y = 0; y < size; y++) {
                int off = y * scanline; raw[off] = 0x00;
                for (int x = 0; x < size; x++) {
                    byte pr = bgR, pg = bgG, pb = bgB;
                    if (glyph != null && x >= offX && x < offX + letterW && y >= offY && y < offY + letterH) {
                        int gx = (x - offX) / scale; int gy = (y - offY) / scale;
                        if (gx < glyphW && gy < glyphH && glyph[gy, gx] == 1) { pr = fgR; pg = fgG; pb = fgB; }
                    }
                    raw[off + 1 + x * 3 + 0] = pr; raw[off + 1 + x * 3 + 1] = pg; raw[off + 1 + x * 3 + 2] = pb;
                }
            }
            byte[] compressed;
            using (var comp = new MemoryStream()) {
                comp.WriteByte(0x78); comp.WriteByte(0x9C);
                using (var dfl = new DeflateStream(comp, CompressionLevel.Optimal, true)) { dfl.Write(raw, 0, raw.Length); }
                uint adler = Adler32(raw);
                byte[] adlerBytes = BigEndian4(adler);
                comp.Write(adlerBytes, 0, 4);
                compressed = comp.ToArray();
            }
            byte[] ihdr = new byte[13];
            byte[] wb = BigEndian4((uint)size); Array.Copy(wb, 0, ihdr, 0, 4);
            byte[] hb = BigEndian4((uint)size); Array.Copy(hb, 0, ihdr, 4, 4);
            ihdr[8] = 8; ihdr[9] = 2; ihdr[10] = 0; ihdr[11] = 0; ihdr[12] = 0;
            byte[] pngSig = new byte[] { 137, 80, 78, 71, 13, 10, 26, 10 };
            byte[] typeIHDR = new byte[] { 73, 72, 68, 82 };
            byte[] typeIDAT = new byte[] { 73, 68, 65, 84 };
            byte[] typeIEND = new byte[] { 73, 69, 78, 68 };
            using (var fs = File.Open(path, FileMode.Create, FileAccess.Write)) {
                fs.Write(pngSig, 0, 8);
                WriteChunk(fs, typeIHDR, ihdr);
                WriteChunk(fs, typeIDAT, compressed);
                WriteChunk(fs, typeIEND, new byte[0]);
            }
        }
    }
}
'@
    }
}

# ─── Teams Agent Package ────────────────────────────────────────────────────

function New-FoundryAgentPackage {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [PSCustomObject]$Agent,
        [Parameter(Mandatory)] [string]$Prefix,
        [Parameter(Mandatory)] [PSCustomObject]$AgentConfig,
        [Parameter(Mandatory)] [string]$OutputDir,
        [Parameter(Mandatory)] [string]$TenantId
    )
    <#
    .SYNOPSIS
        Generates a Teams declarative-agent zip package for an agent with a deterministic manifest ID.
    #>

    $agentName   = [string]$Agent.name
    $shortName   = $agentName -replace "^$([regex]::Escape($Prefix))-", ''
    $shortNameNH = $shortName -replace '-', ''

    $description  = if ($AgentConfig.PSObject.Properties['description'] -and
                        -not [string]::IsNullOrWhiteSpace([string]$AgentConfig.description)) {
                        [string]$AgentConfig.description } else { $shortName }
    $instructions = [string]$AgentConfig.instructions
    $baseUrl      = if ($Agent.PSObject.Properties['baseUrl']) { [string]$Agent.baseUrl } else { '' }
    $descShort    = if ($description.Length -le 80) { $description } else { $description.Substring(0, 77) + '...' }

    $pkgDir  = Join-Path $OutputDir $shortName
    $zipPath = Join-Path $OutputDir "$shortName.zip"
    if (Test-Path $pkgDir)  { Remove-Item $pkgDir -Recurse -Force }
    if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
    New-Item -ItemType Directory -Path $pkgDir -Force | Out-Null

    # manifest.json — deterministic GUID from prefix + shortName so reruns
    # update the existing tenant app (matched by externalId) instead of
    # creating a duplicate every time.
    $idSeed     = "$Prefix/$shortName".ToLowerInvariant()
    $md5        = [System.Security.Cryptography.MD5]::Create()
    try {
        $hashBytes = $md5.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($idSeed))
    } finally { $md5.Dispose() }
    $stableId = [guid]::new($hashBytes).ToString()

    # Manifest version must be monotonically increasing for each update —
    # Graph returns 409 "Update tenant app definition manifest version exists"
    # otherwise. Encode as 1.<mmdd>.<hhmmss>.
    $now = [datetime]::UtcNow
    $pkgVersion = '1.{0:MMdd}.{0:HHmmss}' -f $now

    $teamsManifest = [ordered]@{
        '$schema'       = 'https://developer.microsoft.com/json-schemas/teams/v1.19/MicrosoftTeams.schema.json'
        manifestVersion = '1.19'; version = $pkgVersion; id = $stableId
        developer       = [ordered]@{ name = 'Contoso'; websiteUrl = 'https://contoso.com'; privacyUrl = 'https://contoso.com/privacy'; termsOfUseUrl = 'https://contoso.com/terms' }
        name            = [ordered]@{ short = $shortName; full = "$Prefix $shortName" }
        description     = [ordered]@{ short = $descShort; full = "$description — powered by Microsoft Foundry + Purview AI Governance" }
        icons           = [ordered]@{ color = 'color.png'; outline = 'outline.png' }
        accentColor     = '#0078D4'
        copilotAgents   = [ordered]@{ declarativeAgents = @([ordered]@{ id = $shortNameNH; file = 'declarativeAgent.json' }) }
    }
    $teamsManifest | ConvertTo-Json -Depth 10 | Set-Content -Path (Join-Path $pkgDir 'manifest.json') -Encoding UTF8

    # declarativeAgent.json
    $declAgent = [ordered]@{
        '$schema' = 'https://developer.microsoft.com/json-schemas/copilot/declarative-agent/v1.4/schema.json'
        version = 'v1.4'; name = $shortName; description = $description; instructions = $instructions
        actions = @([ordered]@{ id = "${shortNameNH}API"; file = 'plugin.json' })
    }
    $declAgent | ConvertTo-Json -Depth 10 | Set-Content -Path (Join-Path $pkgDir 'declarativeAgent.json') -Encoding UTF8

    # plugin.json
    $plugin = [ordered]@{
        '$schema' = 'https://developer.microsoft.com/json-schemas/copilot/plugin/v2.2/schema.json'
        schema_version = 'v2.2'; name_for_human = $shortName; description_for_human = $description
        namespace = $shortNameNH
        functions = @([ordered]@{ name = "ask$shortNameNH"; description = "Ask $shortName a question" })
        runtimes  = @([ordered]@{ type = 'OpenApi'; auth = [ordered]@{ type = 'None' }; spec = [ordered]@{ url = 'openapi.json' } })
    }
    $plugin | ConvertTo-Json -Depth 10 | Set-Content -Path (Join-Path $pkgDir 'plugin.json') -Encoding UTF8

    # openapi.json
    $authUrl  = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/authorize"
    $tokenUrl = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token"
    $openapi = [ordered]@{
        openapi = '3.0.1'
        info    = [ordered]@{ title = $shortName; version = '1.0.0' }
        servers = @(@{ url = $baseUrl })
        paths   = [ordered]@{
            '/responses' = [ordered]@{
                post = [ordered]@{
                    operationId = "ask$shortNameNH"; summary = "Ask $shortName a question"
                    requestBody = [ordered]@{ required = $true; content = [ordered]@{ 'application/json' = [ordered]@{ schema = [ordered]@{ type = 'object'; required = @('input'); properties = [ordered]@{ input = [ordered]@{ type = 'string'; description = 'User question or prompt' } } } } } }
                    responses   = [ordered]@{ '200' = [ordered]@{ description = 'Successful response'; content = [ordered]@{ 'application/json' = [ordered]@{ schema = [ordered]@{ type = 'object'; properties = [ordered]@{ output = [ordered]@{ type = 'array'; items = [ordered]@{ type = 'object' } }; status = [ordered]@{ type = 'string' } } } } } } }
                    security    = @(@{ EntraOAuth = @() })
                }
            }
        }
        components = [ordered]@{
            securitySchemes = [ordered]@{
                EntraOAuth = [ordered]@{
                    type = 'oauth2'
                    flows = [ordered]@{
                        authorizationCode = [ordered]@{ authorizationUrl = $authUrl; tokenUrl = $tokenUrl; scopes = [ordered]@{ 'https://cognitiveservices.azure.com/.default' = 'Access Azure AI services' } }
                    }
                }
            }
        }
    }
    $openapi | ConvertTo-Json -Depth 15 | Set-Content -Path (Join-Path $pkgDir 'openapi.json') -Encoding UTF8

    # PNG icons
    Initialize-PngWriter
    $iconColors = @{
        'HR' = @{ R = 16; G = 124; B = 16 }; 'Finance' = @{ R = 0; G = 120; B = 212 }
        'IT' = @{ R = 216; G = 59; B = 1 };   'Sales'   = @{ R = 92; G = 45; B = 145 }
    }
    $iconKey   = ($shortName -split '-')[0]
    $iconColor = if ($iconColors.ContainsKey($iconKey)) { $iconColors[$iconKey] } else { @{ R = 0; G = 120; B = 212 } }
    $initial   = [char]$shortName[0]

    [Foundry.PngWriter]::WriteWithInitial((Join-Path $pkgDir 'color.png'), 192,
        [byte]$iconColor.R, [byte]$iconColor.G, [byte]$iconColor.B, [byte]255, [byte]255, [byte]255, $initial)
    [Foundry.PngWriter]::WriteWithInitial((Join-Path $pkgDir 'outline.png'), 32,
        [byte]255, [byte]255, [byte]255, [byte]$iconColor.R, [byte]$iconColor.G, [byte]$iconColor.B, $initial)

    # Zip
    Compress-Archive -Path (Join-Path $pkgDir '*') -DestinationPath $zipPath -Force
    Remove-Item $pkgDir -Recurse -Force
    return $zipPath
}

# ─── Bot Function Zip ────────────────────────────────────────────────────────

function New-BotFunctionZip {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([byte[]])]
    param(
        [Parameter(Mandatory)] [hashtable[]]$BotInfoList
    )

    $routeFuncs = foreach ($b in $BotInfoList) {
        $envPrefix = switch ($b.routeName) {
            'hr-helpdesk'     { 'HR' }
            'finance-analyst' { 'FINANCE' }
            'it-support'      { 'IT' }
            'sales-research'  { 'SALES' }
            default           { ($b.routeName -replace '-', '_').ToUpper() }
        }
        $funcName = $b.routeName -replace '-', '_'
        @"


@app.route(route="$($b.routeName)/messages", methods=["POST"])
def ${funcName}(req: func.HttpRequest) -> func.HttpResponse:
    return _handle_bot(
        req,
        os.environ.get("${envPrefix}_AGENT_URL", ""),
        os.environ.get("${envPrefix}_PURVIEW_APP_ID", ""),
        os.environ.get("${envPrefix}_PURVIEW_APP_NAME", ""),
    )
"@
    }
    $routesBlock = $routeFuncs -join ''

    $pyCode = @"
import azure.functions as func
import json
import os
import logging
import asyncio
import aiohttp
from azure.identity.aio import ManagedIdentityCredential
from azure.identity import DefaultAzureCredential

from purview_sdk import (
    ProcessActivity,
    ProcessContentResult,
    PurviewClient,
    PurviewSdkError,
)

app = func.FunctionApp(http_auth_level=func.AuthLevel.ANONYMOUS)

PURVIEW_ENABLED = os.environ.get("PURVIEW_ENABLED", "false").lower() == "true"
PURVIEW_FAIL_MODE = os.environ.get("PURVIEW_FAIL_MODE", "open").lower()
PURVIEW_ENFORCE_PROMPT = os.environ.get("PURVIEW_ENFORCE_PROMPT", "true").lower() == "true"
PURVIEW_ENFORCE_RESPONSE = os.environ.get("PURVIEW_ENFORCE_RESPONSE", "true").lower() == "true"

BLOCKED_PROMPT_REPLY = (
    "This message was blocked by your organization's data security policy. "
    "Please rephrase your request without sensitive information."
)
BLOCKED_RESPONSE_REPLY = (
    "The agent's response was blocked by your organization's data security "
    "policy. Please contact your administrator if you believe this is in error."
)


def _get_user_id(body: dict) -> str:
    frm = body.get("from", {}) or {}
    return frm.get("aadObjectId") or frm.get("id") or ""


def _purview_client() -> PurviewClient:
    # Function App MSI app-context token. Per
    # docs/foundry-purview-integration.md §3 this path populates Audit + DSPM
    # Activity Explorer with classifications but does NOT trigger DLP/IRM/CC
    # enforcement — that requires a user-context token (v0.7 SSO follow-on).
    return PurviewClient(credential=DefaultAzureCredential())


def _process(
    client: PurviewClient,
    user_id: str,
    text: str,
    activity: ProcessActivity,
    app_id: str,
    app_name: str,
    correlation_id: str,
):
    try:
        return client.process_content(
            user_id=user_id,
            text=text,
            activity=activity,
            app_entra_id=app_id,
            app_name=app_name,
            correlation_id=correlation_id,
        )
    except PurviewSdkError as exc:
        logging.warning(
            "Purview processContent %s failed (%s): %s",
            activity.value, exc.status, exc.body[:200],
        )
    except Exception as exc:
        logging.warning(
            "Purview processContent %s unexpected error: %s",
            activity.value, exc,
        )
    if PURVIEW_FAIL_MODE == "closed":
        raise RuntimeError("Purview processContent failed and failMode=closed")
    return None


async def _call_foundry(agent_url: str, user_message: str) -> str:
    async with ManagedIdentityCredential() as cred:
        token = await cred.get_token("https://cognitiveservices.azure.com/.default")
    headers = {
        "Authorization": f"Bearer {token.token}",
        "Content-Type": "application/json",
    }
    async with aiohttp.ClientSession() as session:
        async with session.post(
            f"{agent_url}/responses",
            json={"input": user_message},
            headers=headers,
            ssl=True,
        ) as resp:
            data = await resp.json(content_type=None)
    for item in data.get("output", []):
        if item.get("type") == "message":
            for c in item.get("content", []):
                if c.get("type") == "output_text":
                    return c.get("text", "")
    return json.dumps(data)


def _reply(text: str, reply_to_id: str) -> func.HttpResponse:
    return func.HttpResponse(
        json.dumps({"type": "message", "text": text, "replyToId": reply_to_id}),
        mimetype="application/json",
        status_code=200,
    )


def _handle_bot(
    req: func.HttpRequest,
    agent_url: str,
    purview_app_id: str,
    purview_app_name: str,
) -> func.HttpResponse:
    try:
        body = req.get_json()
    except Exception as exc:
        logging.error("Bot error parsing request: %s", exc)
        return func.HttpResponse(status_code=500)

    if body.get("type") != "message" or not agent_url:
        return func.HttpResponse(status_code=200)

    activity_id = body.get("id", "")
    user_text = body.get("text", "") or ""
    user_id = _get_user_id(body)

    purview_active = (
        PURVIEW_ENABLED
        and bool(purview_app_id)
        and bool(user_id)
        and bool(user_text.strip())
    )
    client: PurviewClient = None  # type: ignore[assignment]
    correlation_id = ""
    if purview_active:
        client = _purview_client()
        correlation_id = f"{purview_app_name}:{activity_id}"

    try:
        if purview_active:
            prompt_result: ProcessContentResult = _process(
                client, user_id, user_text, ProcessActivity.UPLOAD_TEXT,
                purview_app_id, purview_app_name, correlation_id,
            )
            if (
                PURVIEW_ENFORCE_PROMPT
                and prompt_result is not None
                and prompt_result.blocked
            ):
                logging.info(
                    "Prompt blocked by Purview policy: actions=%s user=%s app=%s",
                    prompt_result.policy_actions, user_id, purview_app_name,
                )
                return _reply(BLOCKED_PROMPT_REPLY, activity_id)

        try:
            reply_text = asyncio.run(_call_foundry(agent_url, user_text))
        except Exception as exc:
            logging.error("Foundry call failed: %s", exc)
            return func.HttpResponse(status_code=500)

        if purview_active and reply_text:
            response_result: ProcessContentResult = _process(
                client, user_id, reply_text, ProcessActivity.DOWNLOAD_TEXT,
                purview_app_id, purview_app_name, correlation_id,
            )
            if (
                PURVIEW_ENFORCE_RESPONSE
                and response_result is not None
                and response_result.blocked
            ):
                logging.info(
                    "Response blocked by Purview policy: actions=%s user=%s app=%s",
                    response_result.policy_actions, user_id, purview_app_name,
                )
                return _reply(BLOCKED_RESPONSE_REPLY, activity_id)

        return _reply(reply_text, activity_id)

    except Exception as exc:
        logging.error("Bot error: %s", exc)
        return func.HttpResponse(status_code=500)
$routesBlock
"@

    $hostJson = '{"version":"2.0","extensionBundle":{"id":"Microsoft.Azure.Functions.ExtensionBundle","version":"[4.*, 5.0.0)"}}'
    $reqsTxt  = "azure-functions`r`nazure-identity`r`naiohttp`r`nrequests`r`n"

    if (-not $PSCmdlet.ShouldProcess('bot function zip', 'New')) { return [byte[]]@() }

    $purviewSdkPath = Join-Path $PSScriptRoot '..' 'scripts' 'purview_sdk.py'
    if (-not (Test-Path $purviewSdkPath)) {
        throw "Missing scripts/purview_sdk.py — expected at '$purviewSdkPath'. Bot zip requires the Purview Graph client library."
    }
    $purviewSdkCode = Get-Content -Path $purviewSdkPath -Raw

    $ms = [System.IO.MemoryStream]::new()
    $za = [System.IO.Compression.ZipArchive]::new($ms, [System.IO.Compression.ZipArchiveMode]::Create, $true)
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    foreach ($pair in @(
        @{ Name = 'host.json';        Content = $hostJson       }
        @{ Name = 'requirements.txt'; Content = $reqsTxt        }
        @{ Name = 'function_app.py';  Content = $pyCode         }
        @{ Name = 'purview_sdk.py';   Content = $purviewSdkCode }
    )) {
        $entry  = $za.CreateEntry($pair.Name)
        $stream = $entry.Open()
        $writer = [System.IO.StreamWriter]::new($stream, $utf8NoBom)
        $writer.Write($pair.Content)
        $writer.Flush(); $writer.Close(); $stream.Close()
    }
    $za.Dispose()
    $ms.Seek(0, [System.IO.SeekOrigin]::Begin) | Out-Null
    return $ms.ToArray()
}

# ─── Graph App Role Assignment (for Purview processContent bridge) ─────────

function Grant-BotFunctionGraphPermissions {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [string]$MsiPrincipalId,
        [Parameter(Mandatory)] [string]$GraphToken
    )

    # Required Microsoft Graph application permissions for the bot Function
    # App's managed identity to call /dataSecurityAndGovernance/processContent
    # and /protectionScopes/compute. These require tenant admin consent; on
    # MCAPS-governed tenants this call will usually 403 — callers should
    # handle that by granting the roles manually (see the warning message).
    $requiredRoles = @('ProtectedContent.Create.All', 'ProtectionScopes.Compute.All')
    $graphAppId    = '00000003-0000-0000-c000-000000000000'

    if (-not $PSCmdlet.ShouldProcess($MsiPrincipalId, 'Grant Microsoft Graph app permissions')) { return $true }

    $spUri = "https://graph.microsoft.com/v1.0/servicePrincipals(appId='$graphAppId')"
    $spResp = Invoke-WebRequest -Uri $spUri -Method Get `
        -Headers @{ Authorization = "Bearer $GraphToken" } `
        -SkipHttpErrorCheck -ErrorAction Stop
    if ([int]$spResp.StatusCode -ge 400) {
        Write-LabLog -Message "Unable to read Microsoft Graph service principal (HTTP $($spResp.StatusCode)). Skipping Purview permission grant." -Level Warning
        return $false
    }
    $graphSp = $spResp.Content | ConvertFrom-Json
    $graphSpId = [string]$graphSp.id

    $granted = $true
    foreach ($roleName in $requiredRoles) {
        $role = $graphSp.appRoles | Where-Object { $_.value -eq $roleName } | Select-Object -First 1
        if (-not $role) {
            Write-LabLog -Message "Graph SP does not expose role '$roleName' — may be a newer preview role. Skipping." -Level Warning
            $granted = $false
            continue
        }
        $assignBody = @{
            principalId = $MsiPrincipalId
            resourceId  = $graphSpId
            appRoleId   = [string]$role.id
        } | ConvertTo-Json -Compress
        $assignResp = Invoke-WebRequest `
            -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$MsiPrincipalId/appRoleAssignments" `
            -Method Post `
            -Headers @{ Authorization = "Bearer $GraphToken"; 'Content-Type' = 'application/json' } `
            -Body $assignBody -SkipHttpErrorCheck -ErrorAction Stop
        $status = [int]$assignResp.StatusCode
        if ($status -eq 201 -or $status -eq 200) {
            Write-LabLog -Message "Granted '$roleName' to bot Function App MSI." -Level Success
        } elseif ($status -eq 409 -or ($assignResp.Content -match 'already exists|Permission being assigned already exists')) {
            Write-LabLog -Message "'$roleName' already assigned to bot Function App MSI." -Level Info
        } else {
            Write-LabLog -Message "Failed to grant '$roleName' (HTTP $status): $($assignResp.Content)" -Level Warning
            Write-LabLog -Message "Manual grant: az rest --method POST --uri 'https://graph.microsoft.com/v1.0/servicePrincipals/$MsiPrincipalId/appRoleAssignments' --body '$assignBody'" -Level Warning
            $granted = $false
        }
    }
    return $granted
}

# ─── Deploy Bot Services ────────────────────────────────────────────────────

function Deploy-BotServices {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)] [PSCustomObject]$Config,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [PSCustomObject[]]$Agents,
        [Parameter(Mandatory)] [string]$ArmToken,
        [Parameter(Mandatory)] [string]$SubscriptionId,
        [Parameter(Mandatory)] [string]$ResourceGroup
    )
    <#
    .SYNOPSIS
        Deploys bot-services.bicep and bot-per-agent.bicep for each agent, including function app packaging and Graph permissions.
    #>

    $prefix      = [string]$Config.prefix
    $location    = [string]$Config.workloads.foundry.location
    $accountName = [string]$Config.workloads.foundry.accountName
    $tenantId    = [string](Get-AzContext).Tenant.Id
    $graphToken  = Get-FoundryGraphToken

    $subClean          = $SubscriptionId -replace '-', ''
    $subSuffix         = $subClean.Substring($subClean.Length - 8, 8).ToLower()
    $storageAccountName = "pvfoundrybot$subSuffix"
    $funcAppName        = "pvfoundry-bot-$subSuffix"

    $botManifest = [PSCustomObject]@{ storageAccountName = $storageAccountName; funcAppName = $funcAppName; bots = @() }

    if (-not $PSCmdlet.ShouldProcess("Bot Services for '$prefix'", 'Deploy')) { return $botManifest }

    $rgPath      = "$($script:ArmBase)/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup"
    $accountPath = "$rgPath/providers/Microsoft.CognitiveServices/accounts/$accountName"

    # Deploy Bicep for storage + function app + role assignments
    $botBicep = Join-Path $PSScriptRoot '..' 'infra' 'bot-services.bicep'
    Write-LabLog -Message "Deploying Bicep: bot-services.bicep" -Level Info

    az deployment group create `
        --resource-group $ResourceGroup `
        --template-file $botBicep `
        --parameters location=$location `
                     storageAccountName=$storageAccountName `
                     funcAppName=$funcAppName `
                     foundryAccountId=$accountPath `
        --subscription $SubscriptionId `
        --output none 2>&1 | Out-Null

    if ($LASTEXITCODE -ne 0) {
        Write-LabLog -Message "Bot services Bicep deployment failed — falling back to ARM REST." -Level Warning
    }

    # Get MSI principal from deployed function app
    $funcAppUri = "$rgPath/providers/Microsoft.Web/sites/$funcAppName`?api-version=2023-01-01"
    $funcAppObj = Invoke-ArmGet -Uri $funcAppUri -Token $ArmToken
    $msiPrincipalId = if ($funcAppObj) { [string]$funcAppObj.identity.principalId } else { $null }
    Write-LabLog -Message "Function App MSI: $msiPrincipalId" -Level Info

    # Entra app registrations (Graph — can't do in Bicep)
    $botInfoList = [System.Collections.Generic.List[hashtable]]::new()

    foreach ($agentCfg in $Config.workloads.foundry.agents) {
        $agentFullName = "$prefix-$($agentCfg.name)"
        $botName       = "$agentFullName-Bot"
        $routeName     = ([string]$agentCfg.name).ToLower()
        $msgEndpoint   = "https://$funcAppName.azurewebsites.net/api/$routeName/messages"

        $agentObj     = $Agents | Where-Object { $_.name -eq $agentFullName } | Select-Object -First 1
        $agentBaseUrl = if ($agentObj -and $agentObj.PSObject.Properties['baseUrl']) { [string]$agentObj.baseUrl } else { '' }

        Write-LabLog -Message "Registering Entra app: $botName" -Level Info

        $searchUri  = "https://graph.microsoft.com/v1.0/applications?`$filter=displayName eq '$botName'"
        $searchResp = Invoke-WebRequest -Uri $searchUri -Method Get -Headers @{ Authorization = "Bearer $graphToken" } -SkipHttpErrorCheck -ErrorAction Stop
        $existingApps = ($searchResp.Content | ConvertFrom-Json).value

        $appObjectId = $null; $appClientId = $null; $clientSecret = $null

        if ($existingApps -and @($existingApps).Count -gt 0) {
            $appObjectId = [string]$existingApps[0].id
            $appClientId = [string]$existingApps[0].appId
            Write-LabLog -Message "Entra app already exists: $botName ($appClientId)" -Level Info
        }
        else {
            $appBody = @{ displayName = $botName; signInAudience = 'AzureADMyOrg' } | ConvertTo-Json -Compress
            $appResp = Invoke-WebRequest -Uri 'https://graph.microsoft.com/v1.0/applications' -Method Post `
                -Headers @{ Authorization = "Bearer $graphToken"; 'Content-Type' = 'application/json' } `
                -Body $appBody -SkipHttpErrorCheck -ErrorAction Stop
            if ([int]$appResp.StatusCode -ge 400) {
                Write-LabLog -Message "Entra app creation failed for '$botName' (HTTP $($appResp.StatusCode)): $($appResp.Content)" -Level Warning
                continue
            }
            $createdApp  = $appResp.Content | ConvertFrom-Json
            $appObjectId = [string]$createdApp.id
            $appClientId = [string]$createdApp.appId
            Write-LabLog -Message "Created Entra app: $botName ($appClientId)" -Level Success
        }

        $secretBody = @{ passwordCredential = @{ displayName = 'BotServiceCredential' } } | ConvertTo-Json -Compress
        $secretResp = Invoke-WebRequest `
            -Uri "https://graph.microsoft.com/v1.0/applications/$appObjectId/addPassword" -Method Post `
            -Headers @{ Authorization = "Bearer $graphToken"; 'Content-Type' = 'application/json' } `
            -Body $secretBody -SkipHttpErrorCheck -ErrorAction Stop
        if ([int]$secretResp.StatusCode -lt 400) {
            $clientSecret = [string]($secretResp.Content | ConvertFrom-Json).secretText
        }
        else {
            Write-LabLog -Message "Client secret creation failed for '$botName': $($secretResp.Content)" -Level Warning
        }

        $botInfoList.Add(@{
            agentFullName = $agentFullName; botName = $botName; appObjectId = $appObjectId
            appClientId = $appClientId; clientSecret = $clientSecret; routeName = $routeName
            msgEndpoint = $msgEndpoint; agentBaseUrl = $agentBaseUrl
        })
    }

    # Build + deploy function zip
    Write-LabLog -Message "Building bot function package with Linux dependencies..." -Level Info
    $zipBytes   = New-BotFunctionZip -BotInfoList $botInfoList.ToArray()
    $srcZipPath = Join-Path ([System.IO.Path]::GetTempPath()) 'bot-src.zip'
    $fatZipPath = Join-Path ([System.IO.Path]::GetTempPath()) 'bot-functions-linux.zip'
    $buildDir   = Join-Path ([System.IO.Path]::GetTempPath()) "bot-build-$([System.Guid]::NewGuid().ToString('N').Substring(0,8))"
    [System.IO.File]::WriteAllBytes($srcZipPath, $zipBytes)

    try {
        New-Item -ItemType Directory -Path $buildDir -Force | Out-Null
        Expand-Archive -Path $srcZipPath -DestinationPath $buildDir -Force
        $pipArgs = @('install', '-r', (Join-Path $buildDir 'requirements.txt'),
            '--target', (Join-Path $buildDir '.python_packages' 'lib' 'site-packages'),
            '--platform', 'manylinux2014_x86_64', '--python-version', '3.11',
            '--only-binary=:all:', '--quiet')
        $pythonCmd = if (Get-Command 'python3.12' -ErrorAction SilentlyContinue) { 'python3.12' } else { 'python3' }
        & $pythonCmd -m pip @pipArgs 2>&1 | Out-Null
        if (Test-Path $fatZipPath) { Remove-Item $fatZipPath -Force }
        Compress-Archive -Path (Join-Path $buildDir '*') -DestinationPath $fatZipPath -Force
        Write-LabLog -Message "Fat zip built: $fatZipPath ($([math]::Round((Get-Item $fatZipPath).Length / 1MB, 1)) MB)" -Level Info
    }
    finally {
        Remove-Item $buildDir -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item $srcZipPath -Force -ErrorAction SilentlyContinue
    }

    # Upload to blob + set WEBSITE_RUN_FROM_PACKAGE
    $containerName = 'function-releases'; $blobName = 'bot-functions.zip'
    $currentUserId = [string](Get-AzContext).Account.Id
    try {
        az role assignment create --assignee $currentUserId --role 'Storage Blob Data Owner' `
            --scope "$rgPath/providers/Microsoft.Storage/storageAccounts/$storageAccountName" `
            --subscription $SubscriptionId --output none 2>&1 | Out-Null
    } catch { Write-LabLog -Message "Blob role assignment skipped (may already exist)." -Level Info }

    az storage container create --name $containerName --account-name $storageAccountName `
        --auth-mode login --subscription $SubscriptionId --output none 2>&1 | Out-Null
    az storage blob upload --account-name $storageAccountName --container-name $containerName `
        --name $blobName --file $fatZipPath --overwrite --auth-mode login `
        --subscription $SubscriptionId --output none 2>&1 | Out-Null

    $sasExpiry  = (Get-Date).AddDays(7).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $blobSasUrl = az storage blob generate-sas --account-name $storageAccountName `
        --container-name $containerName --name $blobName --permissions r --expiry $sasExpiry `
        --auth-mode login --as-user --full-uri --subscription $SubscriptionId --output tsv 2>&1
    Remove-Item $fatZipPath -Force -ErrorAction SilentlyContinue
    if (-not $blobSasUrl -or $blobSasUrl -notmatch '^https://') {
        Write-LabLog -Message "SAS generation failed. Set WEBSITE_RUN_FROM_PACKAGE manually." -Level Warning
        $blobSasUrl = $null
    }

    # Update function app settings
    $settingsDict = @{ FUNCTIONS_WORKER_RUNTIME = 'python'; FUNCTIONS_EXTENSION_VERSION = '~4'; 'AzureWebJobsStorage__accountName' = $storageAccountName }
    if ($blobSasUrl) { $settingsDict['WEBSITE_RUN_FROM_PACKAGE'] = $blobSasUrl }

    $purviewPc = $null
    if ($Config.workloads.foundry.PSObject.Properties['purviewProcessContent']) {
        $purviewPc = $Config.workloads.foundry.purviewProcessContent
    }
    $purviewEnabled = [bool]($purviewPc -and $purviewPc.enabled)
    $purviewFailMode = 'open'
    if ($purviewPc -and $purviewPc.failMode) { $purviewFailMode = [string]$purviewPc.failMode }
    $purviewEnforcePrompt = $true
    if ($purviewPc -and $purviewPc.PSObject.Properties['enforceOnPrompt']) {
        $purviewEnforcePrompt = [bool]$purviewPc.enforceOnPrompt
    }
    $purviewEnforceResponse = $true
    if ($purviewPc -and $purviewPc.PSObject.Properties['enforceOnResponse']) {
        $purviewEnforceResponse = [bool]$purviewPc.enforceOnResponse
    }
    $settingsDict['PURVIEW_ENABLED']          = $purviewEnabled.ToString().ToLower()
    $settingsDict['PURVIEW_FAIL_MODE']        = $purviewFailMode
    $settingsDict['PURVIEW_ENFORCE_PROMPT']   = $purviewEnforcePrompt.ToString().ToLower()
    $settingsDict['PURVIEW_ENFORCE_RESPONSE'] = $purviewEnforceResponse.ToString().ToLower()

    foreach ($botInfo in $botInfoList) {
        $ep = switch ($botInfo.routeName) {
            'hr-helpdesk' { 'HR' }; 'finance-analyst' { 'FINANCE' }
            'it-support' { 'IT' };  'sales-research' { 'SALES' }
            default { ($botInfo.routeName -replace '-', '_').ToUpper() }
        }
        $settingsDict["${ep}_APP_ID"]             = $botInfo.appClientId
        $settingsDict["${ep}_AGENT_URL"]          = $botInfo.agentBaseUrl
        $settingsDict["${ep}_PURVIEW_APP_ID"]     = $botInfo.appObjectId
        $settingsDict["${ep}_PURVIEW_APP_NAME"]   = $botInfo.botName
    }

    if ($purviewEnabled) {
        Write-LabLog -Message "Purview processContent bridge ENABLED (failMode=$($settingsDict['PURVIEW_FAIL_MODE'])). Each bot turn will call Graph /dataSecurityAndGovernance/processContent — app-context audit-only per docs/foundry-purview-integration.md §3." -Level Info
    } else {
        Write-LabLog -Message "Purview processContent bridge disabled (workloads.foundry.purviewProcessContent.enabled=false)." -Level Info
    }
    $settingsUri  = "$rgPath/providers/Microsoft.Web/sites/$funcAppName/config/appsettings?api-version=2023-01-01"
    $settingsBody = @{ properties = $settingsDict } | ConvertTo-Json -Depth 5 -Compress
    try { Invoke-ArmPut -Uri $settingsUri -Body $settingsBody -Token $ArmToken | Out-Null; Write-LabLog -Message 'Updated Function App settings.' -Level Success }
    catch { Write-LabLog -Message "Error updating app settings: $($_.Exception.Message)" -Level Warning }

    # Restart function app
    try {
        Invoke-WebRequest -Uri "$rgPath/providers/Microsoft.Web/sites/$funcAppName/restart?api-version=2023-01-01" `
            -Method Post -Headers @{ Authorization = "Bearer $ArmToken" } -SkipHttpErrorCheck -ErrorAction Stop | Out-Null
        Write-LabLog -Message "Function App restarted." -Level Success
    } catch { Write-LabLog -Message "Function App restart skipped: $($_.Exception.Message)" -Level Info }

    # Grant Graph permissions for Purview processContent bridge (best-effort;
    # requires tenant admin on the caller — on MCAPS this will usually need
    # to be granted manually by an administrator)
    if ($purviewEnabled -and $msiPrincipalId) {
        try {
            Grant-BotFunctionGraphPermissions -MsiPrincipalId $msiPrincipalId -GraphToken $graphToken | Out-Null
        } catch {
            Write-LabLog -Message "Graph permission grant threw: $($_.Exception.Message). Grant ProtectedContent.Create.All and ProtectionScopes.Compute.All to Function App MSI $msiPrincipalId manually." -Level Warning
        }
    }

    # Deploy Bot Services + Teams channels via Bicep
    $botPerAgentBicep = Join-Path $PSScriptRoot '..' 'infra' 'bot-per-agent.bicep'
    $createdBots = [System.Collections.Generic.List[PSCustomObject]]::new()

    foreach ($botInfo in $botInfoList) {
        $botName = $botInfo.botName
        Write-LabLog -Message "Creating Bot Service: $botName" -Level Info
        try {
            az deployment group create --resource-group $ResourceGroup `
                --template-file $botPerAgentBicep `
                --parameters botName=$botName `
                             msaAppId=$($botInfo.appClientId) `
                             tenantId=$tenantId `
                             endpoint=$($botInfo.msgEndpoint) `
                --subscription $SubscriptionId --output none 2>&1 | Out-Null

            if ($LASTEXITCODE -eq 0) {
                Write-LabLog -Message "Created Bot Service + Teams channel: $botName" -Level Success
                $createdBots.Add([PSCustomObject]@{
                    botName = $botName; appClientId = $botInfo.appClientId
                    appObjectId = $botInfo.appObjectId; msgEndpoint = $botInfo.msgEndpoint; teamsEnabled = $true
                })
            }
            else {
                Write-LabLog -Message "Bot Service Bicep failed for '$botName' — skipping." -Level Warning
            }
        }
        catch {
            Write-LabLog -Message "Error creating Bot Service '$botName': $($_.Exception.Message)" -Level Warning
        }
    }

    $botManifest.bots = $createdBots.ToArray()
    return $botManifest
}

# ─── Remove Bot Services ────────────────────────────────────────────────────

function Remove-BotServices {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [PSCustomObject]$Config,
        [Parameter()] [PSCustomObject]$BotManifest,
        [Parameter(Mandatory)] [string]$ArmToken,
        [Parameter(Mandatory)] [string]$SubscriptionId,
        [Parameter(Mandatory)] [string]$ResourceGroup
    )
    <#
    .SYNOPSIS
        Removes Bot Services resources including bot registrations, Teams channels, the function app, and the Entra app registration.
    #>

    $graphToken = Get-FoundryGraphToken
    $rgPath     = "$($script:ArmBase)/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup"

    $bots = if ($BotManifest -and $BotManifest.PSObject.Properties['bots'] -and $BotManifest.bots) { @($BotManifest.bots) } else { @() }
    $funcAppName = if ($BotManifest -and $BotManifest.PSObject.Properties['funcAppName'] -and
        -not [string]::IsNullOrWhiteSpace([string]$BotManifest.funcAppName)) { [string]$BotManifest.funcAppName }
    else {
        $subClean = $SubscriptionId -replace '-', ''; $subSuffix = $subClean.Substring($subClean.Length - 8, 8).ToLower()
        "pvfoundry-bot-$subSuffix"
    }

    if (-not $PSCmdlet.ShouldProcess("Bot Services for '$($Config.prefix)'", 'Remove')) { return }

    foreach ($bot in $bots) {
        $botName = [string]$bot.botName
        if ([string]::IsNullOrWhiteSpace($botName)) { continue }
        try {
            Invoke-ArmDelete -Uri "$rgPath/providers/Microsoft.BotService/botServices/$botName/channels/MsTeamsChannel`?api-version=2023-09-15-preview" -Token $ArmToken | Out-Null
            Write-LabLog -Message "Removed Teams channel: $botName" -Level Success
        } catch { Write-LabLog -Message "Teams channel removal skipped for '$botName': $($_.Exception.Message)" -Level Info }
        try {
            Invoke-ArmDelete -Uri "$rgPath/providers/Microsoft.BotService/botServices/$botName`?api-version=2023-09-15-preview" -Token $ArmToken | Out-Null
            Write-LabLog -Message "Removed Bot Service: $botName" -Level Success
        } catch { Write-LabLog -Message "Error removing Bot Service '$botName': $($_.Exception.Message)" -Level Warning }
    }

    foreach ($bot in $bots) {
        $appObjectId = [string]$bot.appObjectId
        if ([string]::IsNullOrWhiteSpace($appObjectId)) { continue }
        try {
            Invoke-WebRequest -Uri "https://graph.microsoft.com/v1.0/applications/$appObjectId" -Method Delete `
                -Headers @{ Authorization = "Bearer $graphToken" } -SkipHttpErrorCheck -ErrorAction Stop | Out-Null
            Write-LabLog -Message "Deleted Entra app: $appObjectId" -Level Success
        } catch { Write-LabLog -Message "Error deleting Entra app '$appObjectId': $($_.Exception.Message)" -Level Warning }
    }

    try {
        Invoke-ArmDelete -Uri "$rgPath/providers/Microsoft.Web/sites/$funcAppName`?api-version=2023-01-01" -Token $ArmToken | Out-Null
        Write-LabLog -Message "Removed Function App: $funcAppName" -Level Success
    } catch { Write-LabLog -Message "Error removing Function App '$funcAppName': $($_.Exception.Message)" -Level Warning }
}

# ─── Teams Catalog ───────────────────────────────────────────────────────────

function Publish-TeamsApps {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([PSCustomObject[]])]
    param(
        [Parameter(Mandatory)] [PSCustomObject]$Config,
        [Parameter(Mandatory)] [PSCustomObject[]]$Agents
    )
    <#
    .SYNOPSIS
        Publishes Teams declarative-agent packages to the organization app catalog using deterministic manifest IDs.
    #>

    if (-not $PSCmdlet.ShouldProcess("Teams app catalog for '$($Config.prefix)'", 'Publish')) {
        return @()
    }

    Write-LabLog -Message 'Publishing agent packages to Teams app catalog...' -Level Info
    $published = [System.Collections.Generic.List[PSCustomObject]]::new()

    # Require an existing Graph context with the right scope. Deploy.ps1 now
    # connects Graph with AppCatalog.ReadWrite.All in every mode (including
    # -FoundryOnly), so this should only fire when -SkipAuth is used.
    $mgContext = $null
    try { $mgContext = Get-MgContext -ErrorAction SilentlyContinue } catch { $mgContext = $null }
    $hasScope = $mgContext -and ($mgContext.Scopes -contains 'AppCatalog.ReadWrite.All')
    if (-not $hasScope) {
        Write-LabLog -Message 'Teams catalog publish skipped: Microsoft Graph not connected with AppCatalog.ReadWrite.All.' -Level Warning
        return @()
    }

    try {
        $catalogApps = $null
        try {
            $catalogResp = Invoke-MgGraphRequest -Method GET `
                -Uri "v1.0/appCatalogs/teamsApps?`$filter=distributionMethod eq 'organization'&`$expand=appDefinitions" -ErrorAction Stop
            $catalogApps = $catalogResp.value
        } catch { Write-LabLog -Message "Could not query Teams catalog: $($_.Exception.Message)" -Level Warning }

        foreach ($agent in $Agents) {
            $pkgPath = if ($agent.PSObject.Properties['packagePath']) { [string]$agent.packagePath } else { $null }
            if (-not $pkgPath -or -not (Test-Path $pkgPath)) {
                Write-LabLog -Message "No package found for $($agent.name) — skipping catalog publish." -Level Warning
                continue
            }
            $agentName = [string]$agent.name
            $shortName = $agentName -replace "^$([regex]::Escape($Config.prefix))-", ''

            # Read the package's manifest.json id (externalId). Matching on this
            # rather than displayName avoids collisions with unrelated tenant
            # apps that happen to share a name.
            $manifestId = $null
            try {
                Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
                $zip = [System.IO.Compression.ZipFile]::OpenRead($pkgPath)
                try {
                    $entry = $zip.Entries | Where-Object { $_.Name -eq 'manifest.json' } | Select-Object -First 1
                    if ($entry) {
                        $reader = New-Object System.IO.StreamReader($entry.Open())
                        $manifestJson = $reader.ReadToEnd() | ConvertFrom-Json
                        $reader.Dispose()
                        $manifestId = [string]$manifestJson.id
                    }
                } finally { $zip.Dispose() }
            } catch { Write-LabLog -Message "Could not read manifest.json from $pkgPath : $($_.Exception.Message)" -Level Warning }

            $existing = if ($catalogApps -and $manifestId) {
                $catalogApps | Where-Object { [string]$_.externalId -eq $manifestId } | Select-Object -First 1
            } else { $null }

            try {
                if ($existing) {
                    $appId = [string]$existing.id
                    Invoke-MgGraphRequest -Method POST -Uri "v1.0/appCatalogs/teamsApps/$appId/appDefinitions" `
                        -ContentType 'application/zip' -InputFilePath $pkgPath -ErrorAction Stop | Out-Null
                    Write-LabLog -Message "Updated Teams app: $shortName ($appId)" -Level Success
                    $published.Add([PSCustomObject]@{ name = $shortName; teamsAppId = $appId; action = 'updated' })
                }
                else {
                    $newApp = Invoke-MgGraphRequest -Method POST -Uri 'v1.0/appCatalogs/teamsApps?requiresReview=false' `
                        -ContentType 'application/zip' -InputFilePath $pkgPath -ErrorAction Stop
                    $newId = [string]$newApp.id
                    Write-LabLog -Message "Published Teams app: $shortName ($newId)" -Level Success
                    $published.Add([PSCustomObject]@{ name = $shortName; teamsAppId = $newId; action = 'created' })
                }
            } catch { Write-LabLog -Message "Teams catalog publish failed for '$shortName': $($_.Exception.Message)" -Level Warning }
        }
    }
    catch { Write-LabLog -Message "Teams catalog publish skipped: $($_.Exception.Message)" -Level Warning }

    return $published.ToArray()
}

function Remove-TeamsApps {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [PSCustomObject[]]$TeamsApps,
        [Parameter(Mandatory)] [string]$TenantId
    )
    <#
    .SYNOPSIS
        Removes Teams apps from the organization app catalog.
    #>

    if (-not $PSCmdlet.ShouldProcess("Teams app catalog", 'Remove apps')) { return }

    try {
        Connect-MgGraph -Scopes 'AppCatalog.ReadWrite.All' -TenantId $TenantId -NoWelcome -ErrorAction Stop
        foreach ($app in $TeamsApps) {
            $appId = [string]$app.teamsAppId
            if ([string]::IsNullOrWhiteSpace($appId)) { continue }
            try {
                Invoke-MgGraphRequest -Method DELETE -Uri "v1.0/appCatalogs/teamsApps/$appId" -ErrorAction Stop | Out-Null
                Write-LabLog -Message "Removed Teams app: $($app.name) ($appId)" -Level Success
            } catch { Write-LabLog -Message "Error removing Teams app '$($app.name)': $($_.Exception.Message)" -Level Warning }
        }
    }
    catch { Write-LabLog -Message "Teams catalog removal skipped: $($_.Exception.Message)" -Level Warning }
}

function Enable-FoundryPurviewDataSecurity {
    <#
    .SYNOPSIS
        Enables Microsoft Purview Data Security on the Foundry subscription.

    .DESCRIPTION
        Prerequisite for Microsoft Purview to see Foundry prompts/responses.
        Targets the Defender for Cloud "Enable Data Security for Azure AI with
        Microsoft Purview" toggle on the AI services plan. See
        docs/foundry-purview-integration.md §1.

        Safe to call repeatedly — the underlying REST call is idempotent.
        If the REST path is unavailable (preview API changes, tenant without
        Defender for Cloud, MCAPS governance), logs a Warning with manual
        portal steps and returns $false rather than throwing.

    .PARAMETER SubscriptionId
        Azure subscription ID that hosts the Foundry account.

    .OUTPUTS
        [bool] — $true if the toggle was confirmed on, $false if manual
        portal action is required.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$SubscriptionId
    )

    Write-LabLog -Message "Verifying Purview Data Security toggle on subscription $SubscriptionId (Defender for Cloud AI services plan)." -Level Info

    $apiVersion = '2024-01-01'
    $pricingPath = "/subscriptions/$SubscriptionId/providers/Microsoft.Security/pricings/AI"

    # Sanity check: ensure the Purview service principal is present in the tenant.
    # App ID from Microsoft Learn: azure/defender-for-cloud/ai-onboarding#troubleshooting
    $purviewSpAppId = '9ec59623-ce40-4dc8-a635-ed0275b5d58a'
    try {
        $spExists = Get-AzADServicePrincipal -ApplicationId $purviewSpAppId -ErrorAction SilentlyContinue
        if (-not $spExists) {
            Write-LabLog -Message "Microsoft Purview service principal ($purviewSpAppId) is NOT registered in this tenant. The Defender for Cloud data security toggle may fail. Create it via: New-AzADServicePrincipal -ApplicationId '$purviewSpAppId'" -Level Warning
        }
        else {
            Write-LabLog -Message 'Microsoft Purview service principal is registered in the tenant.' -Level Info
        }
    }
    catch {
        Write-LabLog -Message "Could not query for Microsoft Purview service principal: $($_.Exception.Message). Continuing." -Level Warning
    }

    try {
        $current = Invoke-ArmGet -Path $pricingPath -ApiVersion $apiVersion -ErrorAction Stop
    }
    catch {
        Write-LabLog -Message "Could not read Microsoft.Security/pricings/AI on subscription ${SubscriptionId}: $($_.Exception.Message). Enable Data Security for Azure AI manually via Defender for Cloud → Environment settings → AI services → Settings → Enable data security for AI interactions." -Level Warning
        return $false
    }

    # The extension name / field for the data security toggle is currently published as
    # a subExtension on the AI services plan. Exact field name has moved between previews;
    # we probe for common shapes and fall back to a warning if none match.
    $currentExtensions = @()
    if ($current -and $current.properties -and $current.properties.extensions) {
        $currentExtensions = @($current.properties.extensions)
    }

    $dataSecurityExt = $currentExtensions | Where-Object { $_.name -match 'DataSecurity|PurviewDataSecurity|AIInteractions' } | Select-Object -First 1
    if ($dataSecurityExt -and [bool]$dataSecurityExt.isEnabled) {
        Write-LabLog -Message "Purview Data Security for AI interactions is already enabled on subscription $SubscriptionId." -Level Success
        return $true
    }

    if (-not $PSCmdlet.ShouldProcess("subscription $SubscriptionId", 'Enable Purview Data Security for AI interactions')) {
        return $false
    }

    $desiredBody = @{
        properties = @{
            pricingTier = 'Standard'
            extensions  = @(
                @{
                    name      = 'PurviewDataSecurity'
                    isEnabled = 'True'
                }
            )
        }
    }

    try {
        Invoke-ArmPut -Path $pricingPath -ApiVersion $apiVersion -Body $desiredBody -ErrorAction Stop | Out-Null
        Write-LabLog -Message "Purview Data Security for AI interactions enabled on subscription $SubscriptionId." -Level Success
        return $true
    }
    catch {
        Write-LabLog -Message "Failed to enable Purview Data Security toggle via REST: $($_.Exception.Message). Enable manually via Defender for Cloud → Environment settings → select subscription $SubscriptionId → AI services → Settings → 'Enable data security for AI interactions' → On." -Level Warning
        return $false
    }
}

Export-ModuleMember -Function @(
    'Get-FoundryArmToken'
    'Get-FoundryDataToken'
    'Get-FoundryGraphToken'
    'Invoke-ArmGet'
    'Invoke-ArmPut'
    'Invoke-ArmDelete'
    'Wait-ArmAsyncOperation'
    'Deploy-FoundryBicep'
    'Remove-FoundryBicep'
    'Initialize-PngWriter'
    'New-FoundryAgentPackage'
    'New-BotFunctionZip'
    'Grant-BotFunctionGraphPermissions'
    'Deploy-BotServices'
    'Remove-BotServices'
    'Publish-TeamsApps'
    'Remove-TeamsApps'
    'Enable-FoundryPurviewDataSecurity'
)
