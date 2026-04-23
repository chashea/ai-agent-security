// foundry-guardrail-violation-fixtures.bicep
//
// Intentionally weak model deployments bound to permissive RAI policies so
// the per-risk guardrail assignments in
// `infra/foundry-guardrail-per-risk.bicep` have something non-compliant to
// flag during Azure Policy scans.
//
// The built-in policy set `5207647b-...` evaluates
// Microsoft.CognitiveServices.Data/accounts/deployments — it looks at the
// contentFilters on the raiPolicy attached to each deployment. Merely
// creating a weak raiPolicies child resource does NOT trip the policies;
// a DEPLOYMENT bound to it does.
//
// Cost note: each deployment draws TPM quota from the Foundry account.
// Capacity 1 GlobalStandard on gpt-4o is the minimum. Delete after the
// demo.
//
// Deployed at resource-group scope (the Foundry account's RG).

targetScope = 'resourceGroup'

@description('Foundry account name (Microsoft.CognitiveServices/accounts).')
param accountName string = 'aisec-foundry'

@description('Weak RAI policy to bind to the demo deployment. Must already exist on the account. `aisec-permissive` (from guardrails.bicep) has severity High on hate/sexual/violence, no indirect_attack, no protected_material, no profanity — trips multiple per-risk policies.')
param weakRaiPolicyName string = 'aisec-permissive'

@description('Partial-coverage RAI policy to bind to the 2nd demo deployment. `aisec-balanced` (from guardrails.bicep) uses severity Medium on hate/sexual/violence and has no profanity filter — trips those per-risk policies.')
param partialRaiPolicyName string = 'aisec-balanced'

@description('Model deployment name for the weak fixture.')
param weakDeploymentName string = 'gpt-4o-demo-weak'

@description('Model deployment name for the partial fixture.')
param partialDeploymentName string = 'gpt-4o-demo-partial'

@description('Minimum TPM capacity (GlobalStandard SKU units, thousands/min). Keep low since these are compliance fixtures not serving traffic.')
param capacity int = 1

resource account 'Microsoft.CognitiveServices/accounts@2026-01-15-preview' existing = {
  name: accountName
}

// ── Weak fixture: permissive policy bound to a GPT-4o deployment ────────────
// Expected per-risk violations triggered:
//   hate, sexual, violence (severity High ≠ Low)
//   indirect-attack (missing)
//   protected-material-text, protected-material-code (missing)
//   profanity (missing)
//   spotlighting (missing)

resource weakDeployment 'Microsoft.CognitiveServices/accounts/deployments@2026-01-15-preview' = {
  parent: account
  name: weakDeploymentName
  sku: {
    name: 'GlobalStandard'
    capacity: capacity
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: 'gpt-4o'
      version: '2024-11-20'
    }
    raiPolicyName: weakRaiPolicyName
  }
}

// ── Partial fixture: balanced policy bound to a second deployment ───────────
// Expected per-risk violations triggered:
//   hate, sexual, violence (severity Medium ≠ Low)
//   profanity (missing)
//   spotlighting (missing)

resource partialDeployment 'Microsoft.CognitiveServices/accounts/deployments@2026-01-15-preview' = {
  parent: account
  name: partialDeploymentName
  sku: {
    name: 'GlobalStandard'
    capacity: capacity
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: 'gpt-4o'
      version: '2024-11-20'
    }
    raiPolicyName: partialRaiPolicyName
  }
  dependsOn: [weakDeployment]
}

output weakDeploymentId string = weakDeployment.id
output partialDeploymentId string = partialDeployment.id
output weakDeploymentName string = weakDeployment.name
output partialDeploymentName string = partialDeployment.name
