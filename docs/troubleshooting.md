# Troubleshooting

Common errors encountered during development on MCAPS-governed tenants, and
the resolutions that made each one go away. Entries link to the commit or
module that contains the fix.

## Foundry project creation returns HTTP 500

**Symptom.** Every PUT to
`Microsoft.CognitiveServices/accounts/<account>/projects/<proj>` returns
`InternalServerError`. The project resource is created but lands in `Failed`
state. Reproduces across ARM REST, Bicep, `azure-mgmt-cognitiveservices`, and
the Azure portal.

**Root cause.** Two overlapping issues:
1. The MCAPS `CognitiveServices_LocalAuth_Modify` policy forces the parent
   Foundry account to `disableLocalAuth: true`, which breaks the project
   capability host handshake.
2. The project PUT body needs `kind`, `identity`, and `displayName` — older
   API versions allowed them to be omitted, but `2026-01-15-preview` rejects
   an otherwise-correct body as a generic 500.

**Fix.** Create a policy exemption on the target resource group (see
[Tenant prerequisites](../README.md#tenant-prerequisites-mcaps-governed-tenants))
so `disableLocalAuth: false` sticks, and PUT with the full body:

```json
{
  "kind": "AIServices",
  "location": "eastus2",
  "identity": { "type": "SystemAssigned" },
  "properties": {
    "description": "...",
    "displayName": "aisec-project"
  }
}
```

See `Deploy-FoundryBicep` in `modules/FoundryInfra.psm1`.

## Project connection PUT returns HTTP 405 Method Not Allowed

**Symptom.** `PUT <projectEndpoint>/connections/<name>?api-version=...`
returns 405.

**Root cause.** Project connections are NOT a data-plane resource — they
live under the ARM control plane as
`Microsoft.CognitiveServices/accounts/<account>/projects/<proj>/connections/<name>`.

**Fix.** `scripts/foundry_tools.py create_connection()` hits the ARM URL.

## Blob Storage connection PUT returns HTTP 400

**Symptom.**
```
{"code":"ValidationError","message":"Required metadata property ContainerName
is missing;Required metadata property AccountName is missing"}
```

**Fix.** Pass `properties.metadata.ContainerName` and
`properties.metadata.AccountName` in the PUT body. See
`setup_connections()` → "Blob Storage connection" branch in
`scripts/foundry_tools.py`.

## Bing Search connection PUT returns HTTP 400

**Symptom.**
```
{"code":"UserError","message":"Error when parsing request; unable to
deserialize request body"}
```

**Root cause.** The Bing Search API has been retired
(aka.ms/BingAPIsRetirement). The `BingSearch` connection category no
longer accepts the old payload shape.

**Fix.** Skip the connection entirely. Foundry's built-in `bing_grounding`
tool uses the project's managed web search with no project connection
required. The tool builder emits the tool without a `project_connection_id`
field when no connection exists.

## Agent creation HTTP 400 — `function` tool missing `name`

**Symptom.**
```
required: Required properties ["name"] are not present
param: "/definition/tools/N"
```
where tool N is a `function` type.

**Root cause.** The current code emitted OpenAI Chat Completions format
`{type: "function", function: {name, description, parameters}}` but Foundry
prompt agents use a flat schema.

**Fix.** Emit
`{type: "function", name, description, parameters}` — `name` at the top level
of the tool object. See the `function` branch in `build_tool_definitions()`.

## Agent creation HTTP 400 — `sharepoint_grounding_preview` missing

**Symptom.**
```
required: Required properties ["sharepoint_grounding_preview"] are not present
```

**Root cause.** When the tool `type` is `sharepoint_grounding_preview`, the
nested property key must match the type name exactly
(`sharepoint_grounding_preview`), not `sharepoint_grounding`.

**Fix.** Rename the nested key. Same applies to `a2a_preview` and any other
`<name>_preview` tool types.

## Agent shows "missing configuration" for SharePoint grounding

**Symptom.** Agent creates successfully but Foundry portal flags the
`sharepoint_grounding_preview` tool as "missing configuration".

**Root cause.** We passed an empty `connection_id` because no SharePoint
project connection was configured.

**Fix.** Either:
- Set `workloads.foundry.connections.sharePoint.siteUrl` in `config.json` to
  a real SharePoint site URL — the deploy creates the project connection and
  wires it to the tool.
- Leave it empty — the tool builder skips the tool entirely with a warning.

## AgentIdentity role assignment query HTTP 400

**Symptom.**
```
The filter 'principalId eq '...' and roleDefinitionId eq '...' is not
supported. Supported filters are either 'atScope()' or
'principalId eq '{value}' or assignedTo('{value}').
```

**Root cause.** ARM role assignments API doesn't support compound filters.

**Fix.** Filter by `principalId` server-side and match `roleDefinitionId`
client-side. See `modules/AgentIdentity.psm1`.

## Custom evaluator creation HTTP 400 — unsupported api-version

**Symptom.**
```
Unsupported api-version 2025-05-15-preview. The supported api-versions are
v1, 2025-10-15-preview, 2025-11-15-preview.
```

**Fix.** Evaluation endpoints (`/evaluators`, `/evaluations`,
`/prompt-optimizations`, `/agents/{id}/continuous-evaluation`) use
`2025-11-15-preview`, distinct from the agents API version
(`2025-05-15-preview`). `Foundry.psm1` plumbs a separate `evalApiVersion`
into the Python eval pipeline.

## Evaluations endpoints return HTTP 404

**Symptom.** Every call under `/evaluations` and `/prompt-optimizations`
returns 404.

**Root cause.** The project tier doesn't have Standard Agent Setup — the
evaluation service is not provisioned on the project.

**Fix.** `foundry_evals.py` probes the endpoint once at pipeline start and
skips the entire pipeline with a single warning if it returns 404. No
cascading per-agent failures.

## Teams catalog publish HTTP 403 Forbidden

**Symptom.** `POST /v1.0/appCatalogs/teamsApps/<id>/appDefinitions` returns
403 even when signed in as Global Administrator.

**Root cause.** The publish code matched existing tenant apps by
`displayName`. Agent short names (HR-Helpdesk, Finance-Analyst, IT-Support,
Sales-Research) collide with unrelated tenant apps owned by other
principals, so the code landed on the "update existing" path and was
rejected.

**Fix.** Match by the manifest's `externalId` (read from the package zip's
`manifest.json` id field), which is deterministic for our packages and can't
collide with unrelated apps. See `Publish-TeamsApps` in
`modules/FoundryInfra.psm1`.

## Teams catalog publish HTTP 409 Conflict

**Symptom.**
```
Update tenant app definition manifest version exists. AppId: '...',
exist app version: 1.0.0
```

**Root cause.** Manifest `version` was hardcoded to `1.0.0` — after the first
deploy the version already existed, so updates were rejected.

**Fix.** Encode the UTC timestamp as `1.<mmdd>.<hhmmss>` so every deploy
produces a fresh semver-valid version. See `New-FoundryAgentPackage` in
`modules/FoundryInfra.psm1`.

## Teams catalog has duplicate apps after multiple deploys

**Symptom.** Each deploy creates a new tenant Teams app instead of updating
the existing one; after N deploys the org catalog has N copies of each
agent.

**Root cause.** `New-FoundryAgentPackage` generated a fresh
`[System.Guid]::NewGuid()` for every package on every run. `Publish-TeamsApps`
matches on `externalId`, so the new GUID never matched any existing app and
always took the "create new" path.

**Fix.** Derive the manifest `id` from `MD5(prefix + "/" + shortName)`
rendered as a GUID — deterministic across runs, unique per agent.

## `Connect-MgGraph` hangs for 2 minutes then fails with "Authentication needed"

**Symptom.** The Teams catalog publish step hangs for ~120s and then writes
`Authentication needed. Please call Connect-MgGraph` per agent. Deploy
continues but publish is skipped.

**Root cause.** Earlier builds of `-FoundryOnly` mode skipped Graph at
startup and deferred the connect to `Publish-TeamsApps`, which fell back
to an interactive browser/broker flow and timed out in non-interactive
pwsh.

**Fix (v0.8).** `Deploy.ps1` now calls `Connect-LabServices` with
`-SkipGraph:$false -GraphScopes @('AppCatalog.ReadWrite.All')
-UseDeviceCode` when `-FoundryOnly` is set. Device code prints to stdout,
MSAL caches the refresh token, and the publish step finds the context
already wired up. If you need to pre-connect (e.g. to avoid the 120s
device-code prompt on every run), run once manually:

```powershell
pwsh -Command "Connect-MgGraph -Scopes 'AppCatalog.ReadWrite.All' -TenantId <tenantId> -NoWelcome"
```

Then `Deploy.ps1 -FoundryOnly` will silently reuse the cached context.

## Foundry data-plane calls return `Token tenant does not match resource tenant`

**Symptom.** Every POST/PUT to `*.services.ai.azure.com/api/projects/...`
returns `HTTP 401 InvalidAuthenticationTokenTenant` ("wrong issuer") or
`HTTP 400 Tenant provided in token does not match resource token`. Project
connection creation produces 0 connections, file uploads produce 0 files,
and downstream agent tools land with empty connection IDs.

**Root cause.** The Python scripts use
`azure.identity.DefaultAzureCredential`, which tries
`AzureCliCredential` after any SDK-native flows. If the `az` CLI default
subscription points at a different tenant from the one the Foundry
subscription lives in (common when the user is signed in to multiple
MCAPS/tenant accounts), Python gets a token for the wrong tenant. The
PowerShell-side `Connect-AzAccount` / `Set-AzContext` is a separate
context that has no effect on `az` CLI state.

**Fix.** Set the `az` CLI default subscription to match the Foundry
subscription **before** running `Deploy.ps1`:

```bash
az account set --subscription <subId>
az account show   # verify tenantId matches the Foundry tenant
```

Also worth doing if deploys fail intermittently on data-plane calls:
`az account list --query '[].{name:name, tenantId:tenantId, isDefault:isDefault}' -o table`.

## `ConvertTo-Json -Depth 10` truncates OpenAPI tool config to `@{...}`

**Symptom.** Foundry agents with an `openapi` tool come up with invalid
path specs: `parameters[].schema = "@{type=string}"` and
`requestBody.content.application/json = "@{schema=}"`. At runtime the
tool produces garbage or the agent can't use it.

**Root cause.** `Invoke-FoundryPython` in `modules/Foundry.psm1`
serialized the PowerShell-side `$InputData` with `ConvertTo-Json -Depth 10`.
OpenAPI path objects are 10+ levels deep when wrapped inside
`{agents[].tools[].config.paths.<route>.<verb>.requestBody.content.application/json.schema.properties.<field>}`
— anything below level 10 gets emitted as a `System.Collections.Hashtable`
`.ToString()`, which renders as the PowerShell literal `@{key=value}`.
Python reads that as a plain string and posts it to Foundry, which
accepts it without schema validation.

**Fix (v0.8).** `Invoke-FoundryPython` now uses `-Depth 20` by default.
If you add a new Python-bridge action with even deeper input, bump
again — do not lower. PSScriptAnalyzer and the smoke test do not catch
this (both serialize small inputs).

## Agent tool update silently ignored on rerun — stale tools persist

**Symptom.** You change an agent's tool list in `config.json`, rerun
`Deploy.ps1`, and the live agent still has the old tools. `foundry_tools.py
build-tools` reports "Built tool definitions for N agent(s)" but the
Foundry portal shows the old set.

**Root cause.** `foundry_agents.py create_agent` used to return early on
HTTP 200 from the existence check (`Agent already exists: X`). Foundry
prompt agents do not expose a PATCH endpoint, so "already exists" meant
"nothing we can do" — but the function then returned the stub manifest
without propagating the staleness as a warning.

**Fix (v0.8).** `create_agent` now DELETEs the existing agent before
POSTing the new definition. Tools, instructions, and `applicationName`
metadata all refresh on every run. The trade-off: if the POST fails
(e.g. invalid tool payload), the agent is gone until the next
successful deploy. Treat tool-builder errors as hard failures — they
are no longer tolerated.

## Deploy finishes but the Foundry portal shows "no agents"

**Symptom.** You finish a clean-looking deploy, open the Foundry portal,
and the Agents pane is empty. The account, project, and connections are
visible but there are no agents to select.

**Root cause (usually).** You are signed in to the portal as a different
tenant / user than the one the deploy ran under. Symptom: you see a
different account selector in the top-right or the browser shows the
wrong "contoso" breadcrumb.

**Fix.** Confirm the correct tenant in the portal avatar menu and
navigate directly via the project URL:

```
https://ai.azure.com/build/agents?wsid=/subscriptions/<subId>/resourceGroups/<rg>/providers/Microsoft.CognitiveServices/accounts/<account>/projects/<project>&tid=<tenantId>
```

Also useful — list via the API to confirm the agents exist server-side:

```bash
TOKEN=$(az account get-access-token --resource https://ai.azure.com --query accessToken -o tsv)
curl -s -H "Authorization: Bearer $TOKEN" \
  "https://<account>.services.ai.azure.com/api/projects/<project>/agents?api-version=2025-05-15-preview" \
  | jq '.data[].name'
```

## `bing_grounding` rejected with "required: Required properties ['project_connection_id']"

**Symptom.** Agent creation fails with HTTP 400
`/definition/tools/<n>/bing_grounding/search_configurations/0` missing
`project_connection_id`.

**Root cause.** The preview API now requires every
`search_configurations[]` entry to carry `project_connection_id`. Earlier
builds accepted empty strings or missing fields — the
`CLAUDE.md`-documented "managed web search, no connection required"
shortcut is no longer valid.

**Fix (v0.8).** `foundry_tools.py build_tool_definitions` skips
`bing_grounding` entirely (with a warning) if
`connections.bingSearch` is not configured. Provision a `Grounding with
Bing Search` resource and wire it up via
`workloads.foundry.connections.bingSearch` to get web grounding back.

## `a2a_preview` rejected with "At least one of base_url or project_connection_id must be specified"

**Symptom (historical, pre-v0.9.0).** Agents that request the `a2a` tool
fail with HTTP 400 `At least one of base_url or project_connection_id
must be specified for A2A tools` at `definition.tools[n]`.

**Root cause.** Earlier `a2a_preview` schema experiments (per-peer
`{name, base_url}`, tool-level `{base_url}`, nested
`{a2a_preview: {agents: [...]}}`) were rejected by the preview API.

**Resolution (v0.9.0+).** The canonical shape is a flat
`project_connection_id` pointing at a project connection of category
`Agent2Agent`:

```json
{"type": "a2a_preview", "project_connection_id": "<connection-id>"}
```

`setup_connections()` in `foundry_tools.py` auto-provisions the
Agent2Agent connection when `workloads.foundry.connections.a2a` is
present in config. If the connection is missing, the builder skips
the tool with a warning rather than emitting an invalid payload.

If you still hit HTTP 400s on the preview API, confirm the project
connection exists (`az rest --method GET --uri "$(az account show --query id -o tsv | xargs -I{} echo /subscriptions/{})/resourceGroups/<rg>/providers/Microsoft.CognitiveServices/accounts/<acct>/projects/<proj>/connections/<a2a-name>?api-version=2026-01-15-preview"`) and that its `category` is `Agent2Agent`.

## `Az.Accounts` interactive auth blocks headless runs

**Symptom.** `Connect-AzAccount` opens a browser popup from within
`Deploy.ps1`; when run from a non-interactive context it waits forever on
the "Please select the account" prompt.

**Fix.** Run `az login` and/or `Connect-AzAccount` interactively in a
separate session before kicking off `Deploy.ps1`. The deploy reuses the
cached token via `Set-AzContext`.

## Recovering from partial deployments

`Deploy.ps1` has no rollback logic. If a workload fails mid-deploy,
earlier workloads remain deployed and later ones are missing. The
deployment order is:

1. **Foundry** — agents + Defender posture
2. **AgentIdentity** — RBAC
3. **AIGateway** — APIM v2 + TPM limits
4. **TestUsers** — groups
5. **ConditionalAccess** — report-only
6. **MDCA** — session policies

### Identifying what was deployed

Check the manifest in `manifests/` — it captures resource IDs for each
workload that completed. If no manifest exists (deploy crashed before
export), check each workload manually via the Azure portal or CLI.

### Re-running specific workloads

All Deploy functions are idempotent (they check existence before
creating), so re-running is always safe.

| Goal | Command |
|------|---------|
| Re-deploy only Foundry | `Deploy.ps1 -FoundryOnly` |
| Re-deploy everything except Foundry | `Deploy.ps1 -SkipFoundry` |
| Skip individual workloads | Set `workloads.<name>.enabled = false` in `config.json` for each workload to skip, then run `Deploy.ps1` |

### When to use `Remove.ps1` vs. re-run

- **Repair an existing deployment:** just re-run `Deploy.ps1`. Idempotent
  functions skip resources that already exist and create anything missing.
- **Start fresh:** `Remove.ps1 -ManifestPath <path>` to tear down, then
  `Deploy.ps1` to rebuild.
- **Prefix changed between runs:** old resources won't be found by prefix
  lookup — use manifest-based removal (`Remove.ps1 -ManifestPath <path>`)
  to clean up the old-prefix resources before re-deploying.

### Common partial failure scenarios

**Foundry fails.**
No agents exist, but no other workloads are affected. Fix the Foundry
config and re-run with `-FoundryOnly`.

**MDCA fails.**
Everything else is deployed. Re-run the full deploy; MDCA will skip
existing resources and only create what's missing.

**ConditionalAccess fails.**
Agents, RBAC, groups, and labels are in place but CA policies are absent.
Re-run the full deploy — ConditionalAccess picks up where it left off.

## `azure_ai_search` tool returns zero results in the agent UX

**Symptom.** An agent that declares `azure_ai_search` in `config.json`
(e.g., HR-Helpdesk) responds with "I couldn't find any information"
to questions that demo docs in `scripts/demo_docs/` clearly answer.
Foundry surfaces no error — the tool just returns an empty result set.

**Root cause (most common).** The index referenced by the tool
(`aisec-compliance-index`) does not exist on the search service, or
exists but is empty. Until commit `a1b2af1`, the deploy created the
search **service** via Bicep but never created or populated the
**index** — a real silent-failure gap.

**Fix.** Run a fresh deploy on `main` or later. `Deploy-Foundry`
Step 3b (`Initialize-FoundrySearchIndex` in `modules/Foundry.psm1`)
calls `python3.12 scripts/foundry_search_index.py --action populate`
which creates the index with hybrid + semantic config and uploads
the demo corpus tagged with an `agent_scope` filterable field.

**Verify.** Use the facet curl in
[`docs/post-deploy-steps.md#verification`](post-deploy-steps.md#verification).
Expect a count of 12 documents (3 per agent_scope × 4 agent_scopes: HR-Helpdesk, Finance-Analyst, IT-Support, Sales-Research).

## AI Search index population fails with HTTP 403 Forbidden

**Symptom.** `foundry_search_index.py` exits non-zero with
`403 Forbidden` on `PUT /indexes/aisec-compliance-index` or
`POST /docs/index`.

**Root cause.** The deploying identity is missing `Search Service
Contributor` (create/update index) or `Search Index Data Contributor`
(upload docs) on the search service.

**Fix.** `Deploy-FoundryBicep` grants both roles to the signed-in user
right after the eval-infra Bicep deploys. If you ran an old version
of the deploy or the role assignment failed, grant manually:

```bash
USER_ID=$(az ad signed-in-user show --query id -o tsv)
SEARCH_ID=$(az search service show -n aisec-search-eastus -g rg-ai-agent-security --query id -o tsv)
az role assignment create --assignee-object-id $USER_ID --assignee-principal-type User \
  --role "Search Service Contributor"     --scope $SEARCH_ID
az role assignment create --assignee-object-id $USER_ID --assignee-principal-type User \
  --role "Search Index Data Contributor"  --scope $SEARCH_ID
```

Wait ~30s for AAD eventual consistency, then re-run the deploy.

## AI Search index population stalls on embedding 429s

**Symptom.** `foundry_search_index.py` logs many
`429 Too Many Requests` retries on the embeddings endpoint
(`text-embedding-3-small`). The script eventually succeeds but
takes 5-10 minutes for ~20 docs.

**Root cause.** New Foundry accounts get a low default TPM quota
(~1K) on `text-embedding-3-small`. The retry loop with exponential
backoff (8 attempts) absorbs the throttling, but the wait is
visible in deploy logs.

**Fix (optional).** Foundry portal → Models + endpoints →
`text-embedding-3-small` → Edit → raise TPM. Not required for
correctness — the populator is idempotent (`mergeOrUpload` on
stable doc IDs) and can be re-run safely.

## AI Search service rejects bearer token with HTTP 401

**Symptom.** `foundry_search_index.py` fails with
`401 Unauthorized` on the very first request, before any 429s.

**Root cause.** The search service has `authOptions.aadOrApiKey`
disabled (key-only auth). The Bicep in
`infra/foundry-eval-infra.bicep` enables `aadOrApiKey` with
`http401WithBearerChallenge` — older Bicep deploys may have left
the service in key-only mode.

**Fix.**

```bash
az search service update -n aisec-search-eastus -g rg-ai-agent-security \
  --aad-auth-failure-mode http401 --auth-options aadOrApiKey
```

Then re-run the deploy (or just `python3.12 scripts/foundry_search_index.py --action populate`).

## Foundry portal "Knowledge → Foundry IQ Knowledge bases" tab is empty

**Symptom.** After a successful deploy, navigating to the Foundry
portal → your project → **Knowledge** → **Foundry IQ Knowledge bases**
shows "No knowledge bases" / empty state.

**Root cause.** This is **expected**. Foundry IQ Knowledge Bases are
a separate, newer (Ignite 2025) agentic-retrieval abstraction that
wraps Azure AI Search indexes + project connections + reasoning. The
lab does not create one automatically because the public REST API
surface for Foundry IQ KBs is not yet exposed on the Standard Agent
Setup project tier — every probe across `knowledgeBases`,
`knowledgeSources`, `kb`, etc. and every preview api-version returns
HTTP 400 (`API version not supported`) or 404.

**What you should see populated.**

- **Agents → `<agent>` → Tools → file_search** — 4 vector stores named
  `AISec-<agent>-knowledge` (HR-Helpdesk, Finance-Analyst, IT-Support,
  Sales-Research). Security-Triage declares no `file_search` tool.
- **Knowledge → Indexes / Vector stores** — the same 4 stores
  surfaced as `ManagedAzureSearch` indexes.
- **Connected resources → Azure AI Search** — one connection
  `AISec-ai-search`.
- **Azure portal → AI Search → `aisec-search-eastus` → Indexes** —
  one index `aisec-compliance-index` with 12 docs.

**Fix (optional).** If you want the Foundry IQ tab populated for a
demo, follow the manual portal flow in
[`docs/post-deploy-steps.md`](post-deploy-steps.md#optional-create-a-foundry-iq-knowledge-base-manually).
The lab agents will continue to function without this — they reach
the same docs through the `file_search` and `azure_ai_search` tools.

**When this stops being a manual step.** Once Microsoft ships a
public REST API for Foundry IQ KBs, add a `scripts/foundry_iq.py`
that mirrors the structure of `foundry_search_index.py` and wire it
into `Deploy-Foundry` between Step 3b (search index population) and
Step 4 (tool definition build).
