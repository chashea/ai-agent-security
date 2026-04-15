# Security Triage Agent Deployment Spec — Review Findings

**Spec version:** 1.0 (Draft)
**Review date:** 2026-04-15
**Reviewer:** Technical Review
**Status:** 9 findings, 0 blockers, 3 high, 4 medium, 2 low

---

## Executive Summary

The architecture is sound and fully Microsoft-native, leveraging Foundry hosted agents, Entra identity, Graph Security API, and Defender for Endpoint without introducing third-party dependencies. The biggest risks are operational — rate-limit budget management, approval timeout behavior, and consent timing — not architectural. The identity model and pilot guardrails are well-designed and demonstrate mature security thinking. Address the nine findings below before Phase 0 begins; none are blockers, but the three high-severity items carry real operational risk if left unresolved.

---

## Findings

### F-1: App-only token flow creates audit attribution gap

**Severity:** HIGH

**Description:** Both agents use the client credentials (app-only) token flow. All Graph API calls are attributed to the agent's Entra identity, not the invoking analyst. The spec acknowledges this limitation in Section 4.3, but the compensating control — correlating chat transcripts in Microsoft Purview — is not detailed. There is no documented procedure for joining agent-initiated Graph audit entries back to the analyst who triggered the request.

**Impact:** During an incident investigation, it will be difficult to determine which analyst requested which data without manual log correlation. This undermines accountability and may not satisfy audit requirements for regulated industries (HIPAA, FERPA). If a compliance review asks "who accessed this incident data and when," the answer requires stitching together two separate log sources with no documented join key.

**Recommended action:**

1. Confirm Purview audit retention covers the full pilot duration (minimum 90 days recommended).
2. Document the correlation procedure explicitly: which Purview table contains the chat transcript, which field joins to the Graph audit entry (e.g., `CorrelationId`, timestamp window, or session ID), and whether this correlation is automated or manual.
3. Add "OBO (on-behalf-of) token flow" as a hard v2 requirement with a design milestone, not just a "future consideration." OBO eliminates this gap entirely by attributing Graph calls to the delegated user.

---

### F-2: Approval gate timeout behavior unspecified

**Severity:** HIGH

**Description:** The workflow spec references a 15-minute timeout on the Teams Adaptive Card approval gate but does not specify what happens when the timeout expires. The behavior on expiry is undefined: auto-deny, silent drop, escalation, or auto-approve are all possible interpretations.

**Impact:** If timeout behavior is undefined, the workflow may silently skip response actions during off-hours when approvers are unavailable, leaving high-severity incidents unaddressed. Conversely, a misconfigured timeout that defaults to auto-approve would bypass the human-in-the-loop control entirely — the single most important safety mechanism in the workflow agent.

**Recommended action:**

1. Explicitly define timeout behavior as **auto-deny with escalation**. The workflow must not take action without explicit human approval.
2. Log the timeout event with full context (incident ID, proposed action, approver list, timestamp).
3. Post a "timed out — action not taken" message to the designated Teams channel so the SOC has visibility.
4. For high-severity incidents (severity 1-2), implement a secondary escalation path: page on-call via PagerDuty or ServiceNow integration. A 15-minute window with no fallback is insufficient for critical incidents outside business hours.

---

### F-3: Advanced Hunting rate budget not quantified

**Severity:** HIGH

**Description:** The workflow agent runs 4 parallel KQL queries per incident for enrichment. With 10 incidents per run and hourly runs, that is 40 queries per hour from the workflow agent alone. The tenant-wide Advanced Hunting API limit is 1,500 queries per hour and 15 queries per minute. The spec relies on "prompt-level discipline" to manage rate consumption but provides no budget calculation or programmatic enforcement.

**Impact:** In a busy tenant with Sentinel automation rules, SOC analysts running manual hunting queries, and the workflow agent all competing for the same rate budget, the 15/min burst limit is easily exceeded. At peak: 4 queries × 5 parallel incidents = 20 simultaneous queries, already over the burst limit. A 429 response during enrichment causes partial enrichment, which leads to incomplete or incorrect triage recommendations — a silent data quality failure.

**Recommended action:**

1. Add a rate budget table to Section 3.3 showing worst-case queries per run, per hour, and per minute, including headroom for manual SOC usage.
2. Implement a token-bucket or leaky-bucket rate limiter in the workflow code (not prompt instructions). Prompt-level discipline is not a control — it is a suggestion the model may ignore under pressure.
3. Reduce `maxParallelEnrichment` to 3 or serialize enrichment queries within each incident to stay under the 15/min burst limit. The current default of 5 parallel incidents with 4 queries each guarantees burst-limit violations under normal load.

---

### F-4: Device group allow-list enforcement is not a code-level guard

**Severity:** MEDIUM

**Description:** The spec states that the device group allow-list is "hard-coded in workflow variables" and "cannot be overridden by agent reasoning." However, it is unclear whether the allow-list check is implemented as a deterministic workflow condition node (code-level enforcement) or as a system prompt instruction (soft enforcement). Prompt instructions are not a security boundary — they can be bypassed by adversarial input, model hallucination, or prompt drift.

**Impact:** If the allow-list check exists only in the system prompt, an adversarial prompt injection or model hallucination could bypass it, causing the workflow agent to execute machine isolation or other response actions against out-of-scope devices. This is the most consequential failure mode in the workflow agent: taking action against the wrong device.

**Recommended action:**

1. Implement the allow-list check as a deterministic workflow condition node (Node 5a in the workflow diagram), not a prompt instruction.
2. The node must: (a) Resolve the target device's group membership via the Defender for Endpoint API. (b) Compare against the `allowedDeviceGroups` workflow variable. (c) Hard-reject with a logged denial if the device is not in the allowed list, regardless of agent reasoning output.
3. Include an allow-list bypass attempt in the rollback drill (Phase 4 exit criteria) to verify the guard holds.

---

### F-5: No error handling for Graph API failures

**Severity:** MEDIUM

**Description:** The spec does not document agent behavior when Graph Security API or Defender for Endpoint API calls fail. Common failure modes include: 403 (consent not granted or scope missing), 429 (rate limit exceeded), 503 (service unavailable), 504 (gateway timeout), and 400 (malformed KQL syntax in Advanced Hunting).

**Impact:** Without defined error handling, the agent may: silently return empty results (analyst assumes "no incidents found" when in reality the query failed), retry indefinitely (consuming rate budget and compounding F-3), or surface raw HTTP error messages and stack traces to the analyst in the Teams chat.

**Recommended action:**

Create an error taxonomy table and include it in the spec:

| HTTP Status | Cause | Agent Behavior | Analyst Message |
|---|---|---|---|
| 400 (KQL) | Malformed query | Stop, log query text | "Query error: {message}. Check syntax." |
| 403 | Missing consent or scope | Stop, alert admin channel | "Permission denied. Contact your admin." |
| 429 | Rate limit exceeded | Wait `Retry-After` seconds, retry once | "Rate limited. Retrying in {n}s." |
| 5xx | Service unavailable | Retry once after 5s, then stop | "Service unavailable. Try again shortly." |

---

### F-6: Phase 0 exit criteria missing consent verification

**Severity:** MEDIUM

**Description:** The Phase 0 exit criteria is stated as "All admin approvals staged, sub confirmed." This does not include verifying that admin consent has been actually granted and that tokens can be acquired. In large enterprise tenants, staging a consent request in the Entra admin portal and having it processed and propagated are different things — consent propagation can take hours, and conditional access policies may block token acquisition even after consent is granted.

**Impact:** Phase 2 (triage agent deployment) could be blocked for days waiting on consent that was assumed to be complete in Phase 0. The delay cascades through the entire pilot timeline and erodes stakeholder confidence.

**Recommended action:**

Add an explicit Phase 0 exit gate:

> "Admin consent granted for all Graph Security and Defender for Endpoint scopes. Token acquisition test successful for both agent identities (triage and workflow). Verified via:
> ```
> az account get-access-token --resource https://graph.microsoft.com
> az account get-access-token --resource https://api.securitycenter.microsoft.com
> ```
> Both tokens acquired without error. Scopes confirmed via jwt.ms decode."

---

### F-7: No load or stress testing plan

**Severity:** MEDIUM

**Description:** Success metrics include "tool call success rate > 95%" and "mean time to first triage summary < 60 seconds," but there is no plan to validate these metrics under concurrent load before production handoff. The pilot phases test functionality and correctness but not capacity.

**Impact:** The pilot may pass all exit criteria with 2-3 analysts but fail when the full SOC team (10-20 analysts) uses the triage agent simultaneously. Under concurrent load, Advanced Hunting queries stack up (compounding F-3), Foundry agent response times degrade, and Teams Adaptive Card delivery may lag — none of which are observable in a low-concurrency pilot.

**Recommended action:**

Add a Phase 4.5 or Phase 5 pre-handoff load test:

1. Simulate N concurrent analyst sessions issuing triage queries.
2. Measure response latency (p50, p95, p99), rate-limit hit rate, and tool call success rate under load.
3. Define a minimum concurrency target: e.g., "10 simultaneous analyst queries with < 90s p95 response latency and zero 429 errors from the workflow agent."
4. If the target is not met, document the concurrency ceiling and communicate it as a known limitation in the production handoff.

---

### F-8: MCP limitation not explained to customer

**Severity:** LOW

**Description:** The risks table notes "MCP tools do not work in Teams/Copilot runtime" but provides no explanation of why. Customers or partners familiar with the Model Context Protocol may ask why it was excluded, especially given its growing adoption.

**Impact:** Minor confusion during scoping conversations. No operational impact on the deployment.

**Recommended action:**

Add one sentence to the risks table:

> "The InfoConnect Agent runtime used by Teams and M365 Copilot restricts outbound network connectivity and does not support the MCP transport protocol. Use OpenAPI tool specifications exclusively for agent tools consumed through these surfaces."

---

### F-9: Region list and data residency not provided

**Severity:** LOW

**Description:** Section 3.1 instructs the reader to "select from regions that support hosted agents and Agent 365 publishing" but does not list which Azure regions currently qualify or provide a link to the relevant Microsoft Foundry documentation.

**Impact:** The customer may select a region that does not support Foundry hosted agents or Agent 365 publishing, causing Phase 1 (infrastructure provisioning) to fail. This is an easily avoidable delay.

**Recommended action:**

1. Provide the current list of supported regions in the spec, or link to the Microsoft Foundry documentation page listing region availability.
2. Note that the existing repo has been tested and validated in `eastus` only. Recommend `eastus` as the default for the pilot unless data residency requirements dictate otherwise.

---

## Strengths

1. **Identity separation is well-designed.** Three distinct identity types — Foundry managed identity, Entra Agent ID, and analyst user — with clear permission boundaries. The decision to use separate Entra Agent IDs per agent persona (triage vs. workflow) is correct and avoids permission envelope bleed between the read-only and write-capable agents.

2. **Pilot guardrails are concrete and enforceable.** The `dryRun` flag, device group allow-list, `maxActionsPerRun` cap, kill switch, and rollback drill are specific, testable, and reversible. These are not aspirational controls — they are implementable as described, which is uncommon in deployment specs at this stage.

3. **Five-layer audit coverage.** Purview compliance logs, Application Insights telemetry, Microsoft Defender for Cloud Apps (MDA), M365 Admin Center, and workflow run history provide redundant observability. The loss of any single audit layer does not create a blind spot.

4. **Privacy-by-default posture.** The spec defaults to aggregate data over PII, requires explicit opt-in for specifics, and prohibits speculation about attribution. This is the correct default for regulated industries and reduces the risk of inadvertent data exposure through the chat interface.

5. **Scope discipline.** Clear in-scope and out-of-scope boundaries are defined and maintained throughout the document. No write-back to Purview, no cross-tenant queries, no auto-remediation without approval. The spec actively resists scope creep, which is critical for a security-domain agent.

6. **Separation of triage and workflow personas.** Different permission envelopes, different consumption patterns, and different onboarding timelines. The workflow agent's elevated permissions (machine isolation, investigation package collection) are gated behind the approval workflow and are not available by default. This layered deployment reduces blast radius during the pilot.

---

## Pre-Phase-0 Checklist

All items derived from findings above. Complete before Phase 0 begins.

- [ ] **F-1:** Document Purview audit correlation procedure (chat transcript table → Graph audit entry join key)
- [ ] **F-1:** Confirm Purview retention period ≥ pilot duration (minimum 90 days)
- [ ] **F-2:** Define approval gate timeout behavior (recommend: auto-deny + escalation + channel notification)
- [ ] **F-3:** Add rate budget calculation to spec Section 3.3 (worst-case queries per hour and per minute)
- [ ] **F-3:** Reduce `maxParallelEnrichment` or serialize enrichment queries to stay under 15/min burst limit
- [ ] **F-4:** Implement device group allow-list as a deterministic workflow condition node, not a prompt instruction
- [ ] **F-5:** Create error taxonomy table for Graph API and Defender API failure modes
- [ ] **F-6:** Add token acquisition test to Phase 0 exit criteria (both agent identities, both resource endpoints)
- [ ] **F-7:** Add concurrent load test to Phase 5 pre-handoff checklist with defined concurrency target
- [ ] **F-8:** Add one-sentence MCP transport limitation explanation to risks table
- [ ] **F-9:** Provide supported region list or documentation link in Section 3.1
