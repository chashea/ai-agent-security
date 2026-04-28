# AGENTS.md

AI agent guidance for working in this repository.

## Project Overview

Standalone AI agent security tool. Deploys Azure AI Foundry agents and wraps them with managed-identity RBAC, an APIM-based AI Gateway (TPM limits + token metrics), identity governance (Conditional Access), and Microsoft Defender controls (MDCA session policies, Defender for Cloud posture).

Single config file (`config.json`), modular by workload, deploy + teardown symmetry.

## Stack

- PowerShell 7+ (pwsh)
- Python 3.12 (Foundry agent SDK — `azure-ai-projects>=2.0.0`, `azure-identity`, `azure-search-documents`, `requests`)
- Bicep (ARM infrastructure in `infra/`)
- ExchangeOnlineManagement >= 3.0
- Microsoft.Graph SDK (Users, Groups, Authentication, AppCatalog)
- Az.Accounts (for Foundry/Azure deployment)

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

# Teardown
./Remove.ps1 -ConfigPath config.json

# Teardown with manifest (precise)
./Remove.ps1 -ConfigPath config.json -ManifestPath manifests/AISec_20260411-120000.json

# Lint
Invoke-ScriptAnalyzer -Path . -Recurse -Severity Warning -ExcludeRule PSAvoidUsingWriteHost,PSUseSingularNouns

# Tests
Invoke-Pester tests/ -Output Detailed

# Python lint + tests
ruff check scripts/
python3.12 -m pytest scripts/tests/ -v

# Validate Bicep
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
```

## Architecture

### Three-Layer Foundry Architecture

The Foundry workload uses three layers:
- **PowerShell + ARM REST** (`modules/FoundryInfra.psm1`) — RG, Foundry account,
  model + embeddings deployments, and the Foundry project (via direct ARM REST
  at `api-version=2026-01-15-preview`). Also handles Bot Services wiring, Teams
  package generation, and Teams catalog publishing.
- **Python SDK** (`scripts/foundry_agents.py`, `foundry_tools.py`,
  `foundry_knowledge.py`, `foundry_search_index.py`, `foundry_evals.py`,
  `foundry_redteam.py`) — Agent CRUD via `azure-ai-projects`, project
  connections, file_search vector stores, Azure AI Search index lifecycle
  (`aisec-compliance-index`, hybrid + semantic, `agent_scope` filter),
  post-deploy evaluations pipeline, AI red teaming.
- **Bicep** (`infra/`) — Eval infrastructure (`foundry-eval-infra.bicep`:
  AI Search, App Insights, Log Analytics), Bot Services (`bot-services.bicep`,
  `bot-per-agent.bicep`), Defender for Cloud posture (`defender-posture.bicep`),
  Foundry RAI guardrails (`guardrails.bicep`), APIM-based AI Gateway
  (`ai-gateway.bicep`), and Azure Policy guardrail initiatives
  (`foundry-builtin-policies.bicep`, `foundry-guardrail-policies.bicep`,
  `foundry-guardrail-per-risk.bicep`, `foundry-guardrail-violation-fixtures.bicep`).

Foundry core resources (account/model/project) are NOT in Bicep — the project
RP was flaky on MCAPS-governed tenants, so the per-resource retry loop in
`Invoke-ArmPut` ended up more reliable than nested ARM templates.

`Foundry.psm1` is a thin orchestrator that coordinates all layers.

### Config Loading

`Deploy.ps1` calls `Import-LabConfig -ConfigPath config.json` (from `modules/Prerequisites.psm1`). This validates required fields (`labName`, `prefix`, `domain`) and returns a PSCustomObject. The config object is passed into every workload function.

### Workload Invocation

Each workload is invoked only if `$config.workloads.<name>.enabled -eq $true`. Errors in one workload are isolated — they write to the log and set a failed-workloads list, but do not abort the remaining workloads unless it is a hard dependency (e.g., Foundry failure with `-FoundryOnly`).

### Error Isolation

Workload failures are caught per-workload. The orchestrator collects failures and reports a summary at the end. Use `Invoke-LabRetry` for transient Graph/EXO API calls.

## Deployment Order

1. Foundry — agents + Defender for Cloud posture
2. AgentIdentity — managed identity RBAC (auto-derived from tools)
3. AIGateway — APIM v2 + TPM limits + App Insights metrics
4. TestUsers — groups needed for policy scoping
5. ConditionalAccess — MFA + risky sign-in block (report-only)
6. MDCA — session monitoring + activity alerts + app governance

Removal is the exact reverse order.

## Module Contract

Every workload module exports:
- `Deploy-<Workload> -Config <PSCustomObject> [-WhatIf]` — deploys resources, returns hashtable of created resource IDs
- `Remove-<Workload> -Config <PSCustomObject> [-Manifest <PSCustomObject>] [-WhatIf]` — removes resources; uses manifest IDs when provided, falls back to prefix-based lookup

Utility modules (`Prerequisites.psm1`, `Logging.psm1`, `FoundryInfra.psm1`) do not follow the Deploy/Remove pattern.

## Conventions

- All resources prefixed with `{config.prefix}-` for reliable teardown
- Idempotent: check existence before creating; skip silently if already present
- `-WhatIf` support on all deploy/remove functions — must not make any changes when set
- Manifests in `manifests/` are git-ignored; they contain tenant-specific resource GUIDs
- All Write-Host output should use `Write-LabLog` from `Logging.psm1` for structured output
- PSScriptAnalyzer must pass with zero warnings (excludes `PSAvoidUsingWriteHost`, `PSUseSingularNouns`)
