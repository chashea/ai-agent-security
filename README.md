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
- **Conditional Access** — Policies for agent principals (coming soon)
- **Agent identity** — Managed identity and RBAC for agents (coming soon)

## Deployment modes

```powershell
# Full deployment: Foundry agents + all Purview security controls
./Deploy-AISecurity.ps1 -ConfigPath config.json

# Security-only: Purview controls without Foundry deployment
./Deploy-AISecurity.ps1 -ConfigPath config.json -SkipFoundry

# Foundry-only: Deploy agents without Purview controls
./Deploy-AISecurity.ps1 -ConfigPath config.json -FoundryOnly

# Dry run: validate config and show what would be deployed (no cloud connection)
./Deploy-AISecurity.ps1 -ConfigPath config.json -SkipAuth -WhatIf
```

## Prerequisites

- PowerShell 7+
- Microsoft 365 E5 or E5 Compliance add-on
- Azure subscription (required for Foundry deployment)
- Required PowerShell modules:
  - `ExchangeOnlineManagement` >= 3.0
  - `Microsoft.Graph` (Users, Groups, Authentication)
  - `Az.Accounts`
  - `PSScriptAnalyzer` (CI/lint only)
  - `Pester` >= 5.0 (tests only)
- Required Entra roles: Compliance Administrator, User Administrator, eDiscovery Administrator

## Quick start

```powershell
git clone https://github.com/chashea/ai-agent-security.git
cd ai-agent-security

# Edit config.json with your tenant domain, subscription, and agent definitions
# Then deploy:
./Deploy-AISecurity.ps1 -ConfigPath config.json

# Teardown:
./Remove-AISecurity.ps1 -ConfigPath config.json
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
| `agentIdentity` | Managed identity and RBAC assignments for agent principals (coming soon) |
| `testUsers` | User and group provisioning for scoped policy assignment |
| `sensitivityLabels` | Sensitivity label hierarchy with AI-tier sublabels and auto-label policies |
| `dlp` | DLP policies covering AI prompts (EnterpriseAI), labeled content (CopilotExperiences), and endpoint shadow AI |
| `retention` | Retention policy applied to AI interaction locations |
| `eDiscovery` | eDiscovery cases with custodians, hold queries, and search queries for AI governance |
| `communicationCompliance` | DSPM for AI — captures agent interactions for compliance review |
| `insiderRisk` | Insider risk policies targeting risky AI usage patterns |
| `conditionalAccess` | Conditional Access policies for agent principals (coming soon) |
| `auditConfig` | Unified audit log searches scoped to AI interaction and DLP events |

## Architecture

Deployment order (dependency-driven):

```
1. Foundry          — agents must exist before policies govern them
2. TestUsers        — groups needed for policy scoping
3. SensitivityLabels
4. DLP
5. Retention
6. EDiscovery
7. CommunicationCompliance
8. InsiderRisk
9. ConditionalAccess
10. AuditConfig
11. AgentIdentity   — RBAC assigned after all resources exist
```

Removal runs the exact reverse order. A deployment manifest (`manifests/`) captures all created resource IDs and is used for precise teardown.
