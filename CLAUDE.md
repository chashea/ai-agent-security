# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Standalone AI agent security tool. Deploys Azure AI Foundry agents and wraps them with Microsoft Purview security controls (sensitivity labels, DLP, retention, eDiscovery, communication compliance, insider risk).

Single config file (`config.json`), modular by workload, deploy + teardown symmetry. Supports `-SkipFoundry` (Purview-only) and `-FoundryOnly` (Foundry-only) modes.

## Stack

- PowerShell 7+ (pwsh)
- Python 3.12 (Foundry agent SDK — `azure-ai-projects>=2.0.0`, `azure-identity`, `requests`)
- Bicep (ARM infrastructure templates in `infra/`)
- ExchangeOnlineManagement >= 3.0
- Microsoft.Graph SDK (Users, Groups, Authentication)
- Az.Accounts (for Foundry/Azure deployment)

## Tenant

| Environment | Tenant ID | Domain |
|---|---|---|
| **Commercial** | `f1b92d41-6d54-4102-9dd9-4208451314df` | `MngEnvMCAP648165.onmicrosoft.com` |

## Commands

```powershell
# Full deploy
./Deploy.ps1 -ConfigPath config.json

# Security-only (skip Foundry)
./Deploy.ps1 -ConfigPath config.json -SkipFoundry

# Foundry-only
./Deploy.ps1 -ConfigPath config.json -FoundryOnly

# Dry run (no cloud connection)
./Deploy.ps1 -ConfigPath config.json -SkipAuth -WhatIf

# Teardown (config-based, prefix lookup)
./Remove.ps1 -ConfigPath config.json

# Teardown (manifest-based, precise resource IDs)
./Remove.ps1 -ConfigPath config.json -ManifestPath manifests/AISec_20260411-120000.json

# Lint (CI uses this — zero warnings required)
Invoke-ScriptAnalyzer -Path . -Recurse -Severity Warning -ExcludeRule PSAvoidUsingWriteHost,PSUseSingularNouns,PSUseBOMForUnicodeEncodedFile

# Run all Pester tests
Invoke-Pester tests/ -Output Detailed

# Run a single test file
Invoke-Pester tests/Prerequisites.Tests.ps1 -Output Detailed

# Smoke test (import all modules + validate config)
pwsh -NoProfile -Command '
  Import-Module ./modules/Prerequisites.psm1 -Force
  Import-Module ./modules/Logging.psm1 -Force
  Get-ChildItem ./modules/*.psm1 | ForEach-Object { Import-Module $_.FullName -Force }
  $config = Import-LabConfig -ConfigPath ./config.json
  Test-LabConfigValidity -Config $config
'

# Python lint
ruff check scripts/

# Python tests
python3.12 -m pytest scripts/tests/ -v

# Validate Bicep templates
az bicep build --file infra/foundry-eval-infra.bicep
az bicep build --file infra/bot-services.bicep
az bicep build --file infra/bot-per-agent.bicep
az bicep build --file infra/defender-posture.bicep
```

## Architecture

### Three-Layer Foundry Architecture

```
PowerShell (modules/)           Python SDK (scripts/)          Bicep (infra/)
─────────────────────           ─────────────────────          ──────────────────
FoundryInfra.psm1               foundry_tools.py               foundry-eval-infra.bicep
 ARM REST: RG, account,          Project connections,           AI Search, App Insights,
 model, project                  tool definition builder        Log Analytics
 Teams packages,                foundry_knowledge.py           bot-services.bicep
 Bot Services,                   Demo doc upload,               Storage, Function App,
 Teams catalog                   vector store creation          role assignments
                                foundry_agents.py              bot-per-agent.bicep
                                 Agent CRUD with tools,         Bot Service, Teams channel
                                 app publishing                defender-posture.bicep
                                foundry_evals.py                MDC pricing tiers
                                 Prompt optimization,
                                 batch / continuous eval,
                                 custom evaluators
```

**Deployment flow:**
1. `Deploy-FoundryBicep` (in `FoundryInfra.psm1`) creates RG, account, gpt-4o model,
   embeddings model, and the project via direct ARM REST
   (`api-version=2026-01-15-preview`). Then deploys `foundry-eval-infra.bicep`
   to the RG for AI Search / App Insights / Log Analytics.
2. `foundry_tools.py setup-connections` creates project connections via ARM
   control plane (`accounts/projects/connections`). Data-plane `/connections`
   returns HTTP 405.
3. `foundry_knowledge.py upload` uploads demo docs, creates vector stores,
   returns vector store IDs.
4. `foundry_tools.py build-tools` builds per-agent tool definition dicts,
   injecting vector store IDs + connection IDs.
5. `foundry_agents.py deploy` creates agents via `azure-ai-projects` SDK and
   publishes each as a Foundry application, returning a `baseUrl`.
6. PowerShell: Teams declarative-agent packages + Bot Services + Teams catalog
   publish (stable manifest id + monotonic version for idempotent reruns).
7. `foundry_evals.py evaluate` probes the evaluations endpoint; runs prompt
   optimization, custom evaluators, batch eval (quality+safety), and
   continuous eval if available.

`Foundry.psm1` is a thin orchestrator that coordinates all three layers. The
external contract (`Deploy-Foundry` / `Remove-Foundry`) is unchanged.

**Note:** Foundry core resources (RG/account/model/project) are created via
pure PowerShell ARM REST rather than Bicep. The project RP has transient
behavior that benefits from per-step retry + existence checks, and Bicep's
`Microsoft.CognitiveServices/accounts/projects` type returned HTTP 500s
consistently on MCAPS-governed tenants during testing. See the Known
Constraints section.

### Orchestration Flow

`Deploy.ps1` imports all `modules/*.psm1`, loads `config.json` via `Import-LabConfig`, connects to EXO + Graph (+ Az for Foundry), then deploys workloads in dependency order. Each workload is invoked through an `Invoke-Workload` helper that isolates errors — a failed workload logs the error and adds to `$failedWorkloads` but does not abort remaining workloads. Manifest data (created resource IDs) is collected and exported to `manifests/<prefix>_<timestamp>.json`.

`Remove.ps1` mirrors deploy with reversed workload order. Accepts optional `-ManifestPath` for precise teardown using resource GUIDs; without it, falls back to config + prefix-based lookup. `Get-WorkloadManifest` extracts per-workload data, returning null for graceful degradation.

### Deployment Order (dependency-driven)

1. Foundry — agents + Defender for Cloud posture
2. AgentIdentity — managed identity RBAC (auto-derived from tools)
3. TestUsers — groups needed for policy scoping
4. SensitivityLabels
5. DLP
6. Retention
7. EDiscovery
8. CommunicationCompliance
9. InsiderRisk
10. ConditionalAccess — MFA + risky sign-in block (report-only)
11. MDCA — session monitoring + activity alerts + app governance
12. AuditConfig

Removal is the exact reverse.

### Module Contract

Every workload module in `modules/` exports:
- `Deploy-<Workload> -Config <PSCustomObject> [-WhatIf]` — returns hashtable of created resource IDs (manifest data)
- `Remove-<Workload> -Config <PSCustomObject> [-Manifest <PSCustomObject>] [-WhatIf]` — uses manifest for precise removal, falls back to config + prefix

Exceptions: `Prerequisites.psm1`, `Logging.psm1`, `Interactive.psm1`, and `FoundryInfra.psm1` are utility/infrastructure modules (no Deploy/Remove exports).

### Key Utility Functions (Prerequisites.psm1)

- `Import-LabConfig` — JSON loader with required field validation (labName, prefix, domain)
- `Test-LabConfigValidity` — validates enabled workloads have required subfields (e.g., dlp.policies, retention.policies)
- `Invoke-LabRetry -ScriptBlock -MaxAttempts 3 -DelaySeconds 5` — generic retry for transient Graph/EXO failures
- `Get-LabSupportedParameterName` — inspects cmdlet parameters to handle version differences (e.g., `ExchangeSenderMemberOf` vs `ExchangeSenderMemberOfGroups`)
- `Connect-LabServices` / `Disconnect-LabServices` — multi-service auth (EXO, Graph, optional Azure)
- `Resolve-LabTenantDomain` — verifies config domain against tenant; auto-corrects if mismatched
- `Export-LabManifest` / `Import-LabManifest` — JSON serialization with `generatedAt` timestamp

### Key Patterns

- **DLP preflight** (Deploy.ps1): Before DLP deployment, validates which cmdlet parameters are available. Degrades gracefully — falls back to baseline if label/override/alert params are unsupported.
- **Parameter fallback**: Multiple modules use `Get-LabSupportedParameterName` to detect cmdlet capability at runtime, since parameter names vary across module versions (DLP locations, insider risk groups, etc.).
- **Post-deploy validation** (Deploy.ps1): Retries 6 times with 5-second delays to handle Microsoft Graph eventual consistency lag.
- **Long-running operations**: EDiscovery polls async operation status (120s timeout, 5s interval). Foundry uses `Wait-ArmAsyncOperation` in FoundryInfra.psm1.
- **PowerShell-to-Python interface**: `Invoke-FoundryPython` helper writes JSON config to a temp file, invokes `python3.12 scripts/<script>.py --action <verb> --config <path>`, captures JSON manifest from stdout. Four Python scripts: `foundry_agents.py` (agent CRUD), `foundry_tools.py` (connections + tool definitions), `foundry_knowledge.py` (vector stores + doc upload), `foundry_evals.py` (evaluations pipeline). API versions are passed from PowerShell (single source of truth).
- **Agent tools**: Each agent gets tools defined in `config.json` under `agents[].tools[]`. Tool definitions are built by `foundry_tools.py`, injecting runtime values (vector store IDs, connection IDs) from earlier deployment steps. Currently supports: code_interpreter, file_search, azure_ai_search, bing_grounding, openapi, azure_function, function, mcp, sharepoint_grounding, a2a, image_generation.
- **Post-deploy evaluations**: Run automatically as Step 7 in Deploy-Foundry. Includes prompt optimization, custom evaluator creation (compliance_adherence), batch eval with synthetic data (quality + safety + agent evaluators), and continuous evaluation enablement (10% sampling).
- **Logging**: All output goes through `Write-LabLog` (Level: Info/Warning/Error/Success) and `Write-LabStep` for visual sections. Transcripts auto-cleanup after 30 days.

### Known Constraints & Tenant Requirements

**MCAPS tenant policy exemption (required for Foundry).** The MCAPS
governance policy set includes `CognitiveServices_LocalAuth_Modify` which
forces `disableLocalAuth: true` on all Cognitive Services accounts. Foundry
project creation requires `disableLocalAuth: false` for the capability host
handshake. Create a policy exemption on the target resource group before
deploying:

```bash
az policy exemption create \
  --name "foundry-localauth-exempt" \
  --policy-assignment "/providers/microsoft.management/managementgroups/<tenantId>/providers/microsoft.authorization/policyassignments/mcapsgovdeploypolicies" \
  --exemption-category Waiver \
  --scope "/subscriptions/<subId>/resourceGroups/<rgName>"
```

**Foundry project creation API.** Requires `api-version=2026-01-15-preview`
(earlier versions 500 on MCAPS tenants) and the PUT body must include
`kind: "AIServices"`, `identity: { type: "SystemAssigned" }`, and
`properties.displayName`. See `Deploy-FoundryBicep` in
`modules/FoundryInfra.psm1`.

**Region.** Tested in `eastus`. Earlier attempts in `eastus2` and `centralus`
hit either capacity (`InsufficientResourcesAvailable`) or project-RP
errors.

**Project connections are ARM resources.** Use the ARM control-plane path
`Microsoft.CognitiveServices/accounts/projects/connections` for
CRUD — the data-plane `<projectEndpoint>/connections` returns HTTP 405
on PUT. `scripts/foundry_tools.py setup_connections()` uses ARM.

**Bing Search connection is skipped.** The Bing Search API has been retired
(aka.ms/BingAPIsRetirement). Foundry's built-in `bing_grounding` tool uses
the project's managed web search with no project connection required —
emit the tool without a `project_connection_id` field.

**Blob Storage connection metadata.** `AzureBlob` connections require
`properties.metadata.ContainerName` and `properties.metadata.AccountName`
on PUT. The endpoint alone is rejected with HTTP 400.

**SharePoint grounding tool.** Requires a `SharePoint` project connection
pointing at a real site URL (`https://<tenant>.sharepoint.com/sites/<site>`).
If `workloads.foundry.connections.sharePoint.siteUrl` is empty, the tool is
skipped entirely on each agent (otherwise Foundry shows the agent as
"missing configuration").

**Agent tool schema quirks.**
- `function` tools use a flat schema (`{type, name, description, parameters}`),
  NOT the OpenAI Chat Completions nested `{type, function: {...}}`.
- `sharepoint_grounding_preview`, `a2a_preview`, etc. — the nested property
  key must match the `type` field exactly.

**Teams catalog publishing is idempotent.** `New-FoundryAgentPackage` emits
a deterministic `manifest.json` id (`MD5(prefix/shortName)` rendered as a
GUID) and a monotonic `version` (`1.<mmdd>.<hhmmss>` UTC). `Publish-TeamsApps`
matches existing tenant apps by `externalId`, so reruns update the existing
app rather than creating duplicates. The publish step requires a pre-existing
`MgContext` with `AppCatalog.ReadWrite.All` — in `-FoundryOnly` mode, the
deploy does not connect Graph itself, so connect manually first or run a
full deploy.

**Evaluations pipeline may be unavailable.** `foundry_evals.py` probes
`/evaluations` at startup and skips the entire pipeline with a single warning
if the project tier doesn't expose the endpoint (returns 404). Requires
Standard Agent Setup in Foundry.

### Config Structure

Single config at `config.json`. Required top-level: `labName`, `prefix`, `domain`, `cloud`. Each workload under `workloads` has `enabled: true/false`. Setting `enabled: false` skips the workload entirely — no validation is run against disabled workloads.

### Safety Defaults

- Conditional Access policies deploy in **report-only mode** (not enforced)
- MDCA session policies (CAAC) deploy in **report-only mode** via CA
- AuditConfig removal is **non-destructive** — audit logging stays enabled on teardown
- Defender for Cloud posture enables Standard pricing tiers (non-destructive on teardown)
- All Deploy/Remove functions support `-WhatIf` via `$PSCmdlet.ShouldProcess()`

## Conventions

- All resources prefixed with `{config.prefix}-` for reliable teardown
- Idempotent: check existence before creating; skip silently if already present
- `-WhatIf` support on all deploy/remove functions — must not make any changes when set
- Manifests in `manifests/` are git-ignored; they contain tenant-specific resource GUIDs
- Logs in `logs/` are git-ignored
- PSScriptAnalyzer must pass with zero warnings (excludes `PSAvoidUsingWriteHost`, `PSUseSingularNouns`)
- Label identity normalization: spaces replaced with dashes, GUID used for reliable lookups

## CI

GitHub Actions (`validate.yml`) runs six jobs:
1. **lint** — PSScriptAnalyzer with zero-warning policy
2. **test** — Pester tests from `tests/`
3. **smoke-test** — imports all modules, loads config, validates structure
4. **python-lint** — `ruff check scripts/`
5. **python-test** — `pytest scripts/tests/`
6. **bicep-validate** — `az bicep build` on all templates in `infra/`
