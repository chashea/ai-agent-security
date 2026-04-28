# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Standalone AI agent security tool. Deploys Azure AI Foundry agents and wraps them with managed-identity RBAC, an APIM-based AI Gateway (TPM limits + token metrics), Conditional Access, and Defender for Cloud Apps controls.

Single config file (`config.json`), modular by workload, deploy + teardown symmetry. Supports `-SkipFoundry` (identity/CA/MDCA only), `-FoundryOnly` (Foundry only), and `-AIGatewayOnly` (APIM gateway only) modes.

## Stack

- PowerShell 7+ (pwsh)
- Python 3.12 (Foundry agent SDK — `azure-ai-projects>=2.0.0`, `azure-identity`, `requests`)
- Bicep (ARM infrastructure templates in `infra/`)
- ExchangeOnlineManagement >= 3.0
- Microsoft.Graph SDK (Users, Groups, Authentication)
- Az.Accounts (for Foundry/Azure deployment)

## Tenant

Target tenant is configured per-user in `config.json`. On the first
`./Deploy.ps1` run, the script auto-bootstraps `config.json` from
`config.sample.json` (if absent) and prompts for `<TENANT_DOMAIN>`,
`<SUBSCRIPTION_ID>`, `<PUBLISHER_UPN>`, and "Create new test users? [y/N]"
(see `Resolve-LabConfigPlaceholders` and `Request-CreateTestUsersChoice`
in `modules/Interactive.psm1`). Answers are persisted so subsequent
runs are silent. CI and tests use a fixture domain. Helper scripts that
need a tenant ID read from `-TenantId` or `$env:AZURE_TENANT_ID`.

## Commands

```powershell
# Full deploy
./Deploy.ps1 -ConfigPath config.json

# Identity / CA / MDCA only (skip Foundry + AI Gateway)
./Deploy.ps1 -ConfigPath config.json -SkipFoundry

# Foundry-only
./Deploy.ps1 -ConfigPath config.json -FoundryOnly

# AI Gateway-only (assumes Foundry exists)
./Deploy.ps1 -ConfigPath config.json -AIGatewayOnly

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
az bicep build --file infra/guardrails.bicep
az bicep build --file infra/ai-gateway.bicep
az bicep build --file infra/foundry-builtin-policies.bicep
az bicep build --file infra/foundry-guardrail-policies.bicep
az bicep build --file infra/foundry-guardrail-per-risk.bicep
az bicep build --file infra/foundry-guardrail-violation-fixtures.bicep

# Deploy + fire adversarial traffic at end to light up detections
./Deploy.ps1 -ConfigPath config.json -AdversarialTraffic

# Security-Triage demo: Defender XDR alerts → Foundry triage agent
python3.12 scripts/demo_security_triage.py --since-minutes 60 --top 3

# Red-team trend HTML report (auto-runs after Step 8 in Deploy.ps1)
python3.12 scripts/trend_redteam.py --html logs/trend.html
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
                                foundry_redteam.py
                                 AI Red Teaming Agent,
                                 local + cloud scan,
                                 PyRIT attack strategies,
                                 ASR scorecards
```

**Deployment flow:**
1. `Deploy-FoundryBicep` (in `FoundryInfra.psm1`) creates RG, account, gpt-4o model,
   embeddings model, and the project via direct ARM REST
   (`api-version=2026-01-15-preview`). Then deploys `foundry-eval-infra.bicep`
   to the RG for AI Search / App Insights / Log Analytics.
2. `foundry_tools.py setup-connections` creates project connections via ARM
   control plane (`accounts/projects/connections`). Data-plane `/connections`
   returns HTTP 405.
3. `foundry_knowledge.py upload` uploads demo docs, creates per-agent
   vector stores, returns vector store IDs.
3b. `foundry_search_index.py populate` creates `aisec-compliance-index`
   on the Azure AI Search service with hybrid (HNSW vector) + semantic
   config, then uploads the same demo doc corpus tagged with an
   `agent_scope` filterable field. Embeddings come from the existing
   `text-embedding-3-small` deployment via `DefaultAzureCredential`.
   Idempotent (`mergeOrUpload` on stable doc IDs). Required because
   three agents (`HR-Helpdesk`, `Finance-Analyst`, `IT-Support`)
   declare an `azure_ai_search` tool — without this step the index
   doesn't exist and queries silently return zero results.
4. `foundry_tools.py build-tools` builds per-agent tool definition dicts,
   injecting vector store IDs + connection IDs.
5. `foundry_agents.py deploy` creates agents via `azure-ai-projects` SDK and
   publishes each as a Foundry application, returning a `baseUrl`.
6. PowerShell: Teams declarative-agent packages + Bot Services + Teams catalog
   publish (stable manifest id + monotonic version for idempotent reruns).
7. `foundry_evals.py evaluate` probes the evaluations endpoint; runs prompt
   optimization, custom evaluators, batch eval (quality+safety), and
   continuous eval if available.
8. `foundry_redteam.py scan` (or `cloud-scan`) runs the AI Red Teaming Agent
   against deployed agents. Local mode uses PyRIT-backed adversarial probing
   with configurable attack strategies and risk categories. Cloud mode uses
   Foundry's eval API with taxonomy-driven agentic risk testing (prohibited
   actions, sensitive data leakage, task adherence). Outputs ASR scorecards.

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
3. AIGateway — APIM v2 in front of Foundry AOAI with TPM + quota + metrics
4. TestUsers — groups used for policy scoping
5. ConditionalAccess — MFA + risky sign-in block (report-only)
6. MDCA — session monitoring + activity alerts + app governance

Removal is the exact reverse.

### Module Contract

Every workload module in `modules/` exports:
- `Deploy-<Workload> -Config <PSCustomObject> [-WhatIf]` — returns hashtable of created resource IDs (manifest data)
- `Remove-<Workload> -Config <PSCustomObject> [-Manifest <PSCustomObject>] [-WhatIf]` — uses manifest for precise removal, falls back to config + prefix

Exceptions: `Prerequisites.psm1`, `Logging.psm1`, `Interactive.psm1`, and `FoundryInfra.psm1` are utility/infrastructure modules (no Deploy/Remove exports).

### Key Utility Functions (Prerequisites.psm1)

- `Import-LabConfig` — JSON loader with required field validation (labName, prefix, domain)
- `Test-LabConfigValidity` — validates enabled workloads have required subfields (e.g., conditionalAccess.policies, mdca.policies)
- `Invoke-LabRetry -ScriptBlock -MaxAttempts 3 -DelaySeconds 5` — generic retry for transient Graph/EXO failures
- `Get-LabSupportedParameterName` — inspects cmdlet parameters to handle version differences across module releases
- `Connect-LabServices` / `Disconnect-LabServices` — multi-service auth (EXO, Graph, optional Azure)
- `Resolve-LabTenantDomain` — verifies config domain against tenant; auto-corrects if mismatched
- `Export-LabManifest` / `Import-LabManifest` — JSON serialization with `generatedAt` timestamp

### Key Patterns

- **Parameter fallback**: Modules use `Get-LabSupportedParameterName` to detect cmdlet capability at runtime, since parameter names vary across module versions.
- **Post-deploy validation** (Deploy.ps1): Retries 6 times with 5-second delays to handle Microsoft Graph eventual consistency lag.
- **Long-running operations**: Foundry uses `Wait-ArmAsyncOperation` in FoundryInfra.psm1.
- **PowerShell-to-Python interface**: `Invoke-FoundryPython` helper writes JSON config to a temp file, invokes `python3.12 scripts/<script>.py --action <verb> --config <path>`, captures JSON manifest from stdout. Python scripts invoked by the orchestrator: `foundry_agents.py` (agent CRUD), `foundry_tools.py` (connections + tool definitions), `foundry_knowledge.py` (vector stores + doc upload), `foundry_search_index.py` (Azure AI Search index lifecycle + doc upload with embeddings), `foundry_evals.py` (evaluations pipeline), `foundry_redteam.py` (AI Red Teaming). Standalone CLI scripts (not invoked by Deploy.ps1): `demo_security_triage.py` (Defender alerts → Triage agent), `fetch_defender_alerts.py` (Graph security alert pull — also importable), `attack_agents.py` (adversarial traffic catalog, opt-in via `-AdversarialTraffic`), `trend_redteam.py` (manifest-diff ASR regressions + HTML report). API versions are passed from PowerShell (single source of truth).
- **Agent tools**: Each agent gets tools defined in `config.json` under `agents[].tools[]`. Tool definitions are built by `foundry_tools.py`, injecting runtime values (vector store IDs, connection IDs) from earlier deployment steps. Currently supports: code_interpreter, file_search, azure_ai_search, bing_grounding, openapi, azure_function, function, mcp, sharepoint_grounding, a2a, image_generation, connected_agent (used by the Concierge orchestrator).
- **Security-Triage demo**: `scripts/demo_security_triage.py` pulls recent Defender XDR alerts via Microsoft Graph (`SecurityAlert.Read.All` + `SecurityIncident.Read.All`), ranks top-N by severity, and pipes each one through the deployed Security-Triage Foundry agent using the thread/message/run REST pattern shared with `foundry_redteam.py` (`_build_agent_callback` at `scripts/foundry_redteam.py:106-144`). Writes `logs/security-triage-demo-<UTC>.json` with `{alert, run_status, duration_ms, assistant_response}` per alert. Reads the agent id from the latest `manifests/*.json`. Requires `az login` against the target sub.
- **Red-team trend HTML**: `scripts/trend_redteam.py --html <path>` renders a standalone HTML report (per-agent ASR table, evaluator metrics, regression highlighting). Auto-invoked by `modules/Foundry.psm1` after Step 8 against the prior manifest; writes `logs/redteam-trend-<stamp>.html`. Non-fatal on error.
- **Adversarial traffic switch**: `Deploy.ps1 -AdversarialTraffic` invokes `scripts/attack_agents.py` (legacy agent-thread path) after agents deploy and writes `logs/attack_<stamp>.json`. Generates real alerts in Defender XDR / Purview / Foundry evaluators — opt-in only, lab tenants only.
- **Smoke testing harness (v0.16+)**: `scripts/attack_via_gateway.py` is the recommended path — fires through the AI Gateway, captures the full `content_filter_result`, grades into 6 outcomes (`pass-blocked-by-filter`, `pass-refused-by-agent`, `FAIL-complied`, `FAIL-network`, `pass-blocked-other`, `skip-rate-limited`), emits per-category coverage matrix, supports `--assert --min-coverage X` for CI. Stamps `run_id` (uuid4[:8]) into the chat-completions `user` field for XDR/Purview correlation; `--wait-for-alerts N` pulls Defender XDR via Graph after the burst. Full contract in `docs/smoke-testing.md`.
- **Post-deploy evaluations**: Run automatically as Step 7 in Deploy-Foundry. Includes prompt optimization, custom evaluator creation (compliance_adherence), batch eval with synthetic data (quality + safety + agent evaluators), and continuous evaluation enablement (10% sampling).
- **AI Red Teaming**: Runs as Step 8 in Deploy-Foundry (after evaluations). Uses Microsoft's AI Red Teaming Agent (PyRIT-backed) to probe deployed agents for content safety risks, prompt injection, jailbreak, encoding bypasses, and more. Local mode sends adversarial prompts through transient Foundry threads (cleaned up after each probe). Cloud mode uses Foundry eval API with taxonomy-driven agentic risk testing. `azure-ai-evaluation[redteam]` is an optional dependency (separate `requirements-redteam.txt`). Cloud mode requires a supported region (East US 2, France Central, Sweden Central, Switzerland West, North Central US); falls back to local on unsupported regions.
- **Logging**: All output goes through `Write-LabLog` (Level: Info/Warning/Error/Success) and `Write-LabStep` for visual sections. Transcripts auto-cleanup after 30 days.

### Post-deploy manual steps (v0.11.0+, current as of v0.20.0)

Most post-deploy items are now automated. See
[`docs/post-deploy-steps.md`](docs/post-deploy-steps.md) for the full
checklist. Remaining manual items (all blocked by MCAPS or external
resources):

1. Approve Agent 365 digital-worker submissions at
   <https://admin.cloud.microsoft/?#/agents/all/requested> — no API available.
2. Deploy Teams apps to users via M365 admin center → Integrated apps —
   per-user install via Graph is 403'd by MCAPS policy.
3. Populate SharePoint `siteUrl` in `config.json` → `workloads.foundry.connections.sharePoint` if SharePoint grounding is desired (tool skipped otherwise).

**Automated (no action needed):**
- Defender for Cloud "Data security for AI interactions" — wired into `infra/defender-posture.bicep` as `Microsoft.Security/pricings@2024-01-01` (name `AI`, extensions `AIModelScanner` + `AIPromptEvidence` + `AIPromptSharingWithPurview`).
- Bing Grounding — set `workloads.foundry.connections.bingSearch.provision: true` to auto-provision a `Microsoft.Bing/accounts` resource.
- Agent-to-Agent (a2a) project connection — auto-created when `workloads.foundry.connections.a2a` is present in config.
- Foundry guardrail-baseline Azure Policy initiative — `infra/foundry-guardrail-policies.bicep`.
- Adversarial traffic fire — `Deploy.ps1 -AdversarialTraffic`.

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

**Region.** Tested in `eastus2` (current default). Earlier attempts in
`eastus` and `centralus` hit either capacity
(`InsufficientResourcesAvailable`) or project-RP errors.

**Project connections are ARM resources.** Use the ARM control-plane path
`Microsoft.CognitiveServices/accounts/projects/connections` for
CRUD — the data-plane `<projectEndpoint>/connections` returns HTTP 405
on PUT. `scripts/foundry_tools.py setup_connections()` uses ARM.

**Bing grounding requires a project connection.** The `bing_grounding`
tool's `search_configurations[].project_connection_id` is now a **required**
field on the preview API (earlier builds accepted empty strings / missing
fields — that was the pre-v0.8 assumption). If no `Grounding with Bing
Search` connection exists on the project, `foundry_tools.py` skips the
tool and emits a warning. Provision a Bing Search resource and add it via
`workloads.foundry.connections.bingSearch` to enable web grounding.

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
- `a2a_preview` takes a flat `project_connection_id` pointing at a project
  connection of category `Agent2Agent`. The connection is auto-provisioned
  by `scripts/foundry_tools.py setup_connections` when
  `workloads.foundry.connections.a2a` is set in config. The tool is
  skipped with a warning if no connection exists.

**PowerShell → Python JSON depth must be 20+.** `Invoke-FoundryPython`
in `modules/Foundry.psm1` serializes `$InputData` with `ConvertTo-Json
-Depth 20`. The depth-10 default truncates deeply nested objects like
`openapi.config.paths` to `@{...}` PowerShell-hashtable strings, which
Python then reads as literal strings and Foundry accepts without
error — producing an agent with an unusable OpenAPI tool. Do not lower
the depth.

**Agent update path requires delete-then-recreate.** `scripts/foundry_agents.py
create_agent` checks for an existing agent by name; if present, it
`DELETE`s before issuing the `POST`. Foundry prompt agents have no PATCH
endpoint, so returning early on existence leaves stale tool state on the
server (old tools, old instructions, missing new tools). This means
mid-deploy `create_agent` failures will leave the agent deleted — any
tool builder bug is now a hard error rather than a silent "tools not
refreshed" warning.

**Teams catalog publishing is idempotent.** `New-FoundryAgentPackage` emits
a deterministic `manifest.json` id (`MD5(prefix/shortName)` rendered as a
GUID) and a monotonic `version` (`1.<mmdd>.<hhmmss>` UTC). `Publish-TeamsApps`
matches existing tenant apps by `externalId`, so reruns update the existing
app rather than creating duplicates. `-FoundryOnly` mode now connects
Graph with `AppCatalog.ReadWrite.All` via device code (see `Deploy.ps1`
auth step) — no more "skipped: Graph not connected" warning. The
`HTTP 403 Forbidden` on `/appCatalogs/teamsApps` means the signed-in
user lacks tenant-level Teams admin rights OR custom app upload is
disabled at the tenant level (common on MCAPS tenants). Sideload the
zipped packages in `packages/foundry/*.zip` per-user instead.

**`-FoundryOnly` Graph authentication.** Deploy.ps1 used to skip Graph
connect entirely in `-FoundryOnly` mode. It now connects Graph with a
minimal scope set (`AppCatalog.ReadWrite.All` only) using
`-UseDeviceCode`, which works in both interactive shells and background
pwsh (the default browser/broker flow hangs when stdin is not a TTY).
MSAL caches the refresh token to `~/.IdentityService`, so subsequent
reruns within the token lifetime complete silently.

**Python `DefaultAzureCredential` follows the az CLI default.** PowerShell
`Connect-AzAccount` and `az login` maintain **separate** contexts. The
Python scripts (`foundry_tools.py`, `foundry_agents.py`,
`foundry_knowledge.py`) use `DefaultAzureCredential`, which falls through
to `AzureCliCredential` — so `az account show` must point at the target
subscription/tenant before any deploy runs. Symptom of a mismatch: every
data-plane call returns `HTTP 401 wrong issuer` or `HTTP 400 Token tenant
does not match resource tenant`. Fix with
`az account set --subscription <id>`.

**Evaluations pipeline may be unavailable.** `foundry_evals.py` probes
`/evaluations` at startup and skips the entire pipeline with a single warning
if the project tier doesn't expose the endpoint (returns 404). Requires
Standard Agent Setup in Foundry.

**Azure AI Search data-plane requires AAD + RBAC.** The Bicep enables
`authOptions.aadOrApiKey` so the populator's bearer token is accepted.
The deploying identity also needs **`Search Service Contributor`**
(create/update index) **and** `Search Index Data Contributor`** (upload
docs) on the Search resource. `Deploy-FoundryBicep` grants both roles to
the signed-in user (`az ad signed-in-user show --query id -o tsv`)
right after the eval-infra Bicep deploys. Failure to grant is a
warning, not fatal — but `foundry_search_index.py` will then fail with
HTTP 403 and the index will not be populated. Symptom in the agent UX:
`azure_ai_search` returns zero results.

**Embeddings throttle on small TPM quotas.** `text-embedding-3-small`
defaults to a low TPM quota (~1K) on new Foundry accounts. Uploading
the 12 demo documents through the populator can spend 5-10 minutes on
429 backoff. The retry budget (8 attempts × exponential backoff) is
large enough to absorb this; if a deploy hangs longer than that on the
`AI Search Index` step, raise the deployment quota in the Foundry
portal → Models + endpoints → text-embedding-3-small → Edit.

### Config Structure

Single config at `config.json`. Required top-level: `labName`, `prefix`, `domain`, `cloud`. Each workload under `workloads` has `enabled: true/false`. Setting `enabled: false` skips the workload entirely — no validation is run against disabled workloads.

### Safety Defaults

- Conditional Access policies deploy in **report-only mode** (not enforced)
- MDCA session policies (CAAC) deploy in **report-only mode** via CA
- Defender for Cloud posture enables Standard pricing tiers for Storage, App Services, Key Vault, ARM, and **AI** (non-destructive on teardown). The AI plan enables prompt/response capture + Purview sharing — set `enableAIDefender: false` in `infra/defender-posture.bicep` to opt out.
- All Deploy/Remove functions support `-WhatIf` via `$PSCmdlet.ShouldProcess()`
- `-AdversarialTraffic` is **opt-in only** — generates real alerts, lab/demo tenants only.

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

## Git hooks

`./scripts/install-hooks.sh` wires both hooks via `core.hooksPath`:

- **`.githooks/pre-commit`** runs `ruff` on staged `scripts/**/*.py`
  and `PSScriptAnalyzer` (Warning level, same exclusions as CI) on
  staged `*.ps1` / `*.psm1` / `*.psd1`. Fast (~2s).
- **`.githooks/pre-push`** mirrors the full CI matrix: ruff, pytest,
  PSScriptAnalyzer (repo-wide), Pester, `az bicep build` on every
  `infra/*.bicep`, and the smoke-test. Skip individual jobs via env
  (`SKIP_PYTEST=1`, `SKIP_PESTER=1`, `SKIP_BICEP=1`, `SKIP_PSSA=1`,
  `SKIP_SMOKE=1`). Bypass entirely with `git push --no-verify` only
  when the user explicitly asks.
  - **Opt-in adversarial smoke** (`RUN_ADVERSARIAL_SMOKE=1`): fires
    `attack_via_gateway.py --category prompt_injection` (5 attacks ×
    5 agents = 25 calls, ~45s) through the live AI Gateway and
    asserts ≥90% jailbreak classifier coverage. Catches RAI tuning
    regressions and gateway policy XML breakage. Requires `az login`
    + a manifest with `aiGateway.starterSubscriptionKey`. Auto-skips
    if any prerequisite is missing.

Only use `--no-verify` on either hook when the user explicitly
authorizes it — hooks are load-bearing (catch real CI failures locally).

## Releases

Every push to `main` gets a new GitHub release with a version tag
(`v<major>.<minor>.<patch>`) and markdown bullet release notes. Use
`gh release create vX.Y.Z --title "vX.Y.Z — <headline>" --notes "..."`
with manual notes; never `--generate-notes`. Current version: **v0.20.0**
(local `Deploy.ps1` is the only supported deploy path; the prior
`deploy-foundry` GitHub Actions workflow was retired in favor of the
device-code/local flow).

## Post-push CI watch (automatic)

Any time a `git push` to `origin` succeeds from this repo — whether I
ran it or the user did — I must autonomously watch the GitHub Actions
run to completion and repair any failures without being asked. No
confirmation prompts, no "do you want me to…" — just do it.

**Loop:**

1. Immediately after the push returns, launch the `devops-engineer`
   subagent with the head SHA and instruct it to poll
   `gh run watch --exit-status` (or equivalent) until the run finishes.
2. If the run **succeeds** → report green and stop.
3. If the run **fails** → launch the appropriate fix subagent
   (`software-engineer` for code/test failures, `devops-engineer` for
   workflow or infra-compile failures, `database-engineer` for
   migration failures) with the failing job's log excerpt. It must
   apply a real fix (no `--no-verify`, no skipping jobs), commit, and
   push again.
4. Return to step 1 with the new SHA. Repeat until the run is green
   or a fix attempt fails three times in a row — in which case stop
   and surface the blocker to the user.

**Constraints:**

- Never bypass hooks (`--no-verify`) or disable a failing CI job to
  force-green. Fix the root cause.
- Never force-push to `main`.
- Each fix attempt is its own commit with a descriptive message
  (`ci: fix <job> — <root cause>`), so the history explains itself.
- Cache the last watched SHA in memory so re-entering the loop after
  a fix commit doesn't poll the stale run.
- If `gh` is not authenticated, stop and tell the user — don't guess.

Applies to this repo only (scope: the `CLAUDE.md` at the repo root).
