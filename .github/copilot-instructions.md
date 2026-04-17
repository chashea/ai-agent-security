# Copilot Instructions — ai-agent-security

Repo-specific guidance for GitHub Copilot. Inherits from the user's global
`~/CLAUDE.md`; this file overrides anything that conflicts. See also
[`CLAUDE.md`](../CLAUDE.md) and [`AGENTS.md`](../AGENTS.md) for the longer
architecture deep-dive — those are the source of truth, this is the short
operational primer.

## What this repo is

Standalone Azure AI Foundry security lab. `./Deploy.ps1 -ConfigPath config.json`
must work end-to-end on a fresh clone — that is the user's primary
constraint. Everything below exists to keep the deploy reproducible.

The deploy stands up:

- 7 Foundry agents (HR, Finance, IT, Sales, Kusto, Entra, Defender)
- A shared Azure AI Search index (`aisec-compliance-index`, hybrid +
  semantic, `agent_scope` filter) populated from `scripts/demo_docs/`
- Per-agent file_search vector stores
- Sensitivity labels with AI Search MI enforcement
- Custom RAI guardrails + jailbreak / PII blocklists
- Conditional Access (report-only), Defender for Cloud Apps session
  policies, Defender for Cloud posture
- Post-deploy evaluations + AI red teaming (Steps 7 & 8)

## Stack

- **PowerShell 7+** orchestration in `modules/*.psm1`
- **Python 3.12** for Foundry SDK work in `scripts/*.py` (system `python3`
  is 3.9, **always** invoke as `python3.12` explicitly)
- **Bicep** in `infra/` for eval infra, Bot Services, Defender posture
- **ARM REST** (PowerShell) for Foundry account / project — Bicep's
  `accounts/projects` type 500s on MCAPS tenants

## Three-layer Foundry architecture

```
PowerShell (modules/)         Python SDK (scripts/)              Bicep (infra/)
─────────────────────         ─────────────────────              ──────────────
FoundryInfra.psm1             foundry_tools.py                   foundry-eval-infra.bicep
 ARM REST: RG, account,        Project connections,               AI Search (AAD+key, semantic),
 model, project, eval-infra    tool definition builder            App Insights, Log Analytics
 Bicep, Search RBAC grants    foundry_knowledge.py               bot-services.bicep
 Teams packages, Bot          Demo doc upload, vector stores     bot-per-agent.bicep
 Services, Teams catalog      foundry_search_index.py            defender-posture.bicep
                               AI Search index lifecycle +        guardrails.bicep
                               doc upload with embeddings
                              foundry_agents.py
                               Agent CRUD + app publishing
                              foundry_evals.py
                               Prompt opt + custom evaluators
                              foundry_redteam.py
                               PyRIT-backed red team scans
```

`modules/Foundry.psm1` is a thin orchestrator. The deploy order inside
`Deploy-Foundry` is:

1. Bicep eval infra (AI Search + App Insights + Log Analytics) +
   post-Bicep RBAC grants
2. Project connections via ARM control plane
3. Vector stores (`foundry_knowledge.py upload`)
3b. **AI Search index** (`foundry_search_index.py populate`) — creates
    `aisec-compliance-index`, uploads ~21 docs tagged with `agent_scope`
4. Tool definitions (`foundry_tools.py build-tools`)
5. Agents (`foundry_agents.py deploy` — DELETE-then-POST, no PATCH)
6. Teams packages + Bot Services + Teams catalog publish
7. Evaluations pipeline
8. AI Red Teaming

`Remove-Foundry` mirrors this in reverse — every create has a paired
removal step.

## Build, lint, test commands

```bash
# Full deploy / teardown
./Deploy.ps1 -ConfigPath config.json
./Remove.ps1 -ConfigPath config.json

# Foundry-only / labels-only
./Deploy.ps1 -ConfigPath config.json -FoundryOnly
./Deploy.ps1 -ConfigPath config.json -SkipFoundry

# Dry run
./Deploy.ps1 -ConfigPath config.json -SkipAuth -WhatIf

# Lint (zero warnings required — matches CI)
Invoke-ScriptAnalyzer -Path . -Recurse -Severity Warning \
  -ExcludeRule PSAvoidUsingWriteHost,PSUseSingularNouns,PSUseBOMForUnicodeEncodedFile
python3.12 -m ruff check scripts/

# Tests
Invoke-Pester tests/ -Output Detailed
python3.12 -m pytest scripts/tests/ -v

# Bicep validation
az bicep build --file infra/foundry-eval-infra.bicep
az bicep build --file infra/bot-services.bicep
az bicep build --file infra/bot-per-agent.bicep
az bicep build --file infra/defender-posture.bicep
az bicep build --file infra/guardrails.bicep
```

CI (`.github/workflows/validate.yml`) runs six jobs: `lint`, `test`,
`smoke-test`, `python-lint`, `python-test`, `bicep-validate`. All six
must be green before a PR merges.

### Python test conventions

- Tests live in `scripts/tests/` and run with `python3.12 -m pytest`.
- Repo root has `conftest.py` adding the repo root to `sys.path`, and
  `scripts/__init__.py` makes `scripts` importable as a package — both
  are required for the `from scripts import …` style used in newer tests.
- Mock external HTTP calls (Foundry, Azure Search, embeddings). Don't
  let tests escape to the network — CI doesn't have credentials.

## Deploy-flow rules (do not break these)

1. **Idempotent everything.** Vector stores dedupe by name. Blocklists
   GET-then-PUT. Search index is `mergeOrUpload` on stable doc IDs.
   Agents are DELETE-then-POST (no PATCH endpoint). Reruns of
   `Deploy.ps1` must be safe.
2. **Every tool an agent declares must have backing infra in the deploy.**
   Adding `tools[].type = "foo"` in `config.json` without a corresponding
   create-step in `foundry_tools.py` build_tools + a backing resource
   step earlier in `Foundry.psm1` produces a silent zero-result tool.
   See `tasks/lessons.md` ("Declared agent tools must point at
   infrastructure that the deploy actually creates").
3. **Every create has a Remove counterpart.** `Remove-Foundry` is
   structured as parallel cleanup paths — when adding a new step to
   `Deploy-Foundry`, add the matching teardown to `Remove-Foundry`
   in the same PR.
4. **Resource naming uses the config prefix.** All resource names are
   `{config.prefix}-…` so prefix-based teardown works without a manifest.
5. **Manual Azure changes don't count.** If you bootstrap something
   live (RBAC, an index, a connection), back-port it into the deploy
   modules in the same PR — a fresh clone must reproduce the state.

## Lint / formatting

- **PowerShell:** PSScriptAnalyzer Warning severity, exclusions
  `PSAvoidUsingWriteHost,PSUseSingularNouns,PSUseBOMForUnicodeEncodedFile`.
  Use `Write-LabLog` from `modules/Logging.psm1` (not `Write-Host`),
  but `Write-Host` is allowed because the rule is excluded.
- **Python:** `ruff` only. No `black`, no `mypy` in this repo. Pre-commit
  hook runs ruff on staged `scripts/**/*.py` — install via
  `./scripts/install-hooks.sh`. Bypass only when explicitly asked
  (`git commit --no-verify`).
- **Bicep:** Must build cleanly with `az bicep build`. No linter beyond
  the compiler.

## Foundry / Azure quirks (the long tail)

These have all bitten the deploy at least once. The full catalog with
fix recipes is in [`docs/troubleshooting.md`](../docs/troubleshooting.md);
this list is just the gotchas to keep in mind while writing code.

- **MCAPS tenant policy exemption** is required for the target RG.
  Foundry needs `disableLocalAuth: false`; the policy default is `true`.
- **Foundry project ARM API:** use `2026-01-15-preview`, PUT body must
  include `kind: "AIServices"`, `identity.type: "SystemAssigned"`,
  and `properties.displayName`.
- **Project connections are ARM, not data-plane.** `PUT /connections`
  on the project endpoint returns 405. Use
  `Microsoft.CognitiveServices/accounts/projects/connections` instead.
- **Tool schema variations.** `function` tools use a flat shape
  (`{type, name, description, parameters}`) — NOT the OpenAI
  Chat-Completions nested shape. `connected_agent` uses the nested
  `{type, connected_agent: {...}}` shape. The nested-property key
  must match the `type` value exactly.
- **`a2a_preview`** is currently disabled in `foundry_tools.py` — preview
  API rejects every shape attempted. Config can still reference it;
  the builder log-skips.
- **`-Depth 20`** on `ConvertTo-Json` in `Invoke-FoundryPython` is
  load-bearing. The default depth-2 truncates `openapi.config.paths`
  to literal `@{...}` strings that Foundry silently accepts and
  produces a broken tool.
- **Python `DefaultAzureCredential` follows `az`, not `Az`.** PowerShell
  `Connect-AzAccount` and `az login` keep separate contexts. `az account
  set --subscription <id>` must point at the target sub before the
  deploy runs.
- **AI Search needs AAD + RBAC.** Bicep enables `aadOrApiKey`. Deploy
  grants the signed-in user `Search Service Contributor` and `Search
  Index Data Contributor` post-Bicep. Without those, the search index
  populator 403s.
- **Embeddings throttle on small TPM quotas.** Expect 429 backoff for
  ~5-10 minutes when hydrating the search index on a fresh project.
  The retry budget absorbs it.
- **Teams catalog publish is idempotent** via deterministic
  `manifest.id` (`MD5(prefix/shortName)` as a GUID) +
  monotonic `version` (`1.<mmdd>.<hhmmss>` UTC).
- **Per-user Teams app install via Graph 403s under MCAPS.** Catalog
  publish is automated; user assignment is manual via M365 admin
  center → Integrated apps. See
  [`docs/post-deploy-steps.md`](../docs/post-deploy-steps.md).

## When something fails

1. **Read the symptom in `docs/troubleshooting.md`** first — most
   recurring failures are catalogued there with the exact fix.
2. **Use the `foundry-troubleshooter` subagent** (`.claude/agents/`,
   `.github/copilot/skills/`) — it auto-maps deploy errors to
   `docs/troubleshooting.md` entries.
3. **Use the `foundry-verifier` subagent** to read-only check that
   deployed agent tool definitions match `config.json` after a
   suspect deploy.
4. **Check the live state before assuming code is broken.** `az resource
   show`, `az search service show`, the curls in
   `docs/post-deploy-steps.md#verification`. The Azure MCP server
   (`.github/copilot/mcp.json`) wraps these for inline use.

## After fixing anything

1. Update `docs/troubleshooting.md` with the symptom + root cause + fix
   if the failure recurred or could recur on a fresh deploy.
2. Update `tasks/lessons.md` with the pattern if the user corrected an
   approach (per the user's global `~/CLAUDE.md` rule).
3. Update [`README.md`](../README.md) if the user-facing flow changed
   (new workload, new prereq, new manual step).
4. Update [`CLAUDE.md`](../CLAUDE.md) and [`AGENTS.md`](../AGENTS.md)
   if architecture / commands / conventions changed.
5. Run the full lint + test pass before committing
   (`PSScriptAnalyzer`, `ruff`, `pytest`, `Invoke-Pester`,
   `az bicep build`).

## Things to never do

- Don't fabricate scores or red-team metrics — surface only what the
  Foundry / evals / red-team APIs actually return.
- Don't add docstrings, comments, or type annotations to code outside
  the function you're touching (per global `~/CLAUDE.md`).
- Don't store secrets in `config.json`, env vars, or commits — auth is
  interactive `az login` locally and OIDC in CI.
- Don't lower `ConvertTo-Json -Depth` below 20 in `Invoke-FoundryPython`.
- Don't change agent tool list in `config.json` without verifying every
  tool resolves to backing infra the deploy actually creates.
- Don't skip `--no-verify` / pre-commit hooks unless the user
  explicitly says so.
