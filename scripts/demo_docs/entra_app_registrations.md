# Entra App Registrations

Quick reference for creating and configuring app registrations in Microsoft Entra ID for OAuth 2.0 / OpenID Connect authentication.

## Single-tenant vs multi-tenant

| Audience | `signInAudience` | Who can sign in |
|---|---|---|
| Single-tenant | `AzureADMyOrg` | Users from your tenant only |
| Multi-tenant (work/school) | `AzureADMultipleOrgs` | Users from any Entra tenant |
| Multi-tenant + personal | `AzureADandPersonalMicrosoftAccount` | Any Entra user + MSA |
| Personal only | `PersonalMicrosoftAccount` | Consumer MSA only |

Pick `AzureADMyOrg` by default. Multi-tenant requires tenant admin consent in each target tenant.

## Delegated vs application permissions

| Type | Acting on behalf of | Example |
|---|---|---|
| **Delegated** | Signed-in user | `User.Read` → reads the *user's own* profile |
| **Application** | The app itself (no user) | `User.Read.All` → reads *any* user, app-only |

- Delegated perms require a user flow (auth code / device code)
- Application perms require client credentials flow (secret or cert) + admin consent
- A single app registration can hold both types — `az ad app permission list` shows them separately

## OAuth flows

### Authorization code + PKCE (SPA, mobile)

- Redirect URI registered as "Single-page application"
- No client secret (public client)
- PKCE is mandatory for public clients
- Token obtained from the browser, passed to the backend for validation

### Client credentials (daemon / service-to-service)

```bash
curl -X POST https://login.microsoftonline.com/{tenant}/oauth2/v2.0/token \
  -d "client_id={appId}" \
  -d "client_secret={secret}" \
  -d "grant_type=client_credentials" \
  -d "scope=https://graph.microsoft.com/.default"
```

- Requires application permissions + admin consent
- Token is app-only (no user context)
- Use managed identity instead of client secrets whenever possible (e.g., inside Azure Functions, App Service, AKS, VM)

### Device code (CLI, IoT)

- User opens `https://microsoft.com/devicelogin` and types a code
- Your app polls the token endpoint until the user completes sign-in
- Useful for headless / non-TTY shells where a browser redirect is not available

## Redirect URIs

- Must be exact matches — `https://app.example.com/callback` ≠ `https://app.example.com/callback/`
- Wildcards are not supported (except `localhost` with any port for development)
- HTTPS required except for `http://localhost`
- Mobile apps use custom schemes like `msauth://{bundle-id}/{hash}`

## Secrets vs certificates

| Mechanism | Max lifetime | Rotation | Notes |
|---|---|---|---|
| Client secret | 2 years | Manual | Easy to leak; avoid in code |
| Certificate | Up to 10 years | Manual | Preferred for service principals |
| Federated credential (OIDC) | N/A | No secrets | Use for GitHub Actions, Azure DevOps, AKS workload identity |

GitHub Actions OIDC federation is the gold standard for CI/CD — no secrets stored anywhere:

```yaml
- uses: azure/login@v1
  with:
    client-id: ${{ secrets.AZURE_CLIENT_ID }}
    tenant-id: ${{ secrets.AZURE_TENANT_ID }}
    subscription-id: ${{ secrets.AZURE_SUBSCRIPTION_ID }}
```

## Common errors

| Error | Cause | Fix |
|---|---|---|
| `AADSTS50011: redirect URI mismatch` | Exact-match failure | Register the exact URI the app is sending |
| `AADSTS65001: user has not consented` | App needs admin consent | Admin grants consent via portal or `/adminconsent` endpoint |
| `AADSTS700016: application not found` | Wrong tenant | Check tenant id in the authority URL |
| `AADSTS700027: signing key not found` | Stale client assertion cert | Rotate the cert and redeploy |
| `AADSTS54005: auth code already used` | Replay attack / double submit | One-time use; exchange immediately for tokens |
