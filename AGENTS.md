# AGENTS.md

AI agent guidance for working in this repository.

## Project Overview

Standalone AI agent security tool. Deploys Azure AI Foundry agents and wraps them with Microsoft Purview security controls (sensitivity labels, DLP, retention, eDiscovery, communication compliance, insider risk).

Single config file (`config.json`), modular by workload, deploy + teardown symmetry.

## Stack

- PowerShell 7+ (pwsh)
- ExchangeOnlineManagement >= 3.0
- Microsoft.Graph SDK (Users, Groups, Authentication)
- Az.Accounts (for Foundry/Azure deployment)

## Commands

```powershell
# Full deploy
./Deploy-AISecurity.ps1 -ConfigPath config.json

# Security-only (skip Foundry)
./Deploy-AISecurity.ps1 -ConfigPath config.json -SkipFoundry

# Foundry-only
./Deploy-AISecurity.ps1 -ConfigPath config.json -FoundryOnly

# Dry run (no cloud connection)
./Deploy-AISecurity.ps1 -ConfigPath config.json -SkipAuth -WhatIf

# Teardown
./Remove-AISecurity.ps1 -ConfigPath config.json

# Teardown with manifest (precise)
./Remove-AISecurity.ps1 -ConfigPath config.json -ManifestPath manifests/AISec_20260411-120000.json

# Lint
Invoke-ScriptAnalyzer -Path . -Recurse -Severity Warning -ExcludeRule PSAvoidUsingWriteHost,PSUseSingularNouns

# Tests
Invoke-Pester tests/ -Output Detailed
```

## Architecture

### Config Loading

`Deploy-AISecurity.ps1` calls `Import-LabConfig -ConfigPath config.json` (from `modules/Prerequisites.psm1`). This validates required fields (`labName`, `prefix`, `domain`) and returns a PSCustomObject. The config object is passed into every workload function.

### Workload Invocation

Each workload is invoked only if `$config.workloads.<name>.enabled -eq $true`. Errors in one workload are isolated — they write to the log and set a failed-workloads list, but do not abort the remaining workloads unless it is a hard dependency (e.g., Foundry failure with `-FoundryOnly`).

### Error Isolation

Workload failures are caught per-workload. The orchestrator collects failures and reports a summary at the end. Use `Invoke-LabRetry` for transient Graph/EXO API calls.

## Deployment Order

1. Foundry — agents must exist before policies govern them
2. TestUsers — groups needed for policy scoping
3. SensitivityLabels
4. DLP
5. Retention
6. EDiscovery
7. CommunicationCompliance
8. InsiderRisk
9. ConditionalAccess
10. AuditConfig
11. AgentIdentity — RBAC assigned after all resources exist

Removal is the exact reverse order.

## Module Contract

Every workload module exports:
- `Deploy-<Workload> -Config <PSCustomObject> [-WhatIf]` — deploys resources, returns hashtable of created resource IDs
- `Remove-<Workload> -Config <PSCustomObject> [-Manifest <PSCustomObject>] [-WhatIf]` — removes resources; uses manifest IDs when provided, falls back to prefix-based lookup

Utility modules (`Prerequisites.psm1`, `Logging.psm1`) do not follow the Deploy/Remove pattern.

## Conventions

- All resources prefixed with `{config.prefix}-` for reliable teardown
- Idempotent: check existence before creating; skip silently if already present
- `-WhatIf` support on all deploy/remove functions — must not make any changes when set
- Manifests in `manifests/` are git-ignored; they contain tenant-specific resource GUIDs
- All Write-Host output should use `Write-LabLog` from `Logging.psm1` for structured output
- PSScriptAnalyzer must pass with zero warnings (excludes `PSAvoidUsingWriteHost`, `PSUseSingularNouns`)
