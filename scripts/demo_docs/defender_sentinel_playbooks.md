# Defender + Sentinel Playbooks

Reference for building automation playbooks in Microsoft Sentinel. Playbooks are Logic Apps triggered by Sentinel alerts or incidents to enrich, contain, notify, or remediate automatically.

## Trigger types

| Trigger | When it fires | Typical use |
|---|---|---|
| Alert trigger (deprecated) | On each alert | Legacy; prefer incident trigger |
| Incident trigger | On each incident (+ after updates) | Modern automation — one run per incident |
| Entity trigger | Manual from an entity page | User-driven enrichment ("run this on this IP") |

Prefer **Incident trigger** for anything automated. Use **Entity trigger** for analyst-initiated flows.

## Playbook categories

### 1. Enrichment

- **VirusTotal / AbuseIPDB lookup** — check file hash or IP reputation, post the result as a comment
- **WHOIS + GeoIP** — annotate foreign-origin sign-ins with ASN and country
- **Asset owner lookup** — query your CMDB to find who owns the affected device
- **Threat intel pivot** — check internal TI feeds for known-bad indicators

### 2. Containment

- **Disable user account** — via Graph API (`PATCH /users/{id}` with `accountEnabled=false`)
- **Revoke user sessions** — `POST /users/{id}/revokeSignInSessions`
- **Isolate device** — Defender for Endpoint API `POST /machines/{id}/isolate`
- **Block IP at firewall** — push to Azure Firewall rule collection or third-party SIEM

### 3. Notification

- **Teams notification** — post to a SOC channel with incident details + action links
- **Email to owner** — find the resource owner via tag lookup and email them
- **PagerDuty / ServiceNow** — open a ticket for tracking
- **SMS via Twilio** — for after-hours on-call

### 4. Response

- **Auto-quarantine email** — Defender for Office 365 submission API
- **Kill process** — live response on the affected device
- **Delete scheduled task** — via Defender live response
- **Reset password** — Graph API `POST /users/{id}/authentication/methods/.../resetPassword`

## Automation rules vs playbooks

Sentinel automation rules can fire playbooks, but they can also do simple things natively:

| Task | Automation rule | Playbook |
|---|---|---|
| Assign owner | Yes | Yes |
| Change severity | Yes | Yes |
| Add tags | Yes | Yes |
| Close incident | Yes | Yes |
| Call REST API | No | Yes |
| Query another system | No | Yes |

Start with automation rules for simple things, graduate to playbooks when you need external calls.

## Common patterns

### Pattern 1 — Enrich on creation, escalate on confirmation

Rule 1: "When incident is created → run VirusTotal enrichment playbook → tag `enriched`"
Rule 2: "When incident status changes to confirmed → run isolation playbook + Teams notification"

Splitting it lets the analyst see the enrichment before deciding to contain.

### Pattern 2 — Auto-close benign patterns

Rule: "When incident title matches `'Multiple failed logins'` and source IP is in `BenignSubnets` → close as benign"

Use a Sentinel watchlist for the subnet list so it's maintainable.

### Pattern 3 — Retry with backoff

Defender APIs throttle. Wrap any playbook action in a retry loop (Logic App native "Set retry policy" on the HTTP action) — 5 retries, exponential backoff.

## Testing

1. Build the playbook in a dev subscription first
2. Manually trigger on a test incident
3. Check the run history in the Logic App blade
4. Promote to prod via ARM template or Bicep
5. Monitor failure rate via Logic App metrics — alert if > 5% over 1h

## Security considerations

- Give the playbook managed identity the *least* permissions it needs
- Never log sensitive data (passwords, tokens) in run history — use "Secure outputs" on HTTP actions
- Audit playbook changes — enable Activity Log for the Logic App resource
- Separate playbook resource groups from incident data so you can grant SOC analysts read access to one without the other
