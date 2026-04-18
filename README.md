# ai-agent-security

Secure AI agents deployed from Azure AI Foundry with sensitivity labels and adjacent identity controls.

![Validate PowerShell](https://github.com/chashea/ai-agent-security/actions/workflows/validate.yml/badge.svg)

## What it does

Deploy AI agents from Azure AI Foundry and automatically wrap them with:

- **Sensitivity labels** — AI-Accessible, AI-Protected, AI-Restricted, Executives-Only, with AI Search enforcement via the index managed identity
- **Knowledge bases** — Per-agent vector stores (file_search) **plus** a shared Azure AI Search index (`aisec-compliance-index`) with hybrid (keyword + HNSW vector) + semantic ranker, populated from `scripts/demo_docs/` with per-agent `agent_scope` filtering
- **Guardrails** — Custom RAI policy with tightened content filters (severity Low), jailbreak/indirect attack detection, PII annotation, and custom PII blocklists (SSN, credit card, bank account patterns)
- **Agent identity** — Managed identity and auto-derived RBAC for agents
- **Conditional Access** — MFA and risk-based access policies for agent principals (report-only)
- **Defender for Cloud Apps** — Session monitoring, activity alerts, and OAuth app governance
- **Defender for Cloud** — Security posture management for Foundry infrastructure
- **AI Red Teaming** — Automated adversarial probing via Microsoft's AI Red Teaming Agent (PyRIT-backed), with attack strategies (jailbreak, encoding bypass, prompt injection, multi-turn escalation) and ASR scorecards

## Deployment modes

```powershell
# Full deployment: Foundry agents + labels + CA + MDCA
./Deploy.ps1 -ConfigPath config.json

# Labeling + identity only: skip Foundry
./Deploy.ps1 -ConfigPath config.json -SkipFoundry

# Foundry only: skip labeling and adjacent identity workloads
./Deploy.ps1 -ConfigPath config.json -FoundryOnly

# Dry run: validate config and show what would be deployed (no cloud connection)
./Deploy.ps1 -ConfigPath config.json -SkipAuth -WhatIf
```

### Interactive mode

`Deploy-Interactive.ps1` and `Remove-Interactive.ps1` provide guided prompts
for deployment mode, cloud environment, and tenant selection. They wrap the
standard scripts with no additional logic:

```powershell
./Deploy-Interactive.ps1          # prompted deploy
./Remove-Interactive.ps1          # prompted teardown (includes manifest selection)
```

## Prerequisites

- PowerShell 7+
- Python 3.12+ (for Foundry agent SDK script)
- Azure Bicep CLI (`az bicep install`)
- Microsoft 365 E5 or E5 Compliance add-on (for sensitivity labels)
- Azure subscription (required for Foundry deployment)
- Required PowerShell modules:
  - `ExchangeOnlineManagement` >= 3.0
  - `Microsoft.Graph` (Users, Groups, Authentication, AppCatalog)
  - `Az.Accounts`
  - `PSScriptAnalyzer` (CI/lint only)
  - `Pester` >= 5.0 (tests only)
- Required Python packages: `pip install -r scripts/requirements.txt`
  - `azure-ai-projects` >= 2.0.0
  - `azure-identity` >= 1.15.0
  - `requests` >= 2.31.0
- Required Entra roles: Compliance Administrator (for labels), User Administrator

### Graph auth for managed identities

The [`graph-auth/`](graph-auth/) directory contains standalone scripts for granting
and testing Microsoft Graph permissions on Azure Managed Identities. Useful when
agent workloads need Graph access from compute resources. See
[`graph-auth/README.md`](graph-auth/README.md) for setup and permission details.

### Tenant prerequisites (MCAPS-governed tenants)

If your tenant is governed by the MCAPS policy set
(`mcapsgovdeploypolicies`), the `CognitiveServices_LocalAuth_Modify` policy
forces `disableLocalAuth: true` on new Cognitive Services accounts and
breaks Foundry project creation. Create a policy exemption on the target
resource group before running `Deploy.ps1`:

```bash
az policy exemption create \
  --name "foundry-localauth-exempt" \
  --policy-assignment "/providers/microsoft.management/managementgroups/<tenantId>/providers/microsoft.authorization/policyassignments/mcapsgovdeploypolicies" \
  --exemption-category Waiver \
  --scope "/subscriptions/<subId>/resourceGroups/<rgName>"
```

### Region

Foundry core resources are deployed to `eastus2` by default (set via
`workloads.foundry.location` in `config.json`). Other regions may hit
capacity limits or project-RP issues.

### Publishing agents to Teams / Microsoft 365 Copilot

`Deploy.ps1` connects Microsoft Graph automatically in every mode
(including `-FoundryOnly`) with the minimal `AppCatalog.ReadWrite.All`
scope via device code. The Teams catalog publish (`Publish-TeamsApps`)
pushes each `packages/foundry/*.zip` to the org app catalog using a
deterministic `manifest.json` id (`MD5(prefix/shortName)` rendered as a
GUID) and a monotonic `version` (`1.<mmdd>.<hhmmss>` UTC), so reruns
update the existing tenant app rather than creating duplicates.

**Publishing to the catalog is automated; deploying to users is not.**
Getting the apps into a user's Teams sidebar requires either:

- Approving them in **M365 admin center → Integrated apps → Deploy**
  (one click per app, assigns to user groups), OR
- Adding them to a Teams app setup policy via the Teams admin center.

The automated per-user install path (`POST /users/{id}/teamwork/installedApps`)
returns 403 under MCAPS tenant policy even with the correct Graph scope
granted. See [`docs/post-deploy-steps.md`](docs/post-deploy-steps.md#2-deploy-teams-apps-to-users)
for the full click path and alternatives.

### Post-deploy manual steps

`Deploy.ps1` cannot handle every step — a handful of items require tenant
admin approval, external resource provisioning, or MCAPS-policy exceptions.
After every clean deploy, work through
[`docs/post-deploy-steps.md`](docs/post-deploy-steps.md):

1. Approve Agent 365 digital-worker submissions (M365 admin center)
2. Deploy Teams apps to users (Integrated Apps)
3. Enable Defender for Cloud "Data security for AI interactions"
4. Populate SharePoint siteUrl if you want SharePoint grounding
5. Provision a Grounding with Bing Search resource if you want Bing

## Quick start

```powershell
git clone https://github.com/chashea/ai-agent-security.git
cd ai-agent-security

# Edit config.json with your tenant domain, subscription, and agent definitions
# Then deploy:
./Deploy.ps1 -ConfigPath config.json

# Teardown:
./Remove.ps1 -ConfigPath config.json
```

## Configuration

`config.json` is the single configuration file. Top-level required fields:

| Field | Description |
|---|---|
| `labName` | Human-readable deployment name |
| `prefix` | Short prefix applied to all created resources (e.g., `AISec`) |
| `domain` | Tenant domain (e.g., `contoso.onmicrosoft.com`) |
| `cloud` | `commercial` (default) |

Each workload under `workloads` has an `enabled` boolean. Set to `false` to skip that workload entirely.

## Workloads deployed

| Workload | Description |
|---|---|
| `foundry` | Azure AI Foundry account, project, model deployment, and agent definitions |
| `agentIdentity` | Managed identity and auto-derived RBAC assignments for agent principals |
| `testUsers` | User and group provisioning for scoped policy assignment |
| `sensitivityLabels` | Sensitivity label hierarchy with AI-tier sublabels, auto-label policies, and AI Search MI role grants |
| `conditionalAccess` | Conditional Access policies (MFA, risky sign-in block) for agent principals — report-only |
| `mdca` | Defender for Cloud Apps — session policies, activity alerts, OAuth app governance |

## Agents

The Foundry workload deploys 7 agents. Each agent's tools are auto-derived
for RBAC assignment by the `agentIdentity` workload.

| Agent | Tools |
|---|---|
| HR-Helpdesk | `code_interpreter`, `file_search`, `azure_ai_search`, `function`, `sharepoint_grounding`, `a2a`* |
| Finance-Analyst | `code_interpreter`, `file_search`, `azure_ai_search`, `azure_function`, `sharepoint_grounding`, `a2a`* |
| IT-Support | `code_interpreter`, `file_search`, `azure_ai_search`, `openapi`, `mcp`, `a2a`* |
| Sales-Research | `code_interpreter`, `file_search`, `bing_grounding`, `image_generation`, `a2a`* |
| Kusto-Analyst | `code_interpreter`, `file_search`, `azure_ai_search`, `azure_function` |
| Entra-Specialist | `code_interpreter`, `file_search`, `azure_ai_search`, `openapi` |
| Defender-Analyst | `code_interpreter`, `file_search`, `azure_ai_search`, `mcp` |

\* `a2a` (agent-to-agent) requires `workloads.foundry.connections.a2a` in config so an Agent2Agent project connection is provisioned and wired into the `a2a_preview` tool via `project_connection_id`.

## AI Red Teaming

The deployment pipeline includes an automated AI Red Teaming step (Step 8) that
probes deployed agents for safety vulnerabilities using Microsoft's
[AI Red Teaming Agent](https://learn.microsoft.com/en-us/azure/foundry/concepts/ai-red-teaming-agent)
backed by [PyRIT](https://github.com/microsoft/PyRIT).

### Modes

| Mode | SDK | Scope | Region requirement |
|---|---|---|---|
| **Local** (`scan`) | `azure-ai-evaluation[redteam]` | Content/model risks: violence, hate, sexual, self-harm, protected material, code vulnerability, ungrounded attributes | Any region with a Foundry project |
| **Cloud** (`cloud-scan`) | `azure-ai-projects` | Agentic risks: prohibited actions, sensitive data leakage, task adherence + taxonomy-driven probing | East US 2, France Central, Sweden Central, Switzerland West, North Central US |

Cloud mode falls back to local if the project region is unsupported.

### Attack strategies

Configured in `config.json` under `workloads.foundry.redTeaming.attackStrategies`:

| Complexity | Strategies |
|---|---|
| Easy | Base64, Flip, Morse, Jailbreak, AsciiArt, Leetspeak, ROT13, UnicodeConfusable, IndirectAttack |
| Moderate | Tense |
| Difficult | Crescendo, Multiturn |

### Setup

```bash
# Install red teaming extras (optional — only needed for local scans)
pip install -r scripts/requirements-redteam.txt
```

Set `workloads.foundry.redTeaming.enabled` to `true` in `config.json` (enabled
by default). The pipeline runs automatically at the end of `Deploy.ps1`.

### Key metric

**Attack Success Rate (ASR)** — percentage of adversarial prompts that
successfully elicit undesirable responses. Results are logged to the deployment
manifest under `redTeaming.agentScans[].scorecard`.

## Security-Triage demo

`scripts/demo_security_triage.py` pulls recent Defender XDR alerts via
Microsoft Graph and pipes each one through the deployed Security-Triage
Foundry agent, capturing the agent's triage response per alert. See
[`docs/security-triage-agent/demo-usage.md`](docs/security-triage-agent/demo-usage.md)
for usage:

```bash
python3.12 scripts/demo_security_triage.py --since-minutes 60 --top 3
```

Outputs `logs/security-triage-demo-<UTC>.json` with `{alert, run_status,
duration_ms, assistant_response}` per alert.

## Architecture

The Foundry workload uses a three-layer architecture:
- **PowerShell + ARM REST** (`modules/FoundryInfra.psm1`) for Foundry account,
  model deployments, and project creation (direct ARM REST at
  `api-version=2026-01-15-preview`), plus Teams packaging and catalog publishing
- **Python SDK** (`scripts/*.py`) for agent CRUD, project connections,
  knowledge base / vector stores, AI Search index population
  (`foundry_search_index.py`), post-deploy evaluations, and AI red teaming
- **Bicep** (`infra/`) for eval infrastructure (AI Search with AAD-or-key auth
  + semantic ranker enabled), Bot Services, and Defender posture

Deployment order (dependency-driven):

```
1. Foundry          — agents + Defender for Cloud posture
2. AgentIdentity    — managed identity RBAC (auto-derived from tools)
3. TestUsers        — groups used for label scoping
4. SensitivityLabels — label hierarchy + auto-label policies + AI Search MI roles
5. ConditionalAccess — MFA + risky sign-in block (report-only)
6. MDCA              — session monitoring + activity alerts + app governance
```

Removal runs the exact reverse order.

### Deployment manifests

Each successful deploy writes a manifest to `manifests/<prefix>_<timestamp>.json`
containing all created resource IDs. `Remove.ps1 -ManifestPath` uses the manifest
for precise, targeted teardown. Without a manifest, removal falls back to
prefix-based resource lookup.

## Troubleshooting

See [`docs/troubleshooting.md`](docs/troubleshooting.md) for a catalog of
errors encountered on MCAPS-governed tenants and the fixes for each.
Covers Foundry project RP quirks, connection API gotchas, Teams catalog
publish idempotency, and more.

## Developer tooling

### Pre-commit hook

Mirrors CI checks locally so lint errors don't land on main:

```bash
./scripts/install-hooks.sh
```

Runs `ruff` on staged `scripts/**/*.py` and `PSScriptAnalyzer`
(Warning+, same exclusions as `.github/workflows/validate.yml`) on
staged `*.ps1` / `*.psm1` / `*.psd1`. Bypass only when explicitly
instructed: `git commit --no-verify`.

### Subagents / skills

The same four specialized agents are available to both Claude Code
(`.claude/agents/*.md`) and GitHub Copilot CLI
(`.github/copilot/skills/*/SKILL.md`). They auto-activate on matching
triggers:

- **`foundry-troubleshooter`** — maps deploy errors to `docs/troubleshooting.md` entries.
- **`foundry-verifier`** — read-only check that deployed agent tool definitions match `config.json`.
- **`redteam-analyst`** — parses Step 8 red-team scorecards, ranks findings by ASR, and points at `infra/guardrails.bicep` / `config.json` for remediation.
- **`evaluator-interpreter`** — interprets Step 7 evaluator output (trust boundaries, red team resilience, prompt vulnerability), flags regressions vs. prior runs.

### MCP servers

Configured in `.github/copilot/mcp.json`:

- `microsoft-learn` — Microsoft docs search.
- `azure` — live Azure subscription / Foundry / Key Vault state via `@azure/mcp`.
- `github` — PRs, issues, workflow runs.
