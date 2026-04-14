# Entra + Azure RBAC Model

A quick reference for the two distinct role systems in Microsoft Entra ID and Azure, and how they intersect.

## Two role systems, one tenant

| System | What it governs | Assignment surface |
|---|---|---|
| **Entra directory roles** | Entra tenant objects: users, groups, apps, policies, licenses | `graph.microsoft.com/roleManagement/directory` |
| **Azure RBAC** | Azure resources: subscriptions, resource groups, storage accounts, vms, etc. | `management.azure.com` ARM scope |

They do **not** imply each other. A Global Administrator in Entra does not automatically get Owner on Azure subscriptions (but can elevate via `/providers/Microsoft.Authorization/elevateAccess`).

## Azure RBAC scope hierarchy

```
Management Group
  └── Subscription
        └── Resource Group
              └── Resource
```

Assignments inherit downward. Grant at the smallest scope that still works.

## Common Azure built-in roles

| Role | GUID | What it does |
|---|---|---|
| Owner | `8e3af657-a8ff-443c-a75c-2fe8c4bcb635` | Full control + delegate |
| Contributor | `b24988ac-6180-42a0-ab88-20f7382dd24c` | Full control, no delegate |
| Reader | `acdd72a7-3385-48ef-bd42-f606fba81ae7` | Read-only |
| Storage Blob Data Reader | `2a2b9908-6ea1-4ae2-8e65-a410df84e7d1` | Read blobs via data plane |
| Storage Blob Data Contributor | `ba92f5b4-2d11-453d-a403-e96b0029c9fe` | Read + write blobs |
| Key Vault Secrets User | `4633458b-17de-408a-b874-0445c86b69e6` | Read secrets via data plane |
| AcrPull | `7f951dda-4ed3-4680-a7ca-43fe172d538d` | Pull images from ACR |

Full list: `az role definition list --output table`.

## Common Entra directory roles

| Role | Scope | Notes |
|---|---|---|
| Global Administrator | Tenant | Break-glass only; enable MFA + PIM |
| Privileged Role Administrator | Tenant | Manage other role assignments |
| Application Administrator | Tenant | Create/manage app registrations |
| User Administrator | Tenant | Create/manage users and groups |
| Conditional Access Administrator | Tenant | Author CA policies |
| Security Administrator | Tenant | Defender, Sentinel, Secure Score |

## Least-privilege patterns

1. **Grant built-in over custom.** Custom roles require you to maintain the actionlist.
2. **Scope to the resource group, not the subscription.** Easier to revoke.
3. **Use PIM for privileged roles.** Eligible → activation with MFA + approval.
4. **Use managed identities for compute.** Avoid service principal secrets.
5. **Avoid Contributor when Data plane roles exist.** For blob/keyvault/cosmos, the data-plane role is usually what you want.

## Assignment via CLI

```bash
# Role assignment at resource group scope
az role assignment create \
  --assignee <objectId-or-upn> \
  --role "Storage Blob Data Reader" \
  --scope "/subscriptions/<subId>/resourceGroups/<rgName>"

# Elevate (Global Admin) to manage all subs
az rest --method POST \
  --uri "/providers/Microsoft.Authorization/elevateAccess?api-version=2016-07-01"
```

## Assignment via Bicep

```bicep
resource blobReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, principalId, 'blob-reader')
  scope: resourceGroup()
  properties: {
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1'
    )
    principalId: principalId
    principalType: 'ServicePrincipal'
  }
}
```

Use `guid()` for a deterministic name so redeploys are idempotent.
