// guardrails.bicep — RAI policies, blocklists, and blocklist items for Foundry agents.
// Deployed at resource group scope. Assigns the strict policy to the model deployment.
// Additional policies (balanced, permissive) and blocklists (secrets, competitors) are
// created for demo/portal visibility but not bound to any deployment.

param accountName string
param policyName string = 'aisec-strict'
param modelDeploymentName string = 'gpt-4o'
param blocklistName string = 'aisec-sensitive-data'

// ── Reference existing Foundry account ──────────────────────────────────────

resource foundryAccount 'Microsoft.CognitiveServices/accounts@2026-01-15-preview' existing = {
  name: accountName
}

// ── Custom Blocklists ───────────────────────────────────────────────────────

resource blocklist 'Microsoft.CognitiveServices/accounts/raiBlocklists@2024-10-01' = {
  parent: foundryAccount
  name: blocklistName
  properties: {
    description: 'Blocks PII patterns (SSN, credit cards, bank accounts) in prompts and completions'
  }
}

resource secretsBlocklist 'Microsoft.CognitiveServices/accounts/raiBlocklists@2024-10-01' = {
  parent: foundryAccount
  name: 'aisec-secrets-keywords'
  properties: {
    description: 'Blocks credentials, API keys, internal codenames, and infrastructure identifiers'
  }
}

resource competitorBlocklist 'Microsoft.CognitiveServices/accounts/raiBlocklists@2024-10-01' = {
  parent: foundryAccount
  name: 'aisec-competitor-names'
  properties: {
    description: 'Demo blocklist — restricts mentions of competitor brand names in agent responses'
  }
}

// Blocklist items are deployed via ARM REST in FoundryInfra.psm1 to avoid
// ETag race conditions (IfMatchPreconditionFailed) that occur when Bicep
// PUTs multiple items against the same parent blocklist in parallel.

// ── RAI Policies ────────────────────────────────────────────────────────────

var coreFilters = [
  { name: 'hate', source: 'Prompt', severityThreshold: 'Low', blocking: true, enabled: true }
  { name: 'hate', source: 'Completion', severityThreshold: 'Low', blocking: true, enabled: true }
  { name: 'sexual', source: 'Prompt', severityThreshold: 'Low', blocking: true, enabled: true }
  { name: 'sexual', source: 'Completion', severityThreshold: 'Low', blocking: true, enabled: true }
  { name: 'violence', source: 'Prompt', severityThreshold: 'Low', blocking: true, enabled: true }
  { name: 'violence', source: 'Completion', severityThreshold: 'Low', blocking: true, enabled: true }
  { name: 'selfharm', source: 'Prompt', severityThreshold: 'Low', blocking: true, enabled: true }
  { name: 'selfharm', source: 'Completion', severityThreshold: 'Low', blocking: true, enabled: true }
]

var promptProtection = [
  { name: 'jailbreak', source: 'Prompt', blocking: true, enabled: true }
  { name: 'indirect_attack', source: 'Prompt', blocking: true, enabled: true }
]

var materialProtection = [
  { name: 'protected_material_text', source: 'Completion', blocking: true, enabled: true }
  { name: 'protected_material_code', source: 'Completion', blocking: true, enabled: true }
]

var profanityFilter = [
  { name: 'profanity', source: 'Prompt', blocking: true, enabled: true }
]

// Strict — current default, bound to model deployment.
resource raiPolicy 'Microsoft.CognitiveServices/accounts/raiPolicies@2024-10-01' = {
  parent: foundryAccount
  name: policyName
  properties: {
    basePolicyName: 'Microsoft.DefaultV2'
    mode: 'Blocking'
    contentFilters: concat(coreFilters, promptProtection, materialProtection, profanityFilter)
    customBlocklists: [
      { blocklistName: blocklistName, blocking: true, source: 'Prompt' }
      { blocklistName: blocklistName, blocking: true, source: 'Completion' }
    ]
  }
  dependsOn: [blocklist]
}

// Balanced — Medium severity, profanity off, includes secrets blocklist.
// Suitable for IT-Support, Entra, Kusto agents.
var balancedFilters = [
  { name: 'hate', source: 'Prompt', severityThreshold: 'Medium', blocking: true, enabled: true }
  { name: 'hate', source: 'Completion', severityThreshold: 'Medium', blocking: true, enabled: true }
  { name: 'sexual', source: 'Prompt', severityThreshold: 'Medium', blocking: true, enabled: true }
  { name: 'sexual', source: 'Completion', severityThreshold: 'Medium', blocking: true, enabled: true }
  { name: 'violence', source: 'Prompt', severityThreshold: 'Medium', blocking: true, enabled: true }
  { name: 'violence', source: 'Completion', severityThreshold: 'Medium', blocking: true, enabled: true }
  { name: 'selfharm', source: 'Prompt', severityThreshold: 'Low', blocking: true, enabled: true }
  { name: 'selfharm', source: 'Completion', severityThreshold: 'Low', blocking: true, enabled: true }
]

resource raiPolicyBalanced 'Microsoft.CognitiveServices/accounts/raiPolicies@2024-10-01' = {
  parent: foundryAccount
  name: 'aisec-balanced'
  properties: {
    basePolicyName: 'Microsoft.DefaultV2'
    mode: 'Blocking'
    contentFilters: concat(balancedFilters, promptProtection, materialProtection)
    customBlocklists: [
      { blocklistName: 'aisec-secrets-keywords', blocking: true, source: 'Prompt' }
      { blocklistName: 'aisec-secrets-keywords', blocking: true, source: 'Completion' }
    ]
  }
  dependsOn: [secretsBlocklist]
}

// Permissive — High severity, only block jailbreak + selfharm + secrets.
// Suitable for creative/research agents (e.g. Sales-Research).
var permissiveFilters = [
  { name: 'hate', source: 'Prompt', severityThreshold: 'High', blocking: true, enabled: true }
  { name: 'hate', source: 'Completion', severityThreshold: 'High', blocking: true, enabled: true }
  { name: 'sexual', source: 'Prompt', severityThreshold: 'High', blocking: true, enabled: true }
  { name: 'sexual', source: 'Completion', severityThreshold: 'High', blocking: true, enabled: true }
  { name: 'violence', source: 'Prompt', severityThreshold: 'High', blocking: true, enabled: true }
  { name: 'violence', source: 'Completion', severityThreshold: 'High', blocking: true, enabled: true }
  { name: 'selfharm', source: 'Prompt', severityThreshold: 'Medium', blocking: true, enabled: true }
  { name: 'selfharm', source: 'Completion', severityThreshold: 'Medium', blocking: true, enabled: true }
]

var permissivePromptProtection = [
  { name: 'jailbreak', source: 'Prompt', blocking: true, enabled: true }
]

resource raiPolicyPermissive 'Microsoft.CognitiveServices/accounts/raiPolicies@2024-10-01' = {
  parent: foundryAccount
  name: 'aisec-permissive'
  properties: {
    basePolicyName: 'Microsoft.DefaultV2'
    mode: 'Blocking'
    contentFilters: concat(permissiveFilters, permissivePromptProtection)
    customBlocklists: [
      { blocklistName: 'aisec-competitor-names', blocking: false, source: 'Completion' }
    ]
  }
  dependsOn: [competitorBlocklist]
}

// ── Update model deployment to use the strict guardrail policy ──────────────

resource modelDeployment 'Microsoft.CognitiveServices/accounts/deployments@2026-01-15-preview' = {
  parent: foundryAccount
  name: modelDeploymentName
  sku: {
    name: 'GlobalStandard'
    capacity: 10
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: 'gpt-4o'
      version: '2024-11-20'
    }
    raiPolicyName: policyName
  }
  dependsOn: [raiPolicy]
}

// ── Outputs ─────────────────────────────────────────────────────────────────

output raiPolicyName string = raiPolicy.name
output raiPolicyBalancedName string = raiPolicyBalanced.name
output raiPolicyPermissiveName string = raiPolicyPermissive.name
output blocklistName string = blocklist.name
output secretsBlocklistName string = secretsBlocklist.name
output competitorBlocklistName string = competitorBlocklist.name
output modelDeploymentName string = modelDeployment.name
