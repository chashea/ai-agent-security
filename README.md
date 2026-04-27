# ai-agent-security

Secure AI agents deployed from Azure AI Foundry with adjacent identity and SaaS-app controls.

![Validate PowerShell](https://github.com/chashea/ai-agent-security/actions/workflows/validate.yml/badge.svg)

## What it does

Deploy AI agents from Azure AI Foundry and automatically wrap them with:

- **Knowledge bases** — Per-agent vector stores (file_search) **plus** a shared Azure AI Search index (`aisec-compliance-index`) with hybrid (keyword + HNSW vector) + semantic ranker, populated from `scripts/demo_docs/` with per-agent `agent_scope` filtering
- **Guardrails** — Custom RAI policy with tightened content filters (severity Low), jailbreak/indirect attack detection, PII annotation, and custom PII blocklists (SSN, credit card, bank account patterns)
- **Agent identity** — Managed identity and auto-derived RBAC for agents
- **Conditional Access** — MFA and risk-based access policies for agent principals (report-only)
- **Defender for Cloud Apps** — Session monitoring, activity alerts, and OAuth app governance
- **Defender for Cloud** — Security posture management for Foundry infrastructure
- **AI Red Teaming** — Automated adversarial probing via Microsoft's AI Red Teaming Agent (PyRIT-backed), with attack strategies (jailbreak, encoding bypass, prompt injection, multi-turn escalation) and ASR scorecards

## Getting started

Clone the repo, copy the sample config, and fill in your tenant-specific
values. `config.json` is git-ignored so your real values stay local.

```bash
git clone https://github.com/chashea/ai-agent-security.git
cd ai-agent-security
cp config.sample.json config.json
```

Edit `config.json` and replace every placeholder:

| Placeholder         | What to put                                                 |
|---------------------|-------------------------------------------------------------|
| `<SUBSCRIPTION_ID>` | Azure subscription ID (`az account show --query id -o tsv`) |
| `<TENANT_DOMAIN>`   | Your Entra tenant's primary domain, e.g. `contoso.onmicrosoft.com` |
| `<PUBLISHER_UPN>`   | UPN used for APIM publisher contact + agent identity        |
| `<USER_UPN>`        | UPN(s) added to the test groups (Finance/IT/Sales)          |

Then sign in and deploy:

```powershell
az login --tenant <YOUR_TENANT_ID>
az account set --subscription <SUBSCRIPTION_ID>
Connect-AzAccount -Tenant <YOUR_TENANT_ID>

./Deploy.ps1 -ConfigPath config.json
```

`config.json` carries defaults for agent rosters, knowledge bases,
evaluations, and guardrail policies — you only need to edit the
tenant-specific fields above to get a working deploy.

## Deployment modes

```powershell
# Full deployment: Foundry agents + labels + CA + MDCA
./Deploy.ps1 -ConfigPath config.json

# Labeling + identity only: skip Foundry
./Deploy.ps1 -ConfigPath config.json -SkipFoundry

# Foundry only: skip labeling and adjacent identity workloads
./Deploy.ps1 -ConfigPath config.json -FoundryOnly

# AI Gateway only: provisions APIM against existing Foundry; ~30 min
./Deploy.ps1 -ConfigPath config.json -AIGatewayOnly

# Dry run: validate config and show what would be deployed (no cloud connection)
./Deploy.ps1 -ConfigPath config.json -SkipAuth -WhatIf
```

### GitHub Actions (OIDC, no laptop required)

For Foundry-only deploys without setting up pwsh / Az / Python locally,
use the [`Deploy Foundry (OIDC)`](.github/workflows/deploy-foundry.yml)
workflow. It runs `Deploy.ps1 -FoundryOnly` against your subscription
using federated credentials — zero stored secrets.

**Setup (one-time):**

1. Create an Entra app registration (or user-assigned managed identity)
   and grant it the roles in
   [`.github/workflows/deploy-foundry.yml`](.github/workflows/deploy-foundry.yml)
   (Contributor + User Access Administrator + Cognitive Services
   Contributor + Search Service / Index Data Contributor).
2. Add a federated credential trusting your fork + this workflow —
   see [Microsoft docs](https://learn.microsoft.com/azure/developer/github/connect-from-azure-openid-connect).
3. In repo Settings → Secrets and variables → Actions, set the
   variables `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`,
   `AZURE_SUBSCRIPTION_ID`.
4. Run the workflow from the Actions tab → Deploy Foundry (OIDC) →
   Run workflow, providing the tenant domain and publisher UPN.

Teams catalog publish is gracefully skipped in this path (it needs
interactive Graph admin consent). Conditional Access / MDCA / EXO
labels are also skipped — run those locally with the standard
`./Deploy.ps1` flow.

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
| `aiGateway` | APIM-based AI Gateway in front of the Foundry AOAI endpoint with TPM limits, monthly quotas, and App Insights token metrics. See [`docs/ai-gateway.md`](docs/ai-gateway.md). |
| `testUsers` | User and group provisioning for scoped policy assignment |
| `conditionalAccess` | Conditional Access policies (MFA, risky sign-in block) for agent principals — report-only |
| `mdca` | Defender for Cloud Apps — session policies, activity alerts, OAuth app governance |

## Agents

The Foundry workload deploys 5 agents. Each agent's tools are auto-derived
for RBAC assignment by the `agentIdentity` workload.

| Agent | Tools |
|---|---|
| HR-Helpdesk | `code_interpreter`, `file_search`, `azure_ai_search`, `function`, `sharepoint_grounding`, `a2a`* |
| Finance-Analyst | `code_interpreter`, `file_search`, `azure_ai_search`, `azure_function`, `sharepoint_grounding`, `a2a`* |
| IT-Support | `code_interpreter`, `file_search`, `azure_ai_search`, `openapi`, `mcp`, `a2a`* |
| Sales-Research | `code_interpreter`, `file_search`, `bing_grounding`, `image_generation`, `a2a`* |
| Security-Triage | `openapi` (Graph Security API), `code_interpreter` |

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

## Smoke testing

`scripts/attack_via_gateway.py` (v0.16+) is the recommended adversarial
harness. It fires the 29-attack catalog through the live APIM AI
Gateway, captures the full `content_filter_result` per call, grades
each call into one of six outcomes (`pass-blocked-by-filter`,
`pass-refused-by-agent`, `FAIL-complied`, …), and emits a per-category
coverage matrix.

```bash
# Full catalog
python3.12 scripts/attack_via_gateway.py --output logs/run.json

# Assert ≥90% jailbreak-classifier coverage; exit 1 on breach
python3.12 scripts/attack_via_gateway.py --category prompt_injection \
  --assert --min-coverage 0.9

# Run + wait 15 min for Defender XDR alerts to materialize, correlate by run_id
python3.12 scripts/attack_via_gateway.py --output logs/full.json \
  --wait-for-alerts 15
```

Each run gets a `run_id` (`uuid4[:8]`) stamped into the chat-completions
`user` field for XDR / Purview correlation. See
[`docs/smoke-testing.md`](docs/smoke-testing.md) for the full
contract — attack catalog, grading model, coverage matrix, `--assert`
behavior, pre-push hook integration, and known gateway-TPM gotchas.

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
3. AIGateway        — APIM v2 + TPM limits + App Insights metrics
4. TestUsers        — groups used for policy scoping
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

### Git hooks

Mirrors CI checks locally so broken code doesn't land on main:

```bash
./scripts/install-hooks.sh
```

**Pre-commit** runs `ruff` on staged `scripts/**/*.py` and
`PSScriptAnalyzer` (Warning+, same exclusions as
`.github/workflows/validate.yml`) on staged `*.ps1` / `*.psm1` /
`*.psd1`. Fast (~2s).

**Pre-push** runs the full CI matrix — ruff, pytest, PSScriptAnalyzer,
Pester, `az bicep build` on every `infra/*.bicep`, and the
config-smoke-test — before any commit leaves the machine. Slow (~60s
depending on pytest retries). Skip individual jobs with env vars
(`SKIP_PYTEST=1`, `SKIP_PESTER=1`, `SKIP_BICEP=1`, `SKIP_PSSA=1`,
`SKIP_SMOKE=1`) when iterating; bypass entirely with
`git push --no-verify` only when explicitly instructed.

**Opt-in adversarial smoke** — set `RUN_ADVERSARIAL_SMOKE=1` to fire
`scripts/attack_via_gateway.py --category prompt_injection` (5 attacks
× 5 agents = 25 calls, ~45 s) through the live AI Gateway before push,
asserting **≥90% jailbreak-classifier coverage**. Catches RAI tuning
regressions and broken gateway policy XML. Requires an active
`az login` + a manifest with `aiGateway.starterSubscriptionKey`;
auto-skips with a clear message if either is missing.

### Subagents / skills

Five specialized agents available to both Claude Code
(`.claude/agents/*.md`) and GitHub Copilot CLI
(`.github/copilot/skills/*/SKILL.md`). They auto-activate on matching
triggers:

- **`foundry-troubleshooter`** — maps deploy errors to `docs/troubleshooting.md` entries.
- **`foundry-verifier`** — read-only check that deployed agent tool definitions match `config.json`.
- **`redteam-analyst`** — parses Step 8 red-team scorecards, ranks findings by ASR, and points at `infra/guardrails.bicep` / `config.json` for remediation.
- **`evaluator-interpreter`** — interprets Step 7 evaluator output (trust boundaries, red team resilience, prompt vulnerability), flags regressions vs. prior runs.
- **`triage-demo-validator`** — reads `logs/security-triage-demo-*.json`, flags hallucinations, silent refusals, scope violations (the read-only triage agent proposing destructive actions), KQL/OData sanity issues, and PII posture lapses in the Security-Triage agent's responses.

### MCP servers

Configured in `.github/copilot/mcp.json`:

- `microsoft-learn` — Microsoft docs search.
- `azure` — live Azure subscription / Foundry / Key Vault state via `@azure/mcp`.
- `github` — PRs, issues, workflow runs.
