# Contoso Pricing Guide

**Last Updated: 2026-01-15**
**Classification: Internal**
**Owner: Revenue Operations**

---

## Overview

This guide covers Contoso's current pricing structure, discount authority matrix, and add-on pricing. Use this as the authoritative reference when building quotes. All quotes must be generated in Salesforce CPQ. Do not share list pricing with prospects without a signed NDA or equivalent mutual confidentiality agreement.

---

## Core Pricing Tiers

### Starter — $25/user/month (billed annually) / $30/user/month (billed monthly)

Designed for teams of up to 50 users getting started with workflow automation.

Includes:
- Core workflow builder with up to 20 active workflows
- Standard integrations (M365, Google Workspace, Slack)
- 5 GB document storage per workspace
- Email support (48-hour SLA)
- SOC 2 Type II compliance

Minimum: 10 users. No phone or chat support.

---

### Professional — $65/user/month (billed annually) / $78/user/month (billed monthly)

Designed for growing organizations requiring advanced automation, compliance, and API access.

Includes everything in Starter, plus:
- Unlimited active workflows
- Advanced integrations (Salesforce, SAP, Oracle, Workday, 150+ connectors)
- Full REST API access with standard rate limits (1,000 req/min)
- 50 GB document storage per workspace
- Audit log and compliance reporting (SOX, GDPR, HIPAA)
- Chat and email support (8-hour SLA)
- SSO (SAML 2.0, OIDC)

Minimum: 25 users.

---

### Enterprise — Custom pricing

Designed for large organizations with complex requirements, multi-entity structures, or regulated industry needs.

Includes everything in Professional, plus:
- Unlimited document storage
- Dedicated infrastructure (single-tenant option available)
- Custom rate limits and SLA guarantees
- Advanced data residency controls (US, EU, APAC)
- Role-based access control with custom permission models
- Custom integrations and professional services
- 24/7 phone, chat, and email support (1-hour SEV1 SLA)
- Customer Success Manager (CSM) assigned
- Executive Business Review (EBR) program
- FedRAMP Moderate (available on dedicated US Gov instance)

Minimum: 100 users. All Enterprise deals require VP of Sales approval.

---

## Volume Discounts (Professional and Enterprise)

| User Count | Discount Off List |
|---|---|
| 1 – 99 | 0% |
| 100 – 249 | 10% |
| 250 – 499 | 15% |
| 500 – 999 | 20% |
| 1,000 – 2,499 | 25% |
| 2,500+ | Negotiated (requires RevOps involvement) |

Volume discounts apply to the per-user license fee only. Add-ons are priced separately.

---

## Annual vs. Monthly Billing

| Term | Discount vs. Monthly |
|---|---|
| Month-to-month | 0% (list) |
| Annual, paid monthly | 10% |
| Annual, paid upfront | 17% |
| 2-year, paid upfront | 25% |
| 3-year, paid upfront | 32% |

Multi-year deals above $500K ACV require VP of Sales sign-off. Finance approval required for any deal with payment terms beyond Net 30.

---

## Add-On Pricing

| Add-On | Price | Notes |
|---|---|---|
| Advanced Analytics Module | $12/user/month | Requires Professional or Enterprise |
| AI Workflow Assistant | $18/user/month | Requires Professional or Enterprise |
| eSignature (up to 500 envelopes/mo) | $250/month flat | |
| eSignature (up to 5,000 envelopes/mo) | $1,500/month flat | |
| Additional Storage (100 GB blocks) | $50/month per block | |
| API Rate Limit Increase (10x) | $800/month | Enterprise only |
| Data Residency (EU or APAC) | $8/user/month | Enterprise only |
| Dedicated Onboarding Package | $5,000 one-time | Includes 3 sessions, 30 days |
| Premium Onboarding Package | $15,000 one-time | Includes 8 sessions, 90 days, custom templates |

---

## Discount Approval Matrix

Account Executives may offer discounts within their authority. Requests exceeding AE authority must be submitted in Salesforce CPQ with a business justification before a quote is sent.

| Discount Level | Who Can Approve |
|---|---|
| Up to 10% | AE (self-approve) |
| 11% – 20% | Sales Manager |
| 21% – 30% | VP of Sales |
| 31% – 40% | CRO |
| Above 40% | CRO + CFO (rare; strategic deals only) |

Note: Volume discounts and term discounts stack with discretionary discounts. Total effective discount against list price must not exceed 50% without CFO approval.

---

## Non-Standard Terms

The following require Legal review before inclusion in a quote or order form:

- Payment terms beyond Net 30
- Service credits exceeding 10% of monthly fees
- Custom DPA or data processing terms
- Unlimited liability caps
- Source code escrow requests

Submit non-standard term requests to `legal@contoso.com` with the deal opportunity ID at least 5 business days before expected signature.

---

## Contacts

- Revenue Operations: `revops@contoso.com`
- Deal Desk: `dealdesk@contoso.com`
- Legal: `legal@contoso.com`
- Salesforce CPQ access issues: `salesforce-support@contoso.com`
