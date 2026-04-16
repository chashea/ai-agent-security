// guardrails.bicep — RAI policy, blocklist, and blocklist items for Foundry agents.
// Deployed at resource group scope. Assigns the policy to the model deployment.

param accountName string
param policyName string = 'aisec-strict'
param modelDeploymentName string = 'gpt-4o'
param blocklistName string = 'aisec-sensitive-data'

// ── Reference existing Foundry account ──────────────────────────────────────

resource foundryAccount 'Microsoft.CognitiveServices/accounts@2026-01-15-preview' existing = {
  name: accountName
}

// ── Custom Blocklist ────────────────────────────────────────────────────────

resource blocklist 'Microsoft.CognitiveServices/accounts/raiBlocklists@2024-10-01' = {
  parent: foundryAccount
  name: blocklistName
  properties: {
    description: 'Blocks PII patterns (SSN, credit cards, bank accounts) in prompts and completions'
  }
}

resource ssnPattern 'Microsoft.CognitiveServices/accounts/raiBlocklists/raiBlocklistItems@2024-10-01' = {
  parent: blocklist
  name: 'ssn-pattern'
  properties: {
    pattern: '\\b\\d{3}-\\d{2}-\\d{4}\\b'
    isRegex: true
  }
}

resource ccPattern 'Microsoft.CognitiveServices/accounts/raiBlocklists/raiBlocklistItems@2024-10-01' = {
  parent: blocklist
  name: 'credit-card-pattern'
  properties: {
    pattern: '\\b(?:4\\d{3}|5[1-5]\\d{2}|3[47]\\d{2}|6(?:011|5\\d{2}))[-\\s]?\\d{4}[-\\s]?\\d{4}[-\\s]?\\d{3,4}\\b'
    isRegex: true
  }
}

resource bankAccountPattern 'Microsoft.CognitiveServices/accounts/raiBlocklists/raiBlocklistItems@2024-10-01' = {
  parent: blocklist
  name: 'bank-account-keyword'
  properties: {
    pattern: 'my (bank|routing) (account|number) is'
    isRegex: true
  }
}

// ── RAI Policy ──────────────────────────────────────────────────────────────

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

var piiFilters = [
  { name: 'pii', source: 'Prompt', blocking: false, enabled: true }
  { name: 'pii', source: 'Completion', blocking: false, enabled: true }
]

var profanityFilter = [
  { name: 'profanity', source: 'Prompt', blocking: true, enabled: true }
]

resource raiPolicy 'Microsoft.CognitiveServices/accounts/raiPolicies@2024-10-01' = {
  parent: foundryAccount
  name: policyName
  properties: {
    basePolicyName: 'Microsoft.DefaultV2'
    mode: 'Blocking'
    contentFilters: concat(coreFilters, promptProtection, materialProtection, piiFilters, profanityFilter)
    customBlocklists: [
      { blocklistName: blocklistName, blocking: true, source: 'Prompt' }
      { blocklistName: blocklistName, blocking: true, source: 'Completion' }
    ]
  }
  dependsOn: [blocklist]
}

// ── Update model deployment to use the guardrail policy ─────────────────────

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
output blocklistName string = blocklist.name
output modelDeploymentName string = modelDeployment.name
