# Microsoft Foundry + Microsoft Purview — Integration Reference

This is the authoritative reference for how `ai-agent-security` wires Microsoft Foundry agents to Microsoft Purview controls. Every claim in this document is grounded in Microsoft Learn sources cited inline. When a future Purview workload module is built (`SensitivityLabels.psm1`, `DLP.psm1`, `Retention.psm1`, `EDiscovery.psm1`, `CommunicationCompliance.psm1`, `InsiderRisk.psm1`), it should link to the relevant section here from its module-level header.

## Sources

- [Use Microsoft Purview to manage data security & compliance for Microsoft Foundry](https://learn.microsoft.com/purview/ai-azure-foundry) — canonical capability matrix + getting started
- [Use Microsoft Purview capabilities to develop and deploy secure and compliant Microsoft Foundry or custom AI apps](https://learn.microsoft.com/purview/developer/secure-ai-with-purview) — developer / SDK integration model
- [Use Microsoft Purview to manage data security & compliance for AI agents](https://learn.microsoft.com/purview/ai-agents) — per-platform agent capability footnotes
- [Enable Data Security for Azure AI with Microsoft Purview](https://learn.microsoft.com/azure/defender-for-cloud/ai-onboarding#enable-data-security-for-azure-ai-with-microsoft-purview) — Defender for Cloud onboarding
- [Manage compliance and security in Microsoft Foundry](https://learn.microsoft.com/azure/ai-foundry/control-plane/how-to-manage-compliance-security) — Foundry control-plane toggle
- [Purview SDK — processContent Graph API](https://learn.microsoft.com/graph/api/userdatasecurityandgovernance-processcontent) — content-enforcement API
- [Purview SDK — computeProtectionScopes Graph API](https://learn.microsoft.com/graph/api/userprotectionscopecontainer-compute)
- [Azure AI Search sensitivity-label indexing (preview)](https://learn.microsoft.com/azure/search/search-indexer-sensitivity-labels) — label enforcement at RAG query time
- [Query-time Purview sensitivity label enforcement in Azure AI Search](https://learn.microsoft.com/azure/search/search-query-sensitivity-labels)
- [DSPM for AI one-click policies](https://learn.microsoft.com/purview/dspm-for-ai-considerations#one-click-policies-from-data-security-posture-management-for-ai)
- [Collection policies — solution overview](https://learn.microsoft.com/purview/collection-policies-solution-overview)
- [Risky AI usage policy template (Insider Risk Management)](https://learn.microsoft.com/purview/insider-risk-management-policy-templates#risky-ai-usage)
- [Learn about retention for Copilot & AI apps](https://learn.microsoft.com/purview/retention-policies-copilot)
- [Audit logs for Copilot and AI activities](https://learn.microsoft.com/purview/audit-copilot)
- [Gain end-user context for Azure AI API calls (`userSecurityContext`)](https://learn.microsoft.com/azure/ai-foundry/openai/reference-preview#usersecuritycontext)
- [New-DlpComplianceRule — Example 4 (Entra-registered AI app scope)](https://learn.microsoft.com/powershell/module/exchange/new-dlpcompliancerule#example-4)
- [`Azure-Samples/serverless-chat-langchainjs-purview`](https://github.com/Azure-Samples/serverless-chat-langchainjs-purview) — reference integration sample

## 1. Prerequisite — enable Purview Data Security on the Foundry subscription

Before any Purview capability can see Foundry prompts and responses, one of these two knobs must be flipped at the subscription level:

- **Foundry portal (control plane):** `https://ai.azure.com` → compliance/security settings → enable Purview Data Security. See [Manage compliance and security in Microsoft Foundry](https://learn.microsoft.com/azure/ai-foundry/control-plane/how-to-manage-compliance-security).
- **Defender for Cloud:** *Enable Data Security for Azure AI with Microsoft Purview*. See [ai-onboarding#enable-data-security-for-azure-ai-with-microsoft-purview](https://learn.microsoft.com/azure/defender-for-cloud/ai-onboarding#enable-data-security-for-azure-ai-with-microsoft-purview).

Applying Purview **policies** (not just audit telemetry) also requires [pay-as-you-go billing](https://learn.microsoft.com/purview/purview-billing-models) to be enabled on the tenant. Audit of Foundry interactions is included in the base Purview license.

This project tracks this prerequisite under `workloads.foundry.purviewDataSecurity` in `config.json`. Deployment of this toggle is currently out of scope; the module is responsible for verifying it and surfacing a warning if the Foundry subscription has not yet been onboarded.

## 2. Three integration paths for custom Foundry AI apps

Per [secure-ai-with-purview](https://learn.microsoft.com/purview/developer/secure-ai-with-purview):

| Scenario | Native Foundry | Agent Framework | Purview Graph APIs |
|---|---|---|---|
| Govern data at runtime (audit, classification, CC, DLM, eDiscovery) | Supported | Supported | Supported |
| Protect against data leaks / enforce DLP | Not supported | Supported | Supported |
| Prevent oversharing (sensitivity labels honored end-to-end) | Not supported | Not supported | Supported (via API or AI Search label indexing) |

- **Native integration (recommended for governance outcomes):** a single subscription-level toggle (§1). Developers do nothing. Provides audit, classification, DSPM visibility, retention, eDiscovery, and Communication Compliance for all Foundry apps in that subscription.
- **Agent Framework middleware:** plug Purview policy middleware into the Microsoft Agent Framework pipeline to intercept prompts and responses and enforce DLP. See [Use Microsoft Purview SDK with Agent Framework](https://learn.microsoft.com/agent-framework/tutorials/plugins/use-purview-with-agent-framework-sdk).
- **Purview Graph APIs (Purview SDK):** `POST /users/{id}/dataSecurityAndGovernance/protectionScopes/compute` and `POST /users/{id}/dataSecurityAndGovernance/processContent`. Reference sample: [serverless-chat-langchainjs-purview](https://github.com/Azure-Samples/serverless-chat-langchainjs-purview). This repo ships a Python wrapper for both endpoints at [`scripts/purview_sdk.py`](../scripts/purview_sdk.py) — `PurviewClient.compute_protection_scopes()` and `PurviewClient.process_content()`, plus a CLI for smoke-testing against a real tenant.

The bot Function App deployed by `Deploy-BotServices` (see `modules/FoundryInfra.psm1`) bundles `purview_sdk.py` into its runtime zip and — when `workloads.foundry.purviewProcessContent.enabled` is true — calls `processContent(uploadText)` before each Foundry call and `processContent(downloadText)` after, threading both with a shared `correlationId` so Activity Explorer pairs them. The Function App's system-assigned managed identity must hold the Graph application permissions `ProtectedContent.Create.All` and `ProtectionScopes.Compute.All`; `Grant-BotFunctionGraphPermissions` attempts the grant at deploy time and falls back to printing a manual `az rest` command when the caller lacks tenant-admin consent. Per §3, the MSI token is **app-context**, so this path populates Audit + DSPM Activity Explorer with classifications but does **not** trigger DLP/IRM/CC enforcement — real blocking requires forwarding the Teams user's Entra token through Bot Framework SSO, tracked as a v0.7 follow-on.

## 3. Critical auth constraint — user security context

Per [ai-azure-foundry#capabilities-supported](https://learn.microsoft.com/purview/ai-azure-foundry#capabilities-supported):

> Microsoft Purview Data Security Policies for Foundry Services interactions apply to API calls that use Microsoft Entra ID authentication with a user-context token, or for API calls that explicitly include user context. For all other authentication scenarios, user interactions are displayed in Microsoft Purview Audit and AI Interactions with classifications in DSPM for AI Activity Explorer only.

If a Foundry agent calls its Azure OpenAI deployment with its own **managed identity** and no user context, Purview policies (DLP, IRM, Communication Compliance) will **not enforce** on that interaction — it will only appear in Audit / Activity Explorer with classifications. To get Purview policies to act on a Foundry interaction, the upstream call must either:

1. Forward the caller's Entra user token (the agent runtime must obtain and propagate it), or
2. Explicitly include `userSecurityContext` on the Azure OpenAI request — see the [OpenAI reference-preview `userSecurityContext` field](https://learn.microsoft.com/azure/ai-foundry/openai/reference-preview#usersecuritycontext).

This project tracks the intent under `workloads.foundry.userSecurityContext.enabled`. Wiring actual propagation into the request path is a runtime concern, not a deploy-time concern — `scripts/foundry_agents.py` only creates agents and never sees a prompt. The reference library for runtime callers to use is [`scripts/purview_sdk.py`](../scripts/purview_sdk.py): it accepts an explicit bearer token (so a runtime can forward the caller's Entra user token verbatim) and falls back to `DefaultAzureCredential` otherwise. If a caller passes an app-context token the calls will still succeed but will only populate Audit + DSPM Activity Explorer — DLP/IRM/CC will not enforce.

## 4. Capability matrix for Microsoft Foundry

From [ai-azure-foundry#capabilities-supported](https://learn.microsoft.com/purview/ai-azure-foundry#capabilities-supported):

| Purview capability | Supported for Foundry interactions |
|---|---|
| DSPM for AI (classic + preview) | Supported |
| Auditing | Supported (included in Purview license) |
| Data classification | Supported |
| Sensitivity labels | Supported (honored at RAG query time via AI Search label indexing, preview) |
| Encryption without sensitivity labels | Not supported |
| Data Loss Prevention | Supported (SIT-based block only, requires Entra-registered app scope + agent integration) |
| Insider Risk Management | Supported (via *Risky AI usage* template) |
| Communication Compliance | Supported |
| eDiscovery | Supported |
| Data Lifecycle Management (retention) | Supported |
| Compliance Manager | Supported |

From [ai-agents#capabilities-supported](https://learn.microsoft.com/purview/ai-agents#capabilities-supported) footnote 2, **Microsoft Foundry agents** specifically support: *data classification, sensitivity labels, data loss prevention, Insider Risk Management*.

Microsoft Entra Conditional Access and Microsoft Defender for Cloud Apps (MDCA) are **not** in the Foundry × Purview matrix. They remain useful as adjacent identity and SaaS controls but must be understood as *outside* the Purview-for-Foundry integration story — this document does not cover them.

## 5. Capability-specific integration shapes

### 5.1 DSPM for AI one-click policies (collection policies)

DSPM for AI is the front door. The two one-click policies that matter for Foundry are:

- **DSPM for AI — Capture interactions for enterprise AI apps** — created from the *Secure interactions from enterprise apps* recommendation. Captures prompts and responses from enterprise AI apps.
- **DSPM for AI — Detect sensitive info shared with AI via network** — created from the *Extend insights into sensitive data in AI app interactions* recommendation. This is the *collection policy* that IRM, Communication Compliance, eDiscovery, and Data Lifecycle Management all list as a prerequisite for prompts and responses to flow into their solutions.

See [dspm-for-ai-considerations#one-click-policies-from-data-security-posture-management-for-ai](https://learn.microsoft.com/purview/dspm-for-ai-considerations#one-click-policies-from-data-security-posture-management-for-ai). This project tracks these under the top-level `workloads.collectionPolicies` section.

### 5.2 DLP for Foundry

Per [ai-azure-foundry#capabilities-supported](https://learn.microsoft.com/purview/ai-azure-foundry#capabilities-supported):

> Support today is only available for a DLP policy that blocks prompts based on sensitive information types. This requires the configuration of a PowerShell cmdlet that's scoped to a specific Entra-registered AI app. The AI app can honor this configuration by integration with the Microsoft Purview APIs.

In practice:

1. Register the Foundry agent (or its fronting web app) in Microsoft Entra.
2. Author DLP rules with [`New-DlpComplianceRule` example 4](https://learn.microsoft.com/powershell/module/exchange/new-dlpcompliancerule#example-4), scoping each rule to the app's object ID.
3. Have the agent call `computeProtectionScopes` and `processContent` on every prompt (see the [langchainjs-purview sample](https://github.com/Azure-Samples/serverless-chat-langchainjs-purview)). Use [`scripts/purview_sdk.py`](../scripts/purview_sdk.py) from Python runtimes — `PurviewClient.process_content(activity=ProcessActivity.UPLOAD_TEXT, ...)` before forwarding to the model; `ProcessActivity.DOWNLOAD_TEXT` on the response. `blocked=True` on the returned `ProcessContentResult` indicates a `restrictAccess` policy action and should short-circuit the model call.

Only **SIT-based block** rules are supported today. Label-based DLP for Foundry is not GA — do not author label-condition rules against the Foundry app scope and expect enforcement.

### 5.3 Retention for Foundry interactions

Retention policy location must be **`Enterprise AI apps`** (the portal location; the PowerShell literal is the one exposed by the retention cmdlets as of this writing). Exchange and OneDrive locations do not capture Foundry interactions even though the underlying storage is the user's mailbox. See [retention-policies-copilot](https://learn.microsoft.com/purview/retention-policies-copilot). Retention enforcement requires the collection policy from §5.1.

### 5.4 eDiscovery for Foundry interactions

Per [ai-azure-foundry#getting-started-recommended-steps](https://learn.microsoft.com/purview/ai-azure-foundry#getting-started-recommended-steps):

> In the case, create a search and use the *ItemClass* property and the `IPM.SkypeTeams.Message.ConnectedAIApp.AzureAI.<AzureResourceName>` value to search for these interactions in your organization.

For this project the value is `IPM.SkypeTeams.Message.ConnectedAIApp.AzureAI.aisec-foundry` (matching `workloads.foundry.accountName`). Prompts and responses live in the user's mailbox; the search must target mailbox sources. Collection policy (§5.1) must be in place first.

### 5.5 Sensitivity labels honored at RAG query time

Per [search-indexer-sensitivity-labels](https://learn.microsoft.com/azure/search/search-indexer-sensitivity-labels) and [search-query-sensitivity-labels](https://learn.microsoft.com/azure/search/search-query-sensitivity-labels):

1. Azure AI Search sensitivity-label indexing must be enabled on the index (public preview).
2. The AI Search service's system-assigned managed identity must hold two Purview roles: `Content.SuperUser` (for label + content extraction) and `UnifiedPolicy.Tenant.Read` (for label metadata access).
3. Users querying the index must have the `VIEW` and `EXTRACT` usage rights on any encrypted labeled items for those items to be returned in search results.

Without all three of these, the core *AI-Restricted content never reaches the model* control is inert — RAG will happily return labeled content the user should not see. This project tracks the intent under `workloads.sensitivityLabels.aiSearchEnforcement`.

### 5.6 Insider Risk Management

Use the built-in [Risky AI usage](https://learn.microsoft.com/purview/insider-risk-management-policy-templates#risky-ai-usage) template. It detects prompt injection attempts and access to protected materials. Requires the collection policy from §5.1 — without it, the template has no data source.

### 5.7 Communication Compliance

Use [Configure a communication compliance policy to detect for generative AI interactions](https://learn.microsoft.com/purview/communication-compliance-copilot). Requires the collection policy from §5.1.

### 5.8 Auditing

Once §1 is enabled, prompts and responses are captured in the unified audit log and flow into Activity Explorer automatically. See [audit-copilot](https://learn.microsoft.com/purview/audit-copilot). No additional config required beyond the subscription-level toggle.

## 6. Deploy order implied by Microsoft Learn

Given the prerequisite chain in §5, the deploy order inside this project's `Deploy.ps1` should be:

1. **Foundry** (provision agents, account, project)
2. **Purview Data Security subscription toggle** (§1) — currently manual / out of scope
3. **Sensitivity labels** + AI Search label enforcement roles (§5.5)
4. **Collection policies** (§5.1) — prerequisite for the next five
5. **DLP** (§5.2)
6. **Retention** (§5.3)
7. **eDiscovery** (§5.4)
8. **Communication Compliance** (§5.7)
9. **Insider Risk Management** (§5.6)
10. **Audit config** (§5.8) — optional, data already flows from §1

The existing order in `Deploy.ps1` is close but lacks a `CollectionPolicies` step between steps 4 and 5.

## 7. What this project does not cover

- Conditional Access policies (not in the Foundry × Purview matrix). Tracked separately under `workloads.conditionalAccess`; managed as an adjacent identity control, not a Purview control.
- Defender for Cloud Apps (MDCA) session policies and app governance. Tracked separately under `workloads.mdca`; managed as an adjacent SaaS control, not a Purview control.
- Label-based DLP enforcement on Foundry interactions (not GA).
- Enabling the subscription-level Purview Data Security toggle automatically — this is a manual prerequisite today.
- Forwarding user-context tokens through `scripts/foundry_agents.py`.
