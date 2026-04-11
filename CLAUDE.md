# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Standalone AI agent security tool. Deploys Azure AI Foundry agents and wraps them with Microsoft Purview security controls (sensitivity labels, DLP, retention, eDiscovery, communication compliance, insider risk).

Single config file (`config.json`), modular by workload, deploy + teardown symmetry. Supports `-SkipFoundry` (Purview-only) and `-FoundryOnly` (Foundry-only) modes.

## Stack

- PowerShell 7+ (pwsh)
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

# Teardown (config-based)
./Remove.ps1 -ConfigPath config.json

# Teardown (manifest-based, precise resource IDs)
./Remove.ps1 -ConfigPath config.json -ManifestPath manifests/AISec_20260411-120000.json

# Lint (CI uses this — zero warnings required)
Invoke-ScriptAnalyzer -Path . -Recurse -Severity Warning -ExcludeRule PSAvoidUsingWriteHost,PSUseSingularNouns

# Run Pester tests
Invoke-Pester tests/ -Output Detailed
```

## Architecture

### Orchestration Flow

`Deploy.ps1` imports all `modules/*.psm1`, loads `config.json`, connects to EXO + Graph (+ Az for Foundry), then deploys workloads in dependency order. Each `Deploy-*` function returns manifest data (created resource IDs). Manifest is exported to `manifests/<prefix>_<timestamp>.json` (git-ignored).

`Remove.ps1` mirrors deploy with reversed workload order. Accepts optional `-ManifestPath` for precise teardown; without it, falls back to config + prefix-based lookup.

### Deployment Order (dependency-driven)

1. Foundry
2. TestUsers
3. SensitivityLabels
4. DLP
5. Retention
6. EDiscovery
7. CommunicationCompliance
8. InsiderRisk
9. ConditionalAccess
10. AuditConfig
11. AgentIdentity

Foundry deploys first so agents exist before Purview policies govern them. AgentIdentity deploys last so RBAC is assigned after all resources exist. Removal is the exact reverse.

### Module Contract

Every workload module in `modules/` exports:
- `Deploy-<Workload> -Config <hashtable> [-WhatIf]` — returns manifest data (array of resource IDs)
- `Remove-<Workload> -Config <hashtable> [-Manifest <hashtable>] [-WhatIf]` — uses manifest for precise removal, falls back to config + prefix

Exceptions: `Prerequisites.psm1` and `Logging.psm1` are utility modules (no Deploy/Remove).

### Config Structure

Single config at `config.json`. Required fields: `labName`, `prefix`, `domain`. Workloads are toggled via `"enabled": true/false` in the `workloads` object. Each workload section contains its resource definitions.

## Conventions

- All resources prefixed with `{config.prefix}-` for reliable teardown
- Idempotent: check existence before creating
- `-WhatIf` support on all deploy/remove functions
- Cloud defaults to `commercial`; reads from config `cloud` field
- Conditional Access policies deploy in report-only mode (non-blocking)
- Logs written to `logs/` (git-ignored)
- Manifests written to `manifests/` (git-ignored, contain tenant-specific IDs)
