# Graph Auth — Managed Identity to Microsoft Graph

PowerShell scripts for authenticating Azure Managed Identities to the Microsoft Graph API. Works with any Azure compute resource (Function App, VM, Container App, App Service).

## What's Included

| Script | Purpose |
|--------|---------|
| `Setup-GraphPermissions.ps1` | Grants Graph API application permissions to a Managed Identity |
| `Connect-GraphWithManagedIdentity.ps1` | Reusable connection helper (dot-source or call directly) |
| `Test-GraphConnection.ps1` | Validates each permission with a sample Graph call |

## Prerequisites

1. **PowerShell 7+** with the Microsoft Graph PowerShell SDK:

   ```powershell
   Install-Module Microsoft.Graph -Scope CurrentUser
   ```

2. **Azure resource with a Managed Identity** — system-assigned or user-assigned.

3. **Admin permissions** — the account running `Setup-GraphPermissions.ps1` must be **Global Administrator** or **Privileged Role Administrator** to grant application permissions.

4. **For local development** — use `az login` or `Connect-MgGraph` interactively. The Managed Identity scripts only work on Azure compute.

## Permissions Reference

| Permission | Type | Use Case |
|-----------|------|----------|
| `User.Read.All` | Application | Read user profiles and directory info |
| `Mail.Send` | Application | Send emails on behalf of any user |
| `Group.ReadWrite.All` | Application | Create, read, update, delete groups |
| `AuditLog.Read.All` | Application | Read Entra ID audit and sign-in logs |
| `Directory.Read.All` | Application | Read directory objects (domains, roles, etc.) |

## Setup Instructions

### 1. Find Your Managed Identity Object ID

The Object ID is the **Enterprise Application (service principal)** ID in Entra ID, not the resource's ARM resource ID.

**Azure Portal:**
- Go to **Entra ID → Enterprise Applications** → search for your resource name → copy the **Object ID**.

**Azure CLI:**

```bash
# System-assigned identity — use the resource's principal ID
az webapp identity show --name <app-name> --resource-group <rg> --query principalId -o tsv
az functionapp identity show --name <app-name> --resource-group <rg> --query principalId -o tsv
az vm identity show --name <vm-name> --resource-group <rg> --query principalId -o tsv
az containerapp identity show --name <app-name> --resource-group <rg> --query principalId -o tsv

# User-assigned identity — look up the service principal for the identity's client ID
az identity show --name <identity-name> --resource-group <rg> --query clientId -o tsv
# Then find the service principal:
az ad sp show --id <client-id> --query id -o tsv
```

### 2. Grant Graph Permissions (Run from Your Workstation)

```powershell
# This runs interactively — you'll sign in as an admin
.\Setup-GraphPermissions.ps1 -ManagedIdentityObjectId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"

# Preview without making changes
.\Setup-GraphPermissions.ps1 -ManagedIdentityObjectId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" -WhatIf

# Explicit tenant
.\Setup-GraphPermissions.ps1 -ManagedIdentityObjectId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" -TenantId "yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy"
```

### 3. Connect from Azure (Run on the Azure Resource)

```powershell
# System-assigned identity
.\Connect-GraphWithManagedIdentity.ps1

# User-assigned identity
.\Connect-GraphWithManagedIdentity.ps1 -ClientId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"

# Dot-source to keep the connection in your session
. .\Connect-GraphWithManagedIdentity.ps1
```

### 4. Validate Permissions

```powershell
.\Test-GraphConnection.ps1
```

Expected output:

```
  [PASS] User.Read.All — Read user profiles
  [PASS] Group.ReadWrite.All — Read/write groups
  [PASS] AuditLog.Read.All — Read audit logs
  [PASS] Directory.Read.All — Read directory objects
  [PASS] Mail.Send — Send mail (permission check only)
```

## Usage Examples

After connecting with `Connect-GraphWithManagedIdentity.ps1`:

```powershell
# Read user profiles
Get-MgUser -Filter "department eq 'Engineering'" -Property DisplayName, Mail, JobTitle

# Send an email
$message = @{
    Subject      = "Automated Report"
    Body         = @{ ContentType = "HTML"; Content = "<h1>Report</h1><p>Details here.</p>" }
    ToRecipients = @(@{ EmailAddress = @{ Address = "recipient@contoso.com" } })
}
Send-MgUserMail -UserId "sender@contoso.com" -Message $message

# List groups
Get-MgGroup -Filter "startswith(displayName, 'SG-')" -Property DisplayName, Id, Description

# Pull audit logs
Get-MgAuditLogDirectoryAudit -Top 50 -Filter "activityDisplayName eq 'Add member to group'"
```

## Troubleshooting

| Problem | Fix |
|---------|-----|
| `Connect-MgGraph -Identity` fails | Verify the resource has a Managed Identity enabled and the Microsoft.Graph module is installed |
| Permission tests fail | Re-run `Setup-GraphPermissions.ps1` and check the summary table for errors |
| `Insufficient privileges` on Graph calls | Confirm the Object ID used in setup matches the identity running the script |
| Mail.Send test shows FAIL | The test checks the role assignment — ensure the setup script assigned it successfully |
