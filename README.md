# ai-agent-security

Secure AI agents deployed from Azure AI Foundry with Microsoft Purview, DLP, sensitivity labels, and identity controls.

![Validate PowerShell](https://github.com/chashea/ai-agent-security/actions/workflows/validate.yml/badge.svg)

## What it does

Deploy AI agents from Azure AI Foundry and automatically wrap them with enterprise security controls:

- **Sensitivity labels** — AI-Accessible, AI-Protected, AI-Restricted, Executives-Only
- **DLP policies** — Block PII in AI prompts, block labeled content from agents, block shadow AI uploads
- **Retention** — 1-year AI interaction retention
- **eDiscovery** — AI governance investigation cases
- **Communication compliance** — DSPM for AI agent interactions
- **Insider risk** — Risky AI usage policies
- **Conditional Access** — MFA and risk-based access policies for agent principals
- **Agent identity** — Managed identity and auto-derived RBAC for agents
- **Defender for Cloud Apps** — Session monitoring, activity alerts, and OAuth app governance
- **Defender for Cloud** — Security posture management for Foundry infrastructure

## Deployment modes

```powershell
# Full deployment: Foundry agents + all Purview security controls
./Deploy.ps1 -ConfigPath config.json

# Security-only: Purview controls without Foundry deployment
./Deploy.ps1 -ConfigPath config.json -SkipFoundry

# Foundry-only: Deploy agents without Purview controls
./Deploy.ps1 -ConfigPath config.json -FoundryOnly

# Dry run: validate config and show what would be deployed (no cloud connection)
./Deploy.ps1 -ConfigPath config.json -SkipAuth -WhatIf
```

## Prerequisites

- PowerShell 7+
- Python 3.12+ (for Foundry agent SDK script)
- Azure Bicep CLI (`az bicep install`)
- Microsoft 365 E5 or E5 Compliance add-on
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
- Required Entra roles: Compliance Administrator, User Administrator, eDiscovery Administrator

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

Foundry core resources are deployed to `eastus` by default (set via
`workloads.foundry.location` in `config.json`). Other regions may hit
capacity limits or project-RP issues.

### Publishing agents to Teams / Microsoft 365 Copilot

The Teams catalog publish step (`Publish-TeamsApps`) requires an existing
`Microsoft.Graph` context with the `AppCatalog.ReadWrite.All` scope. In
`-FoundryOnly` mode the deploy does not connect Graph itself, so either:

- **Pre-connect Graph** then run the FoundryOnly deploy in the same session:
  ```powershell
  Connect-MgGraph -Scopes 'AppCatalog.ReadWrite.All' -TenantId <tenantId> -NoWelcome
  ./Deploy.ps1 -ConfigPath config.json -FoundryOnly -TenantId <tenantId>
  ```
- **Or run a full deploy** (without `-FoundryOnly`) which connects Graph
  as part of its auth step.

Reruns are idempotent — the Teams manifest uses a deterministic `id`
(MD5 of prefix + shortName) and a monotonic `version`
(`1.<mmdd>.<hhmmss>` UTC), so subsequent deploys update the existing
tenant app rather than creating duplicates.

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

## Security controls deployed

| Workload | Description |
|---|---|
| `foundry` | Azure AI Foundry account, project, model deployment, and agent definitions |
| `agentIdentity` | Managed identity and auto-derived RBAC assignments for agent principals |
| `testUsers` | User and group provisioning for scoped policy assignment |
| `sensitivityLabels` | Sensitivity label hierarchy with AI-tier sublabels and auto-label policies |
| `dlp` | DLP policies covering AI prompts (EnterpriseAI), labeled content (CopilotExperiences), and endpoint shadow AI |
| `retention` | Retention policy applied to AI interaction locations |
| `eDiscovery` | eDiscovery cases with custodians, hold queries, and search queries for AI governance |
| `communicationCompliance` | DSPM for AI — captures agent interactions for compliance review |
| `insiderRisk` | Insider risk policies targeting risky AI usage patterns |
| `conditionalAccess` | Conditional Access policies (MFA, risky sign-in block) for agent principals |
| `mdca` | Defender for Cloud Apps — session policies, activity alerts, OAuth app governance |
| `auditConfig` | Unified audit log searches scoped to AI interaction and DLP events |

## Architecture

Deployment order (dependency-driven):

The Foundry workload uses a three-layer architecture:
- **PowerShell + ARM REST** (`modules/FoundryInfra.psm1`) for Foundry account,
  model deployments, and project creation (direct ARM REST at
  `api-version=2026-01-15-preview`), plus Teams packaging and catalog publishing
- **Python SDK** (`scripts/*.py`) for agent CRUD, project connections,
  knowledge base / vector stores, and post-deploy evaluations
- **Bicep** (`infra/`) for eval infrastructure, Bot Services, and Defender posture

```
1. Foundry          — agents + Defender for Cloud posture
2. AgentIdentity    — managed identity RBAC (auto-derived from tools)
3. TestUsers        — groups needed for policy scoping
4. SensitivityLabels
5. DLP
6. Retention
7. EDiscovery
8. CommunicationCompliance
9. InsiderRisk
10. ConditionalAccess — MFA + risky sign-in block (report-only)
11. MDCA             — session monitoring + activity alerts + app governance
12. AuditConfig
```

Removal runs the exact reverse order. A deployment manifest (`manifests/`) captures all created resource IDs and is used for precise teardown.

## Troubleshooting

See [`docs/troubleshooting.md`](docs/troubleshooting.md) for a catalog of
errors encountered on MCAPS-governed tenants and the fixes for each.
Covers Foundry project RP quirks, connection API gotchas, Teams catalog
publish idempotency, and more.
