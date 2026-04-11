# Contoso IT Security Operations Runbook

**Last Updated: 2026-01-15**
**Classification: Internal**
**Owner: IT Security Operations**

---

## Overview

This runbook defines security operational procedures for Contoso's IT environment. All IT staff and Security Operations Center (SOC) analysts are required to follow these procedures. Deviations must be documented and approved by the IT Security Manager.

---

## Password Policy

All Contoso accounts — including corporate Active Directory, Azure AD, SaaS applications, and service accounts — must comply with the following:

| Requirement | Standard |
|---|---|
| Minimum length | 14 characters |
| Complexity | Uppercase, lowercase, number, and special character required |
| Maximum age | 90 days (rotation required) |
| Password history | Last 12 passwords cannot be reused |
| Account lockout | 5 failed attempts triggers 15-minute lockout |
| MFA | Required for all accounts without exception |

Service accounts must have passwords rotated every 90 days and stored in Azure Key Vault. No service account passwords may be stored in scripts, configuration files, or source code.

---

## Multi-Factor Authentication (MFA)

- MFA is enforced via Entra ID Conditional Access for all users.
- Approved MFA methods: Microsoft Authenticator app (push), FIDO2 hardware key.
- SMS-based MFA is not permitted due to SIM-swapping risk.
- MFA bypass requests require IT Security Manager approval and are time-limited (max 24 hours).

---

## Endpoint Protection

Contoso uses Microsoft Defender for Endpoint (MDE) across all managed devices.

### Requirements
- All corporate laptops and desktops must be Intune-enrolled and Entra ID-joined.
- MDE must be in active mode — passive mode is not permitted on corporate endpoints.
- Tamper protection must be enabled. Disabling requires IT Security approval and an approved change ticket.
- BitLocker encryption is mandatory on all Windows devices.
- macOS endpoints must have FileVault enabled and be managed via Intune.

### Responding to MDE Alerts
1. Triage the alert in the Microsoft Defender portal (`security.microsoft.com`).
2. Classify severity per the severity matrix in Section 6.
3. If device is compromised: isolate immediately using MDE's device isolation feature.
4. Open a ServiceNow incident ticket and link the MDE alert ID.
5. Notify the device owner's manager if isolation will impact business operations.

---

## Phishing Response Procedure

### User Reports Phishing Email
1. User forwards the suspected phishing email to `phishing@contoso.com` or uses the "Report Phishing" button in Outlook.
2. SOC analyst reviews the submission within 1 hour during business hours (4 hours off-hours).
3. If confirmed phishing:
   a. Block sender domain and URL in Defender for Office 365.
   b. Purge the email from all mailboxes using Microsoft 365 Threat Explorer.
   c. Search audit logs for any users who clicked links or opened attachments.
   d. For any user who interacted with the email: force password reset, revoke active sessions, check for inbox rules or forwarding.
4. If credentials were entered on a phishing page: treat as SEV1 credential compromise (see Incident Response plan).
5. Document findings in the ServiceNow ticket and close with resolution notes.

---

## Data Classification Handling

| Classification | Description | Handling Requirements |
|---|---|---|
| Public | Approved for public release | No restrictions |
| Internal | Default for all company data | Do not share externally without approval |
| Confidential | Sensitive business or customer data | Encrypt in transit and at rest; need-to-know access |
| Restricted | Regulated data (PII, financial, legal) | Encrypt always; DLP controls enforced; access logged |

Restricted data must not be stored on personal devices, in personal cloud storage accounts, or in non-approved SaaS tools. Violations must be reported to IT Security and the employee's manager.

---

## VPN Requirements

- All access to on-premises resources requires VPN (GlobalProtect).
- Remote access to production infrastructure requires both VPN and privileged access workstation (PAW).
- Split tunneling is disabled — all traffic routes through the VPN when connected.
- VPN is not required for access to Contoso's Microsoft 365 or Azure cloud resources (managed by Conditional Access).

---

## Security Patch Policy

| Patch Type | Deadline |
|---|---|
| Critical CVE (CVSS 9.0+) | 72 hours from vendor release |
| High CVE (CVSS 7.0–8.9) | 14 days |
| Medium CVE (CVSS 4.0–6.9) | 30 days |
| Low CVE (below 4.0) | Next scheduled maintenance window |

Patch compliance is tracked in Defender for Vulnerability Management. Departments with devices below 95% compliance receive escalation to the department VP.

---

## Contacts

- IT Security Manager: `security-manager@contoso.com`
- SOC 24/7 hotline: ext. 5500 or `soc@contoso.com`
- Security incidents: `incident@contoso.com`
- Phishing reports: `phishing@contoso.com`
