# Post-deploy manual steps

`Deploy.ps1` gets you most of the way, but a handful of steps still need
human intervention because they either (a) require tenant admin approval,
(b) depend on resources the repo does not provision, or (c) are blocked
by MCAPS governance policies that cannot be bypassed automatically. Work
through this checklist after every clean deploy; most items are one-time
per lab tenant.

## Status at a glance (current as of v0.20.0)

| # | Item | Status |
|---|---|---|
| 1 | Approve Agent 365 digital-worker submissions | `Manual — tenant admin, no API` |
| 2 | Deploy Teams apps to users | `Manual — MCAPS blocks automated path` |
| 3 | Defender for Cloud "Data security for AI interactions" | `Automated — infra/defender-posture.bicep` |
| 3a | Foundry guardrail-baseline initiative | `Automated — see workflow note` |
| 4 | Populate `connections.sharePoint.siteUrl` | `Manual — external resource` |
| 5 | Provision Bing Grounding | `Automated — bingSearch.provision=true` |
| 6 | Pre-connect Graph for silent reruns | `Optional convenience — Deploy.ps1 handles` |
| 7 | Fire adversarial traffic | `Automated — Deploy.ps1 -AdversarialTraffic` |

## 1. Approve Agent 365 digital-worker submissions

**When.** After `workloads.foundry.agent365.enabled = true` and a deploy
that calls `Publish-FoundryAgentsAsDigitalWorkers`. Each submission lands
in the M365 admin center "Agents" request queue with `status: requested`
until a tenant admin approves it.

**Where.** <https://admin.cloud.microsoft/?#/agents/all/requested>

**What to do.** Open each pending agent → review → Approve. The admin
center routes the agent into Teams + Copilot and adds it to the deployed
Agents pane. You'll see one entry per agent published by the deploy (4
business-function agents in the default config: HR-Helpdesk,
Finance-Analyst, IT-Support, Sales-Research). Security-Triage is
deployed as a Foundry agent but is not published via Agent 365 — it's
intended for direct API access by SOC tooling, not end-user Teams.

**Why this is manual.** Agent 365 publishing is a submission, not an
install — the Frontier preview requires admin review before agents become
visible to end users.

**If the queue is empty.** Publish didn't land. Either `agent365.enabled`
is still `false` in `config.json`, the bot `appClientId` isn't available
in the deploy manifest (see `modules/Agent365.psm1
Publish-FoundryAgentsAsDigitalWorkers` — it reads from
`$FoundryManifest.botServices.bots[].appClientId`), or Bot Services
deployment was skipped. Rerun with verbose logging or use
`/tmp/publish_agent365.ps1`-style one-shot that synthesizes the manifest
from known bot app IDs.

## 2. Deploy Teams apps to users

**When.** After every deploy that updates the `packages/foundry/*.zip`
files and successfully pushes new definitions to the org Teams catalog
(`Publish-TeamsApps` / the `/tmp/deploy_teams_apps.ps1` helper in this
repo's history). `publishingState=published` in the catalog does **not**
mean users can see the app — it just means the definition is uploaded.

**Where.** Microsoft 365 admin center → Settings → Integrated apps →
find each app (HR-Helpdesk, Finance-Analyst, IT-Support, Sales-Research,
Security-Triage) → **Deploy**.

**What to do.** For each app, click Deploy → assign to a user group (or
"Entire organization") → Next → Accept permissions → Finish. This is the
step that puts the app into users' Teams sidebar / M365 app launcher.

**Why this is manual.** MCAPS-governed tenants block the automated path
`POST /users/{id}/teamwork/installedApps` with HTTP 403 (tenant Teams
app permission policy). The `TeamsAppInstallation.ReadWriteSelfForUser`
scope is granted but the install itself is rejected. The deploy's Graph
publish call works, the user-assign call does not.

**Alternative (per-user sideload).** If Integrated Apps is also
policy-locked for you, open the Teams client → Apps → Manage your apps →
Upload a custom app → pick each `.zip` from `packages/foundry/`. Only
installs for your account.

## 3. Enable Defender for Cloud "Data security for AI interactions"

**Status: AUTOMATED (v0.9.0+).** `infra/defender-posture.bicep` now includes
a `Microsoft.Security/pricings@2024-01-01` resource named `AI` with
`pricingTier: Standard` and the three required extensions
(`AIModelScanner`, `AIPromptEvidence`, `AIPromptSharingWithPurview`). The
Foundry workload deploys this Bicep at subscription scope, so the toggle
is flipped as part of every deploy.

**Verify:**
```bash
az rest --method GET \
  --uri "https://management.azure.com/subscriptions/<subId>/providers/Microsoft.Security/pricings/AI?api-version=2024-01-01"
# Expect: pricingTier: Standard, resourcesCoverageStatus: FullyCovered
# Expect: extensions list includes AIModelScanner, AIPromptEvidence, AIPromptSharingWithPurview
```

**Propagation delay.** Expect 4–24 hours before Foundry agents show up
under Defender portal → AI security → Agents. The Bicep resource applies
the plan immediately, but indexing of existing Cognitive Services accounts
is async.

**To disable (e.g. cost testing):** set `enableAIDefender: false` in the
Bicep parameters, or override at deploy time.

### 3a. (Optional) Deploy the Foundry Control Plane guardrail-baseline initiative

**When.** After the Foundry workload is deployed and you want Azure Policy
to *enforce* that every model deployment ships with the full guardrail
stack — catching the case where someone creates a rogue deployment that
skips the RAI policy or weakens a filter. Mirrors the portal flow at
[Create a guardrail policy](https://learn.microsoft.com/en-us/azure/foundry/control-plane/quickstart-create-guardrail-policy),
but as code.

**What it does.** `infra/foundry-guardrail-policies.bicep` creates 12
custom policy definitions + 1 initiative + 1 subscription-scope
assignment. The controls:

| # | Definition | Target | Enforces |
|---|---|---|---|
| 1 | `require-raipolicy-on-deployment` | `accounts/deployments` | `raiPolicyName` must be set |
| 2 | `require-defaultv2-base` | `accounts/raiPolicies` | `basePolicyName == Microsoft.DefaultV2` |
| 3 | `require-blocking-mode` | `accounts/raiPolicies` | `mode == Blocking` (no audit-only) |
| 4 | `require-prompt-shield-jailbreak` | `accounts/raiPolicies` | Blocking `jailbreak` filter on Prompt |
| 5 | `require-prompt-shield-indirect-attack` | `accounts/raiPolicies` | Blocking `indirect_attack` filter on Prompt |
| 6 | `require-harmful-content-low-threshold` | `accounts/raiPolicies` | hate/sexual/violence/selfharm blocking at severity Low on Prompt + Completion |
| 7 | `require-protected-material-filters` | `accounts/raiPolicies` | Blocking `protected_material_text` + `protected_material_code` on Completion |
| 8 | `require-custom-blocklist` | `accounts/raiPolicies` | At least one `customBlocklists` entry with `blocking=true` |
| 9 | `require-pii-filter` *(v0.17)* | `accounts/raiPolicies` | Blocking `pii` filter on Completion — catches SSN/CC/email/phone/passport emitted by the model |
| 10 | `require-groundedness-filter` *(v0.17)* | `accounts/raiPolicies` | `groundedness` filter on Completion — flags fabricated / ungrounded responses in RAG pipelines |
| 11 | `require-toolcall-filters` *(v0.17)* | `accounts/raiPolicies` | At least one filter on `PreToolCall` or `PostToolCall` intervention point — guards agentic tool-boundary risks |
| 12 | `deny-audit-mode-subfilter` *(v0.17)* | `accounts/raiPolicies` | No individual content filter may have `enabled=true` + `blocking=false` — config-drift detector |

**Deploy (Audit mode — safe to start here):**
```bash
az deployment sub create \
  --name aisec-guardrails-$(date +%Y%m%d-%H%M%S) \
  --location eastus2 \
  --template-file infra/foundry-guardrail-policies.bicep \
  --parameters defaultEffect=Audit
```

**Ramp to Deny once clean:**
```bash
az deployment sub create \
  --name aisec-guardrails-deny-$(date +%Y%m%d-%H%M%S) \
  --location eastus2 \
  --template-file infra/foundry-guardrail-policies.bicep \
  --parameters defaultEffect=Deny
```

**Check compliance:**
```bash
az policy state summarize \
  --policy-set-definition $(az policy set-definition show \
    --name aisec-foundry-guardrails --query id -o tsv) \
  --query 'value[0].policyAssignments[].results'
```

**Why this is optional.** The main `Deploy.ps1` pipeline already configures
the RAI policy directly on the Foundry account (see `infra/guardrails.bicep`).
The Azure Policy initiative is a *second layer*: it prevents regressions
if a new model deployment is added outside the pipeline. Skip it for
pure throw-away demos; deploy it for any lab that simulates production
governance.

## 4. Populate `connections.sharePoint.siteUrl` (optional)

**When.** If you want the `sharepoint_grounding` tool on any agent to
actually ground against real SharePoint content. The tool is skipped
entirely when `siteUrl` is empty, so omitting this step leaves HR and
Finance agents with only their local vector store for document grounding.

**Where.** `config.json` → `workloads.foundry.connections.sharePoint.siteUrl`.

**What to do.**
1. Pick a real SharePoint site (e.g.
   `https://<tenant>.sharepoint.com/sites/aisec-lab-docs`).
2. Grant the Foundry project managed identity read access to the site
   (`Site Reader` role via SharePoint admin).
3. Set `siteUrl` in `config.json`.
4. Rerun `Deploy.ps1 -FoundryOnly` — `foundry_tools.py setup-connections`
   will create the SharePoint project connection, `build-tools` will
   include the tool, and the agents will get replaced via delete-and-create
   so the new tool shows up.

**Why this is manual.** The SharePoint site is an external resource the
repo cannot provision. Connection creation requires the real URL.

## 5. Provision a Grounding with Bing Search connection (optional)

**When.** If you want the `bing_grounding` tool on `Sales-Research`
(currently skipped). The preview API now requires `project_connection_id`
on every `search_configurations[]` entry, so the builder skips the tool
with a warning when no `bingSearch` connection is configured.

**Automated path (v0.10.0+).** Set `workloads.foundry.connections.bingSearch.provision: true`
in `config.json`. `Deploy.ps1 -FoundryOnly` will:
1. PUT a `Microsoft.Bing/accounts` resource (kind `Bing.Grounding`, SKU
   `G1` by default) in the same resource group as the Foundry account.
2. Wire the resulting resource ID into the project connection named
   `<prefix>-bing-grounding`.
3. On teardown (`Deploy.ps1 -RemoveOnly -FoundryOnly`), the account is
   removed alongside the rest of the workload.

Example:
```json
"bingSearch": {
  "provision": true,
  "name": "pv-foundry-bing",
  "sku": "G1"
}
```

**Manual path.** If you already have a Bing Grounding account (different
subscription, shared resource, etc.), provide its resource ID and set
`provision: false`:
```json
"bingSearch": {
  "provision": false,
  "resourceId": "/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Bing/accounts/<name>"
}
```
Then rerun `Deploy.ps1 -FoundryOnly`. `setup-connections` will create the
project connection; the builder will include `bing_grounding` on
Sales-Research.

**Why `provision` defaults to false.** Bing Grounding is billable and
region-limited. The repo doesn't enable it unprompted. Skip entirely if
you don't need live web grounding.

## 6. Pre-connect Graph to skip device-code prompts on reruns

**When.** Optional — makes reruns silent instead of prompting for a
device code on every `Deploy.ps1` invocation.

**Where.** Run this once per shell session (or once per MSAL token
lifetime, typically ~1h):

```powershell
pwsh -Command "Connect-MgGraph -Scopes 'AppCatalog.ReadWrite.All' -TenantId '<YOUR_TENANT_ID>' -NoWelcome"
```

MSAL caches the refresh token to `~/.IdentityService`, so subsequent
`Deploy.ps1 -FoundryOnly` runs pick it up without re-prompting. The
device-code path works fine for fresh sessions, but enter the code
within ~120 seconds or it times out.

**Why this is optional.** `Deploy.ps1` handles this automatically in
v0.8+ via `Connect-LabServices -UseDeviceCode`; pre-connecting is purely
a convenience for tight rerun loops.

## 7. Fire adversarial traffic to light up detections

**Status: AUTOMATED opt-in (v0.9.0+; v0.16+ adds the gateway harness).**
Two paths:

```powershell
# Path A: agent-thread harness (legacy) — fires through Foundry agents,
# attaches user_security_context, can hang on poll for stuck calls.
./Deploy.ps1 -ConfigPath config.json -AdversarialTraffic
```

```bash
# Path B: gateway harness (recommended, v0.16+) — fires through APIM
# AI Gateway directly. Captures full content_filter_result per call,
# grades into 6 outcomes, supports --assert for CI gating, stamps
# run_id into the user field for XDR correlation. See docs/smoke-testing.md.
python3.12 scripts/attack_via_gateway.py --output logs/run.json
python3.12 scripts/attack_via_gateway.py --output logs/run.json --assert --min-coverage 0.9
python3.12 scripts/attack_via_gateway.py --category prompt_injection --wait-for-alerts 15
```

For the full smoke-test contract (expected_classifiers, grades,
coverage matrix, run_id correlation, `--wait-for-alerts`), see
[`docs/smoke-testing.md`](smoke-testing.md).

**When.** After the Foundry workload is deployed and Defender / Purview
are enabled (steps 3 + 5) and you want to *see* alerts surface in the
Defender XDR incident queue, Prompt Shields logs, Purview DSPM for AI,
and Foundry evaluators.

**What it does.** Both harnesses send a curated catalog of hostile
prompts — prompt injection, jailbreak, XPIA, PII harvest, credential
fishing, harmful content, protected material, groundedness
fabrication — at every agent. The gateway harness (Path B) attributes
traffic via the `user` field stamped with a unique `run_id`; the
agent-thread harness (Path A) attaches `user_security_context`. Every
prompt is tagged with the detection signal it is designed to trip.

**Usage.**

```bash
# List the catalog (no network calls):
python3.12 scripts/attack_agents.py --list

# Dry-run (plan only) against the latest manifest:
python3.12 scripts/attack_agents.py --dry-run

# Fire the whole catalog at every agent and capture a JSON report:
python3.12 scripts/attack_agents.py --output logs/attack_$(date +%Y%m%d-%H%M%S).json

# Scope to one category and one agent:
python3.12 scripts/attack_agents.py --category jailbreak --agent HR

# Only high-severity attacks:
python3.12 scripts/attack_agents.py --severity high critical
```

Each result row carries `attack_id`, `category`, `severity`,
`expected_detection`, and a stable `outcome` label
(`ok`, `blocked_content_filter`, `blocked_prompt_shield`,
`blocked_jailbreak`, `blocked_other`, `error`, `network_error`) so you
can correlate what the platform blocked versus what your own agents
allowed through.

**Where to check for the resulting alerts.**

| Attack category | Expected signal surface |
|---|---|
| `prompt_injection` / `jailbreak` | Defender XDR alert `AI.PromptInjection` / `AI.Jailbreak`; Prompt Shields logs |
| `indirect_injection` | Prompt Shields indirect-attack logs + Defender XDR |
| `sensitive_data_exfil` / `credential_fishing` | Defender XDR `AI.SensitiveDataLeakage`; Purview DSPM for AI activity log |
| `pii_harvest` | Purview Sensitive Information Types (SSN, CC, passport, PHI) |
| `harmful_content` / `protected_material` | Azure AI Content Safety blocks; Responsible AI evaluator |
| `groundedness_violation` | Foundry groundedness evaluator score drop |

**Why this is opt-in.** The script generates real traffic and real
alerts. Run it against lab/demo tenants, not production, unless you
have cleared it with your SOC.


## Foundry portal Knowledge tab navigation map (what's empty by design)

If you open the Foundry portal → **Knowledge** blade and one of the
sub-tabs looks empty, that's expected. Here's where each piece of the
lab's knowledge stack actually shows up:

| Foundry portal location | What this lab puts there | How it's created |
|---|---|---|
| **Agents → `<agent>` → Tools → file_search** | 4 vector stores named `AISec-<agent>-knowledge` (HR-Helpdesk, Finance-Analyst, IT-Support, Sales-Research), each with the demo doc corpus from `scripts/demo_docs/<agent_scope>/`. Security-Triage declares no `file_search` tool. | `scripts/foundry_knowledge.py upload` (Step 3 of `Deploy-Foundry`) |
| **Knowledge → Indexes / Vector stores** | Same 4 vector stores surfaced as `ManagedAzureSearch` indexes (the data-plane `/indexes` endpoint backs this view) | Same as above |
| **Connected resources → Azure AI Search** | One search service connection named `AISec-ai-search` pointing at `aisec-search` | `scripts/foundry_tools.py setup-connections` (Step 2) |
| **Azure portal → AI Search → `aisec-search` → Indexes** | One hybrid + semantic index named `aisec-compliance-index` containing 12 docs (3 per agent_scope × 4 agent_scopes) tagged with the `agent_scope` filterable field | `scripts/foundry_search_index.py populate` (Step 3b) |
| **Knowledge → Foundry IQ Knowledge bases** | **Empty by design.** Foundry IQ is a separate, newer (Ignite 2025) agentic-retrieval abstraction that wraps Azure AI Search + connections + reasoning. It is currently portal-only — there is no public REST API to create a Foundry IQ KB programmatically on the Standard Agent Setup tier. | Optional manual step (see below) |

### Optional: create a Foundry IQ Knowledge base manually

If you want to demo Foundry IQ's agentic retrieval (the "40% better
relevance" demo), create one KB by hand in the portal — the lab does
not automate this because the API surface is not yet public.

1. Foundry portal → your project → **Knowledge** → **Foundry IQ
   Knowledge bases** → **+ New knowledge base**.
2. **Name:** `aisec-compliance-iq` (or per-agent, e.g. `aisec-hr-iq`).
3. **Knowledge sources:**
   - Add `aisec-compliance-index` from the connected `AISec-ai-search`
     service. The portal will detect the hybrid + semantic config
     and the `agent_scope` filterable field automatically.
   - Optionally add the `AISec-blob-storage` connection if you want
     Foundry IQ to also crawl the demo doc corpus directly from blob.
4. **Retrieval settings:** leave defaults (agentic retrieval ON,
   reasoning effort = medium).
5. Wire the new KB into one or more agents via **Agents →
   `<agent>` → Knowledge** → attach `aisec-compliance-iq`.

The agents will continue to work without this step — they query the
search index through the existing `azure_ai_search` tool (see Step 3b
in [`CLAUDE.md`](../CLAUDE.md#three-layer-foundry-architecture)).
Foundry IQ adds agentic query reformulation and multi-step retrieval
on top, which is a meaningful UX improvement but not required for the
core lab demo.

**When this becomes automatable.** Once the Foundry IQ KB REST API
ships GA, add a `scripts/foundry_iq.py` (mirroring the structure of
`foundry_search_index.py`) and wire it into `Deploy-Foundry` as
Step 3c. Tracking issue: <https://github.com/chashea/ai-agent-security/issues>
(file one if missing).


## Verification

After working through the manual steps, confirm with:

```bash
# Foundry agents exist with correct tools
TOKEN=$(az account get-access-token --resource https://ai.azure.com --query accessToken -o tsv)
curl -s -H "Authorization: Bearer $TOKEN" \
  "https://aisec-foundry.services.ai.azure.com/api/projects/aisec-project/agents?api-version=2025-05-15-preview" \
  | jq '.data[].name'

# Azure AI Search index exists, AAD auth works, and docs are populated per agent_scope
SEARCH_TOKEN=$(az account get-access-token --resource https://search.azure.com --query accessToken -o tsv)
curl -s -H "Authorization: Bearer $SEARCH_TOKEN" \
  "https://aisec-search.search.windows.net/indexes/aisec-compliance-index/docs/search?api-version=2024-07-01" \
  -H "Content-Type: application/json" \
  -d '{"search":"*","count":true,"facets":["agent_scope"],"top":0}' | jq '.["@odata.count"], .["@search.facets"]'

# Sample semantic-ranked query against a single agent_scope (HR)
curl -s -H "Authorization: Bearer $SEARCH_TOKEN" \
  "https://aisec-search.search.windows.net/indexes/aisec-compliance-index/docs/search?api-version=2024-07-01" \
  -H "Content-Type: application/json" \
  -d '{"search":"how do I request PTO","queryType":"semantic","semanticConfiguration":"aisec-semantic","filter":"agent_scope eq '\''HR-Helpdesk'\''","top":3,"select":"doc_id,title"}'

# Teams apps in org catalog with current version
pwsh -Command "Connect-MgGraph -Scopes 'AppCatalog.ReadWrite.All' -TenantId <tenantId> -NoWelcome; \
  Invoke-MgGraphRequest -Method GET -Uri 'v1.0/appCatalogs/teamsApps?\$filter=startswith(displayName,''AISec'')&\$expand=appDefinitions' \
  | Select-Object -ExpandProperty value | ForEach-Object { Write-Host (\$_.displayName + ' ' + \$_.appDefinitions[0].version + ' ' + \$_.appDefinitions[0].publishingState) }"

# Defender AI plan
az rest --method GET \
  --uri "https://management.azure.com/subscriptions/<subId>/providers/Microsoft.Security/pricings/AI?api-version=2024-01-01" \
  --query '{tier: properties.pricingTier, coverage: properties.resourcesCoverageStatus, extensions: properties.extensions[].name}'

# Agent 365 submissions
# (no direct API to list requested agents — check
# https://admin.cloud.microsoft/?#/agents/all/requested in a browser)
```

If any step fails, see `docs/troubleshooting.md` for root-cause mappings.
