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
  "location": "eastus",
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

**Root cause.** `-FoundryOnly` mode deliberately does not connect Graph at
startup. `Publish-TeamsApps` was calling `Connect-MgGraph` itself which
fell back to device code flow and timed out in non-interactive contexts.

**Fix.** `Publish-TeamsApps` now checks for an existing `MgContext` with
`AppCatalog.ReadWrite.All` at the top of the function. If missing, it
returns immediately with a single warning telling you to either pre-connect
Graph or run a full deploy.

## `Az.Accounts` interactive auth blocks headless runs

**Symptom.** `Connect-AzAccount` opens a browser popup from within
`Deploy.ps1`; when run from a non-interactive context it waits forever on
the "Please select the account" prompt.

**Fix.** Run `az login` and/or `Connect-AzAccount` interactively in a
separate session before kicking off `Deploy.ps1`. The deploy reuses the
cached token via `Set-AzContext`.
