# Contoso IT Incident Response Plan

**Last Updated: 2026-01-15**
**Classification: Internal**
**Owner: IT Security Operations**

---

## Overview

This document defines the incident response (IR) process for Contoso IT security incidents. All IT staff and SOC analysts must follow this process. The goal is to detect, contain, eradicate, and recover from incidents in a consistent and auditable manner.

---

## Severity Levels

### SEV1 — Critical

Active breach or ransomware, imminent data exfiltration, confirmed credential compromise of privileged account, production system outage affecting all customers.

- **Initial Response Target:** 15 minutes
- **Resolution Target:** 4 hours
- **Escalation:** CISO, CTO, and VP of Engineering notified immediately

### SEV2 — High

Suspected breach under investigation, significant data exposure (Restricted data), widespread malware on corporate network, single-system ransomware contained to one host, production degradation affecting >25% of customers.

- **Initial Response Target:** 30 minutes
- **Resolution Target:** 8 hours
- **Escalation:** IT Security Manager, relevant department VP

### SEV3 — Medium

Phishing email with confirmed clicks, malware on isolated endpoint, unauthorized access attempt (blocked), production degradation affecting <25% of customers, access policy violation.

- **Initial Response Target:** 2 hours
- **Resolution Target:** 24 hours
- **Escalation:** IT Security Manager

### SEV4 — Low

Failed login anomaly, low-confidence alert requiring investigation, policy audit finding, non-impactful vulnerability disclosed.

- **Initial Response Target:** 4 business hours
- **Resolution Target:** 5 business days
- **Escalation:** Assigned SOC analyst

---

## Escalation Paths

```
SOC Analyst (initial detection)
    |
IT Security Manager
    |
CISO (SEV1 and SEV2)
    |
CTO / CEO (SEV1 with business impact or data breach notification required)
    |
Legal / Privacy Team (if PII or regulated data involved)
    |
External Counsel / PR (if breach notification or media response required)
```

For after-hours SEV1 incidents: page the on-call security engineer at `soc-oncall@contoso.com`. The on-call rotation is published in PagerDuty.

---

## Incident Response Phases

### Phase 1: Detection and Triage
1. Alert received from SIEM (Microsoft Sentinel), MDE, user report, or third party.
2. SOC analyst assigns initial severity and opens a ServiceNow incident ticket.
3. Analyst performs initial triage — confirm whether the alert is a true positive.
4. If true positive: escalate per severity level. If false positive: document and close.

### Phase 2: Containment
1. Isolate affected systems using MDE device isolation or network segmentation.
2. Revoke compromised credentials and active sessions immediately.
3. Preserve forensic evidence before remediation — do not wipe or reimagine without evidence capture.
4. Block attacker infrastructure (IPs, domains) in Defender for Office 365 and firewall.

### Phase 3: Eradication
1. Identify root cause and full scope of compromise.
2. Remove malware, unauthorized accounts, and attacker persistence mechanisms.
3. Patch the vulnerability or misconfiguration that enabled the incident.
4. Validate eradication with a clean scan from MDE.

### Phase 4: Recovery
1. Restore affected systems from clean backups or rebuild from known-good images.
2. Re-enable access for affected users after credential reset and MFA re-enrollment.
3. Monitor restored systems closely for 72 hours post-recovery.
4. Confirm business operations have returned to normal.

### Phase 5: Post-Mortem
1. Post-mortem is required for all SEV1 and SEV2 incidents.
2. Post-mortem must be completed within 5 business days of incident closure.
3. Use the post-mortem template in Confluence at `confluence.contoso.internal/ir-postmortem`.
4. Identify contributing factors using a blameless root cause analysis.
5. Document action items with owners and due dates.
6. Share findings with IT Security Manager and relevant stakeholders.

---

## Communication Templates

### Internal Notification (SEV1)
```
Subject: [SEV1 INCIDENT] [Brief Description] — In Progress

We are actively responding to a security incident. 
Affected systems: [list]
Current status: [Containment / Eradication / Recovery]
Impact: [Description]
Next update: [Time]

Contact: soc@contoso.com or ext. 5500
```

### External Notification (Data Breach — coordinate with Legal before sending)
```
Subject: Important Security Notice from Contoso

We are writing to inform you of a security incident that may have affected 
information associated with your account. [Description of what occurred, 
what data was involved, steps taken, and what you should do.]
```

---

## Post-Mortem Requirements

Post-mortems for SEV1 and SEV2 incidents must address:

- Timeline of events (detection through recovery)
- Root cause analysis (technical and process factors)
- What worked well in the response
- What did not work or was delayed
- Action items with assigned owners and due dates
- Any regulatory reporting obligations identified (GDPR, CCPA, etc.)

Post-mortems are reviewed by the CISO quarterly as part of the security program review.

---

## Contacts

- SOC 24/7: `soc@contoso.com` or ext. 5500
- IT Security Manager: `security-manager@contoso.com`
- CISO: `ciso@contoso.com`
- Legal / Privacy: `privacy@contoso.com`
- PagerDuty on-call: `soc-oncall@contoso.com`
