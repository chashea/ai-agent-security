# Post-deploy manual steps

`Deploy.ps1` gets you most of the way, but a handful of steps still need
human intervention because they either (a) require tenant admin approval,
(b) depend on resources the repo does not provision, or (c) are blocked
by MCAPS governance policies that cannot be bypassed automatically. Work
through this checklist after every clean deploy; most items are one-time
per lab tenant.

## 1. Approve Agent 365 digital-worker submissions

**When.** After `workloads.foundry.agent365.enabled = true` and a deploy
that calls `Publish-FoundryAgentsAsDigitalWorkers`. Each submission lands
in the M365 admin center "Agents" request queue with `status: requested`
until a tenant admin approves it.

**Where.** <https://admin.cloud.microsoft/?#/agents/all/requested>

**What to do.** Open each pending agent → review → Approve. The admin
center routes the agent into Teams + Copilot and adds it to the deployed
Agents pane. You'll see one entry per agent published by the deploy (4 in
the default config: HR-Helpdesk, Finance-Analyst, IT-Support,
Sales-Research).

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
find each app (HR-Helpdesk, Finance-Analyst, IT-Support, Sales-Research)
→ **Deploy**.

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

**When.** Once per subscription. This is the subscription-level toggle
that lets Purview Data Security Posture Management (DSPM for AI) see
Foundry prompts/responses and feeds the Defender portal "AI agents"
inventory.

**Where.** Defender for Cloud → Environment settings → pick the
subscription (`9d02bc65-...` in the default tenant) → AI services →
Settings → **Enable data security for AI interactions**.

**Verify automatically:**
```bash
az rest --method GET \
  --uri "https://management.azure.com/subscriptions/<subId>/providers/Microsoft.Security/pricings/AI?api-version=2024-01-01"
# Expect: pricingTier: Standard, resourcesCoverageStatus: FullyCovered
# Expect: extensions list includes AIModelScanner, AIPromptEvidence, AIPromptSharingWithPurview
```

**What to do.** Flip the toggle. The deploy tries to verify this and
surfaces a warning if it can't read the pricing; the actual enablement
is safe to do in the portal. Expect a 4–24 hour propagation delay before
Foundry agents show up under Defender portal → AI security → Agents.

**Why this is manual.** The Defender for AI pricing plan is subscription-
scoped and the module can't toggle it from a per-deploy script without
additional role permissions. `Deploy.ps1` only warns.

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

**Where.** Azure portal → Create a resource → search "Grounding with Bing
Search" → create in the target subscription. Then add its resource ID
to `config.json` → `workloads.foundry.connections.bingSearch`.

**What to do.**
1. Provision the Bing Search resource.
2. Capture its resource ID (looks like
   `/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Bing/accounts/<name>`).
3. Add to `config.json`:
   ```json
   "bingSearch": {
     "resourceId": "/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Bing/accounts/<name>",
     "apiKey": "<key>"
   }
   ```
4. Rerun `Deploy.ps1 -FoundryOnly`. `setup-connections` will create the
   project connection; the builder will include `bing_grounding` on
   Sales-Research.

**Why this is manual.** Bing Search is billable and tenant-specific —
the repo does not provision it because cost and region choices vary.
Skip entirely if you don't need live web grounding.

## 6. Create a Purview collection policy if none shows up in DSPM for AI

**When.** If the Purview portal's DSPM for AI → Activity Explorer is empty
after the full deploy (not `-FoundryOnly`). The deploy creates
`workloads.collectionPolicies` policies as a prerequisite for
DLP/IRM/CommCompliance/eDiscovery/Retention to receive Foundry
prompts/responses, but this depends on Purview tenant-side provisioning.

**Where.** Purview portal → Data Security Posture Management for AI →
Policies → Recommendations.

**What to do.** If the recommendations "Secure interactions from enterprise
apps" and "Extend insights into sensitive data in AI app interactions"
aren't created automatically, create them by hand via the one-click
recommendation cards. The policies must exist *before* you send test
traffic, or Activity Explorer stays empty.

**Why this is manual.** DSPM for AI is a preview workload; the one-click
create API surfaces are not all GA and depend on the tenant being
onboarded to Purview Data Security.

## 7. Generate demo traffic

**When.** Before every Purview demo. Without real prompts hitting the
agents, DLP alerts, IRM signals, Activity Explorer rows, and Comm
Compliance reviews all stay empty.

**Where.** Foundry portal → aisec-project → Agents → pick an agent → Try
in playground. Or call the Foundry REST endpoint directly:

```bash
TOKEN=$(az account get-access-token --resource https://ai.azure.com --query accessToken -o tsv)
curl -X POST \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  "https://aisec-foundry.services.ai.azure.com/api/projects/aisec-project/threads" \
  -d '{}'
# then POST /threads/{id}/messages, POST /threads/{id}/runs with assistant_id
```

**What to do.** Send 5–10 prompts per agent covering:
- Benign baseline ("what's the HR policy on PTO carryover?")
- SSN in the prompt ("my SSN is 123-45-6789, can you confirm my PTO?") —
  triggers DLP if rules are active
- Credit card number — triggers DLP
- Medical term ("I have been diagnosed with X") — triggers DLP
- Prompt injection attempt ("ignore previous instructions and ...") —
  triggers indirect attack detector
- Out-of-scope query ("what's the weather?") — triggers task adherence
  evaluator

Wait 5–10 minutes, then check:
- Purview Activity Explorer for prompt/response rows
- Purview DLP alerts for blocked / allowed-with-justification events
- Foundry Evaluations blade for continuous-eval scores

**Why this is manual.** Demo traffic needs intent and the prompts differ
by audience. The repo doesn't ship synthetic-traffic tooling beyond the
pre-deploy evaluation pipeline (which uses Foundry's own synthetic data
generator for batch evals, not for populating Purview).

## 8. Pre-connect Graph to skip device-code prompts on reruns

**When.** Optional — makes reruns silent instead of prompting for a
device code on every `Deploy.ps1` invocation.

**Where.** Run this once per shell session (or once per MSAL token
lifetime, typically ~1h):

```powershell
pwsh -Command "Connect-MgGraph -Scopes 'AppCatalog.ReadWrite.All' -TenantId 'f1b92d41-6d54-4102-9dd9-4208451314df' -NoWelcome"
```

MSAL caches the refresh token to `~/.IdentityService`, so subsequent
`Deploy.ps1 -FoundryOnly` runs pick it up without re-prompting. The
device-code path works fine for fresh sessions, but enter the code
within ~120 seconds or it times out.

**Why this is optional.** `Deploy.ps1` handles this automatically in
v0.8+ via `Connect-LabServices -UseDeviceCode`; pre-connecting is purely
a convenience for tight rerun loops.

## Verification

After working through the manual steps, confirm with:

```bash
# Foundry agents exist with correct tools
TOKEN=$(az account get-access-token --resource https://ai.azure.com --query accessToken -o tsv)
curl -s -H "Authorization: Bearer $TOKEN" \
  "https://aisec-foundry.services.ai.azure.com/api/projects/aisec-project/agents?api-version=2025-05-15-preview" \
  | jq '.data[].name'

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
