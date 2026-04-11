# Contoso IT Access Request Guide

**Last Updated: 2026-01-15**
**Classification: Internal**
**Owner: IT Operations**

---

## Overview

This guide covers how to request, approve, and manage access to Contoso systems and applications. All access requests must be submitted through ServiceNow at `servicenow.contoso.internal`. Requests made via email or Slack without a corresponding ServiceNow ticket will not be processed.

---

## ServiceNow Ticket Categories

Use the correct category when opening a ticket to ensure proper routing and SLA tracking.

| Category | Use When |
|---|---|
| Access Request – Standard | Requesting access to standard business applications (M365, Salesforce, Workday, etc.) |
| Access Request – Privileged | Requesting admin rights, server access, database access, or security tool access |
| Access Request – New Hire | Provisioning access for a new employee (submitted by HR or hiring manager) |
| Access Request – Contractor | Provisioning access for a contractor or vendor (requires Vendor Security Agreement on file) |
| Access Removal | Revoking access for departing employees, role changes, or project completions |
| Access Review | Periodic access certification or manager-initiated review |

---

## Approval Matrix

| Access Type | Who Approves |
|---|---|
| Standard application access | Direct manager |
| Elevated role within a standard app (e.g., Salesforce Admin) | Manager + Application Owner |
| Privileged access (admin, root, DBA, firewall) | Manager + IT Security team |
| Production database access | Manager + IT Security + DBA team lead |
| Security tooling (SIEM, MDE console, Entra admin) | IT Security Manager |
| Executive or Board-level data access | CISO approval required |

All privileged access is subject to quarterly access reviews. Accounts inactive for 90 days are automatically disabled.

---

## SLA Targets

| Access Type | Target Fulfillment Time |
|---|---|
| Standard access (pre-approved catalog items) | 4 business hours |
| Standard access (requires application owner input) | 1 business day |
| Privileged access | 24 business hours |
| New hire provisioning (submitted 5+ days before start) | Ready by first day |
| New hire provisioning (submitted less than 5 days before start) | Best effort, 48 hours max |
| Emergency privileged access (break-glass) | 2 hours with CISO verbal approval |

SLAs apply during business hours (8 AM – 6 PM local time, Monday–Friday). Off-hours requests are queued and processed at start of next business day unless marked as emergency.

---

## Standard Access: Step-by-Step

1. Log into ServiceNow at `servicenow.contoso.internal`.
2. Select "Access Request – Standard" from the Service Catalog.
3. Fill in:
   - Employee name and Contoso email
   - Application(s) requested
   - Business justification (required — "I need access to do my job" is not sufficient)
   - Access level requested (read-only, contributor, admin)
   - Duration (permanent or time-limited with end date)
4. Submit. Your manager receives an approval task automatically.
5. Once approved, IT Operations provisions access within the SLA window.
6. You receive a ServiceNow notification when access is ready.

---

## Privileged Access: Additional Requirements

Privileged access requests require additional documentation:

- Written business justification approved by your manager
- Confirmation that least-privilege principles have been applied (minimum access to perform the role)
- Acknowledgment that activity will be logged and subject to audit
- For production access: confirmation that non-production access is insufficient for the stated need

Privileged accounts are separate from standard accounts. You will receive a dedicated privileged account (e.g., `adm-jsmith@contoso.com`) that must not be used for email, web browsing, or standard business applications.

---

## Offboarding Checklist

When an employee departs, the manager must submit an "Access Removal" ticket no later than the employee's last day. IT Operations targets account disable within 1 hour of the last day end-of-business.

Access removal includes:
- [ ] Disable Active Directory / Entra ID account
- [ ] Revoke all active sessions and MFA registrations
- [ ] Remove from all distribution lists and security groups
- [ ] Disable or transfer corporate email (forward to manager for 30 days)
- [ ] Recover and wipe corporate devices (coordinated with IT Asset Management)
- [ ] Revoke VPN certificates
- [ ] Disable any shared service account credentials known to the employee
- [ ] Transfer or archive files per Data Retention Policy

HR triggers the automated offboarding workflow in Workday, which creates a ServiceNow ticket automatically. Managers must verify completion within 3 business days.

---

## Contacts

- IT Operations Help Desk: `helpdesk@contoso.com` or ext. 5000
- IT Security (privileged access): `itsecurity@contoso.com`
- ServiceNow portal: `servicenow.contoso.internal`
