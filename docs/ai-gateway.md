# AI Gateway (APIM v2 in front of Foundry)

APIM-based AI Gateway that sits between clients and the Foundry AOAI
endpoint. Applies the documented [AI-gateway policy stack][gen-ai-ref]:
TPM rate limits, monthly quotas, token metric emission, and managed-
identity auth to Foundry.

This workload is equivalent to the portal's **Operate → Admin console →
AI Gateway → Add AI Gateway** flow, but as Bicep + PowerShell so it
runs through `Deploy.ps1` and survives teardown.

**Version:** v0.12.0+  
**SKU:** BasicV2 by default (~$50/mo, dev/test with SLA)  
**Provision time:** 15-45 minutes first time, ~5 min subsequent changes

## Architecture

```
    client app                          APIM v2 (AI Gateway)             Foundry
  ┌──────────┐   POST /openai/...    ┌─────────────────────┐   MI auth   ┌─────────────┐
  │ Postman/ │ ──────────────────▶   │ llm-token-limit     │ ─────────▶  │ AOAI        │
  │ Python   │   Ocp-Apim-Sub-Key    │ llm-emit-token-     │             │ gpt-4o,     │
  │ SDK      │                       │   metric            │             │ embeddings  │
  └──────────┘                       │ set-backend-service │             └─────────────┘
                                     └─────────────────────┘
                                              │
                                              ▼
                                       Application Insights
                                       (token counts, latency)
```

## What the Bicep creates

`infra/ai-gateway.bicep` provisions:

| Resource | Purpose |
|---|---|
| `Microsoft.ApiManagement/service` (BasicV2) | APIM instance with system-assigned MI |
| `Microsoft.Authorization/roleAssignments` | APIM MI → `Cognitive Services OpenAI User` on the Foundry account |
| `Microsoft.ApiManagement/service/backends` | `foundry-aoai` backend pointing at the Foundry AOAI endpoint |
| `Microsoft.ApiManagement/service/apis` | `aoai` API with chat-completions + embeddings operations |
| `Microsoft.ApiManagement/service/apis/policies` | `llm-token-limit` + `llm-emit-token-metric` + MI auth + backend routing |
| `Microsoft.ApiManagement/service/loggers` | App Insights logger (when `appInsightsResourceId` is set) |
| `Microsoft.ApiManagement/service/apis/diagnostics` | 100% sampling into the App Insights logger |
| `Microsoft.ApiManagement/service/subscriptions` | Starter `aisec-demo` subscription for smoke testing |

## Config

`config.json` → `workloads.aiGateway`:

```json
"aiGateway": {
  "enabled": true,
  "name": "aisec-aigw",
  "sku": "BasicV2",
  "capacity": 1,
  "publisherEmail": "admin@contoso.com",
  "publisherName": "AISec AI Gateway",
  "tokensPerMinute": 1000,
  "monthlyTokenQuota": 0,
  "openaiApiName": "aoai",
  "openaiApiPath": "openai",
  "openaiApiVersion": "2024-10-21"
}
```

| Field | Default | Notes |
|---|---|---|
| `enabled` | `true` | Toggle the workload without removing config. |
| `sku` | `BasicV2` | `StandardV2` / `PremiumV2` for prod. Portal default is `BasicV2`. |
| `tokensPerMinute` | `1000` | Per-subscription TPM rate limit. Exceed → `429 Too Many Requests`. |
| `monthlyTokenQuota` | `0` | `0` disables the quota (rate limit only). Exceed → `403 Forbidden`. |
| `openaiApiPath` | `openai` | URL prefix — gateway URL is `<apim>.azure-api.net/<path>`. |
| `openaiApiVersion` | `2024-10-21` | AOAI API version surfaced; match client SDK. |

## Deploy

Runs automatically as part of `Deploy.ps1` after the Foundry workload
(needs the Foundry account to exist first so the backend URL and MI
role assignment resolve):

```powershell
./Deploy.ps1 -ConfigPath config.json
```

Iterate only on the gateway — assumes Foundry is already deployed, skips
everything else:

```powershell
./Deploy.ps1 -ConfigPath config.json -AIGatewayOnly
```

`-AIGatewayOnly` skips Exchange + Graph connects, runs only the AIGateway
workload, and skips post-deploy validation. If the Foundry account
doesn't exist in the target RG, the Bicep deploy fails with a clear
missing-resource error — create it first with `-FoundryOnly` or a full
run.

Alternative: full Foundry + AIGateway without security workloads:

```powershell
# Foundry + AgentIdentity + AIGateway, skip labeling + identity workloads
./Deploy.ps1 -ConfigPath config.json -FoundryOnly
```

Bicep-only dry run (no cloud connection):

```bash
az bicep build --file infra/ai-gateway.bicep
```

## Test the gateway

After deploy, grab the starter subscription key from the manifest and
call the gateway:

```bash
# Get the key from the manifest (or portal → APIM → Subscriptions → aisec-demo)
KEY=$(jq -r '.data.aiGateway.starterSubscriptionKey' manifests/AISec_<timestamp>.json)
URL=$(jq -r '.data.aiGateway.gatewayUrl' manifests/AISec_<timestamp>.json)

curl -sS "${URL}/openai/deployments/gpt-4o/chat/completions?api-version=2024-10-21" \
  -H "Ocp-Apim-Subscription-Key: $KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "messages": [{"role": "user", "content": "Say hi in one word."}],
    "max_tokens": 8
  }'
```

Verify the policy is firing:

```bash
# Burst beyond tokensPerMinute to trigger 429
for i in $(seq 1 50); do
  curl -s -o /dev/null -w "%{http_code} " \
    "${URL}/openai/deployments/gpt-4o/chat/completions?api-version=2024-10-21" \
    -H "Ocp-Apim-Subscription-Key: $KEY" \
    -H "Content-Type: application/json" \
    -d '{"messages":[{"role":"user","content":"test"}],"max_tokens":500}'
done | tr ' ' '\n' | sort | uniq -c
# Expect a mix of 200s and 429s once the bucket drains
```

Check token metrics in App Insights (if configured):

```
customMetrics
| where name in ("Total Tokens", "Prompt Tokens", "Completion Tokens")
| where timestamp > ago(1h)
| summarize sum(value) by name, customDimensions.Deployment
```

## Teardown

```powershell
./Remove.ps1 -ConfigPath config.json -ManifestPath manifests/AISec_<timestamp>.json
```

APIM deletion is async (15-30 min). The role assignment on Foundry is
removed automatically when the APIM instance is deleted because the MI
is scoped to the APIM resource lifecycle.

## Known limitations

- **Foundry Admin-console association.** The portal "AI Gateway" tab
  lists gateways created through the portal. Bicep-provisioned APIM
  instances fronting Foundry work identically from the data-plane but
  will not appear in that tab (the portal binding uses an undocumented
  control-plane API). The gateway functionality — TPM limits, quotas,
  metrics, MI auth — is the same.
- **v2 SKU only.** AI Gateway requires APIM v2 (BasicV2, StandardV2,
  PremiumV2). Classic Consumption/Developer/Basic tiers are not
  supported by the AI-gateway policies we apply.
- **Single-region only.** The Bicep deploys one APIM instance in one
  region. Multi-region active/active is a PremiumV2 feature and is out
  of scope.
- **Starter subscription is broad.** `aisec-demo` subscription is
  scoped to the `aoai` API and has no per-operation ACL. For prod,
  create per-team subscriptions with product-level scopes.

## Troubleshooting

| Symptom | Root cause | Fix |
|---|---|---|
| `401 Unauthorized` from APIM on first call | APIM MI role assignment hasn't replicated yet | Wait 60-120 seconds after deploy; rerun |
| `401` from Foundry with `wrong issuer` | APIM MI doesn't have `Cognitive Services OpenAI User` on the Foundry account | Re-run deploy; the Bicep `roleAssignment` resource grants it |
| `404 Not Found` on `/openai/deployments/.../chat/completions` | Model deployment name doesn't exist on the Foundry account | Check `aisec-foundry` → Models + endpoints; use the actual deployment name in the URL path |
| `403 Forbidden` with `token quota exceeded` | `monthlyTokenQuota` hit for this subscription key | Wait for the quota window to roll over, or raise `monthlyTokenQuota` in config |
| `429 Too Many Requests` with `token limit exceeded` | `tokensPerMinute` rate limit hit | Throttle the client or raise `tokensPerMinute` |
| APIM provisioning hangs >45 min | Regional capacity / legacy provisioner bug | Check Azure portal → APIM → Activity log for the error. Delete and retry, optionally in a different region. |

## References

- [AI gateway in Azure API Management][gen-ai-ref]
- [Configure AI Gateway in your Foundry resources][foundry-ai-gw]
- [Limit large language model API token usage (`llm-token-limit`)][llm-token-limit]
- [Emit large language model API token metrics (`llm-emit-token-metric`)][llm-emit]

[gen-ai-ref]: https://learn.microsoft.com/azure/api-management/genai-gateway-capabilities
[foundry-ai-gw]: https://learn.microsoft.com/azure/foundry/configuration/enable-ai-api-management-gateway-portal
[llm-token-limit]: https://learn.microsoft.com/azure/api-management/llm-token-limit-policy
[llm-emit]: https://learn.microsoft.com/azure/api-management/llm-emit-token-metric-policy
