# Defender Incident Triage

Playbook for triaging incidents in Microsoft Defender XDR / Defender portal. Applies to alerts from Defender for Endpoint, Defender for Cloud, Defender for Identity, Defender for Office 365, and Defender for Cloud Apps.

## Severity and SLA

| Severity | First-touch SLA | Containment SLA | Escalation |
|---|---|---|---|
| High | 15 min | 1 hour | Always page on-call |
| Medium | 1 hour | 4 hours | Page on-call if > 4 correlated alerts |
| Low | 8 business hours | 2 business days | No page, daily review |
| Informational | N/A | N/A | Tune or suppress |

High and Medium incidents should always have an incident record in Sentinel / ticketing with owner + status tracked.

## Triage workflow

1. **Open the incident.** Defender portal → Incidents & alerts → Incidents. Sort by severity × last-updated.
2. **Read the description.** Defender auto-correlates alerts into an incident — the summary is usually enough to decide on the initial response.
3. **Check the attack story graph.** Each incident has a visual timeline showing assets, users, alerts, and entities.
4. **Assess scope.** How many devices/users are involved? Is this a single detection or a correlated chain?
5. **Determine false positive likelihood.** Check comments from prior similar alerts, the MITRE technique, and whether the indicator has tuning history.
6. **Decide on response.** Contain → investigate → remediate → close with disposition.

## Response actions

### Endpoint (Defender for Endpoint)

- **Isolate device** — cuts network access except to the Defender portal
- **Collect investigation package** — dumps autoruns, installed programs, running processes to a zip
- **Initiate antivirus scan** — full or quick
- **Restrict app execution** — block unsigned binaries
- **Live response** — open a remote PowerShell-like shell to the device

### Identity (Defender for Identity / Entra)

- **Confirm user compromised** — marks user as compromised in Entra, triggers CA risk policies
- **Require password change** — force next-signin reset
- **Revoke sessions** — invalidates refresh tokens for all apps
- **Disable user** — last resort; breaks anything the user is signed into

### Cloud (Defender for Cloud)

- **Trigger Logic App** — automated remediation via SOAR playbook
- **Assign to owner** — route to resource owner via tag lookup
- **Dismiss** — suppress if tuning is required

## Closing an incident

Set a disposition when closing:

| Disposition | Meaning |
|---|---|
| True positive | Confirmed malicious, action taken |
| Benign positive | Detection was correct but activity was authorized |
| False positive | Detection was wrong; file a tuning request |
| Inconclusive | Cannot determine with available telemetry |

Always leave a comment explaining the decision. Future analysts will thank you.

## Key questions to ask

1. **Who is the user and what's their role?** Admin accounts get white-glove treatment.
2. **What's the device tier?** Tier-0 (domain controllers, KV access) → emergency protocol; Tier-2 (workstation) → standard.
3. **Is the indicator known?** Check threat intel — if it's a known APT IoC, escalate.
4. **Is there lateral movement?** Look for process injection, credential dumping, SMB beacons from the same host.
5. **When did first activity happen?** If the earliest alert is > 24h old, assume persistence is in place.

## Common pivots

- From an alert → `AlertEvidence` table in advanced hunting → see all the entities the alert touched
- From a user → `SigninLogs` + `IdentityLogonEvents` for the last 7 days
- From a device → `DeviceProcessEvents` + `DeviceNetworkEvents` around the alert timestamp
- From a file hash → `DeviceFileEvents` across the whole fleet (has anyone else seen this?)
