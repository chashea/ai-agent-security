# Entra Conditional Access Patterns

Reference for building Conditional Access (CA) policies that cover the common enterprise threats without locking users out.

## Policy structure

Every CA policy has three blocks:

1. **Assignments** — users/groups, cloud apps, conditions (sign-in risk, location, device, client app, platforms)
2. **Access controls** — grant (MFA, compliant device, approved app, ToU, password change) or block
3. **Session** — app-enforced restrictions, MCAS (CAAC), sign-in frequency, persistent browser

Policies are evaluated together and the most restrictive set of controls wins.

## Baseline set

Start with these four; add more as needed.

### 1. Require MFA for admins

- **Users**: Directory role = all privileged roles (include the built-in admin roles)
- **Apps**: All cloud apps
- **Conditions**: none
- **Grant**: Require MFA
- **State**: On

### 2. Block legacy authentication

- **Users**: All users
- **Apps**: All cloud apps
- **Conditions**: Client apps = "Exchange ActiveSync" + "Other clients"
- **Grant**: Block
- **State**: On

Legacy auth bypasses MFA. Blocking it is the single highest-leverage policy you can turn on.

### 3. Require compliant device for M365

- **Users**: All users (exclude break-glass)
- **Apps**: Office 365
- **Conditions**: none
- **Grant**: Require Hybrid Azure AD joined device **or** Require device to be marked compliant
- **State**: On (after Intune enrollment is rolled out)

### 4. Risk-based sign-in

- **Users**: All users (exclude break-glass)
- **Apps**: All cloud apps
- **Conditions**: Sign-in risk = High
- **Grant**: Block
- **State**: On (or report-only during rollout)

Also create a Medium-risk policy that requires MFA + password change.

## Break-glass pattern

- Create 2 cloud-only accounts (no MFA, no Conditional Access exclusions)
- Store credentials in a physical safe
- Exclude these accounts from **every** CA policy
- Monitor sign-ins via `SigninLogs` alerts on break-glass UPNs
- Rotate credentials quarterly

## Common pitfalls

1. **Forgetting to exclude break-glass from the "require MFA for everyone" policy.** Classic lockout.
2. **Scoping to Office 365 but applying session controls that need MCAS.** Session control requires "All cloud apps" or a specific preview-listed app.
3. **Using Named Locations instead of IP-based blocks.** Named Locations are authoritative — "trusted locations" means *nothing else* is trusted.
4. **Report-only persistence.** Leaving a policy in report-only "for safety" forever means it never protects anything. Set a cutover date.
5. **Group nesting.** CA does not expand nested groups for exclusions. Use a flat exclusion group.

## Report-only mode

Every new CA policy should land in report-only for 7–14 days before enforcement. Query:

```kql
SigninLogs
| where TimeGenerated > ago(7d)
| mv-expand ConditionalAccessPolicies
| extend PolicyId = tostring(ConditionalAccessPolicies.id)
| extend PolicyState = tostring(ConditionalAccessPolicies.result)
| where PolicyId == "<policy-guid>"
| summarize count() by PolicyState
```

Expect: `reportOnlySuccess` >> `reportOnlyFailure`. If `reportOnlyFailure` is non-zero, investigate before flipping the policy on.

## Session control: MDCA (CAAC)

Conditional Access App Control lets you route a session through Defender for Cloud Apps to enforce:
- Block download / print / copy
- Monitor only (surfaces to Defender portal)
- Block uploads of labeled content

Enabling requires the policy's Session → Use Conditional Access App Control → Monitor only (preview) OR Block downloads (preview).
