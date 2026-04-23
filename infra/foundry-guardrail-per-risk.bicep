// foundry-guardrail-per-risk.bicep
//
// Per-risk assignments of Microsoft's built-in guardrail initiative
// `[Preview]: Guardrail for Cognitive Services Deployments`
// (policySetDefinitions/5207647b-3e83-4e28-b836-c382cb5e2a2e).
//
// The Foundry portal's "Create policy" wizard (Operate → Compliance →
// Policies → Create) writes one assignment of this built-in per submission,
// using the user-entered name. A policy named "jailbreak" tightens
// allowedJailbreakEnabled/Blocking to ["true"] and leaves every other
// risk permissive.
//
// This bicep replicates that shape, producing one named row per risk in
// Foundry → Operate → Compliance → Policies so the list shows jailbreak
// alongside hate, sexual, violence, self-harm, indirect-attack,
// protected-material-text, protected-material-code, profanity, and
// spotlighting.
//
// Deployed at subscription scope.

targetScope = 'subscription'

@description('Optional name prefix for the generated assignments. Foundry displays `<prefix>-<risk>` unless overridden.')
param namePrefix string = 'aisec-guardrail'

@description('Policy set (initiative) ID to assign per risk. Defaults to the built-in preview guardrail.')
param guardrailInitiativeId string = '/providers/Microsoft.Authorization/policySetDefinitions/5207647b-3e83-4e28-b836-c382cb5e2a2e'

@description('Policy definition version pin. Matches the value the Foundry portal writes.')
param definitionVersion string = '1.*.*-PREVIEW'

var allBools = ['true', 'false']
var allSeverities = ['Low', 'Medium', 'High']
var allModes = ['Default', 'Asynchronous_filter']

// Permissive defaults for every risk. Each per-risk assignment overrides
// only the risk it enforces.
var permissiveBase = {
  allowedHateBlockingForCompletion: { value: allBools }
  allowedHateBlockingForPrompt: { value: allBools }
  allowedHateEnabledForCompletion: { value: allBools }
  allowedHateEnabledForPrompt: { value: allBools }
  allowedHateSeveritiesForCompletion: { value: allSeverities }
  allowedHateSeveritiesForPrompt: { value: allSeverities }
  allowedIndirectAttackBlockingForPrompt: { value: allBools }
  allowedIndirectAttackEnabledForPrompt: { value: allBools }
  allowedJailbreakBlockingForPrompt: { value: allBools }
  allowedJailbreakEnabledForPrompt: { value: allBools }
  allowedProfanityBlockingForCompletion: { value: allBools }
  allowedProfanityBlockingForPrompt: { value: allBools }
  allowedProfanityEnabledForCompletion: { value: allBools }
  allowedProfanityEnabledForPrompt: { value: allBools }
  allowedProtectedMaterialCodeBlockingForCompletion: { value: allBools }
  allowedProtectedMaterialCodeEnabledForCompletion: { value: allBools }
  allowedProtectedMaterialTextBlockingForCompletion: { value: allBools }
  allowedProtectedMaterialTextEnabledForCompletion: { value: allBools }
  allowedSelfharmBlockingForCompletion: { value: allBools }
  allowedSelfharmBlockingForPrompt: { value: allBools }
  allowedSelfharmEnabledForCompletion: { value: allBools }
  allowedSelfharmEnabledForPrompt: { value: allBools }
  allowedSelfharmSeveritiesForCompletion: { value: allSeverities }
  allowedSelfharmSeveritiesForPrompt: { value: allSeverities }
  allowedSexualBlockingForCompletion: { value: allBools }
  allowedSexualBlockingForPrompt: { value: allBools }
  allowedSexualEnabledForCompletion: { value: allBools }
  allowedSexualEnabledForPrompt: { value: allBools }
  allowedSexualSeveritiesForCompletion: { value: allSeverities }
  allowedSexualSeveritiesForPrompt: { value: allSeverities }
  allowedSpotlightingBlockingForPrompt: { value: allBools }
  allowedSpotlightingEnabledForPrompt: { value: allBools }
  allowedViolenceBlockingForCompletion: { value: allBools }
  allowedViolenceBlockingForPrompt: { value: allBools }
  allowedViolenceEnabledForCompletion: { value: allBools }
  allowedViolenceEnabledForPrompt: { value: allBools }
  allowedViolenceSeveritiesForCompletion: { value: allSeverities }
  allowedViolenceSeveritiesForPrompt: { value: allSeverities }
  raiPolicyMode: { value: allModes }
}

// ── Per-risk assignments ────────────────────────────────────────────────────

resource indirectAttack 'Microsoft.Authorization/policyAssignments@2023-04-01' = {
  name: '${namePrefix}-indirect-attack'
  properties: {
    displayName: 'indirect-attack'
    description: 'Enforces Prompt Shields indirect-attack (XPIA) protection: model deployments must keep indirect_attack enabled and blocking on Prompt.'
    policyDefinitionId: guardrailInitiativeId
    definitionVersion: definitionVersion
    enforcementMode: 'Default'
    parameters: union(permissiveBase, {
      allowedIndirectAttackEnabledForPrompt: { value: ['true'] }
      allowedIndirectAttackBlockingForPrompt: { value: ['true'] }
    })
  }
}

resource hate 'Microsoft.Authorization/policyAssignments@2023-04-01' = {
  name: '${namePrefix}-hate'
  properties: {
    displayName: 'hate'
    description: 'Enforces hate-content filtering at severity Low (blocking) on both Prompt and Completion.'
    policyDefinitionId: guardrailInitiativeId
    definitionVersion: definitionVersion
    enforcementMode: 'Default'
    parameters: union(permissiveBase, {
      allowedHateEnabledForPrompt: { value: ['true'] }
      allowedHateEnabledForCompletion: { value: ['true'] }
      allowedHateBlockingForPrompt: { value: ['true'] }
      allowedHateBlockingForCompletion: { value: ['true'] }
      allowedHateSeveritiesForPrompt: { value: ['Low'] }
      allowedHateSeveritiesForCompletion: { value: ['Low'] }
    })
  }
}

resource sexual 'Microsoft.Authorization/policyAssignments@2023-04-01' = {
  name: '${namePrefix}-sexual'
  properties: {
    displayName: 'sexual'
    description: 'Enforces sexual-content filtering at severity Low (blocking) on both Prompt and Completion.'
    policyDefinitionId: guardrailInitiativeId
    definitionVersion: definitionVersion
    enforcementMode: 'Default'
    parameters: union(permissiveBase, {
      allowedSexualEnabledForPrompt: { value: ['true'] }
      allowedSexualEnabledForCompletion: { value: ['true'] }
      allowedSexualBlockingForPrompt: { value: ['true'] }
      allowedSexualBlockingForCompletion: { value: ['true'] }
      allowedSexualSeveritiesForPrompt: { value: ['Low'] }
      allowedSexualSeveritiesForCompletion: { value: ['Low'] }
    })
  }
}

resource violence 'Microsoft.Authorization/policyAssignments@2023-04-01' = {
  name: '${namePrefix}-violence'
  properties: {
    displayName: 'violence'
    description: 'Enforces violence-content filtering at severity Low (blocking) on both Prompt and Completion.'
    policyDefinitionId: guardrailInitiativeId
    definitionVersion: definitionVersion
    enforcementMode: 'Default'
    parameters: union(permissiveBase, {
      allowedViolenceEnabledForPrompt: { value: ['true'] }
      allowedViolenceEnabledForCompletion: { value: ['true'] }
      allowedViolenceBlockingForPrompt: { value: ['true'] }
      allowedViolenceBlockingForCompletion: { value: ['true'] }
      allowedViolenceSeveritiesForPrompt: { value: ['Low'] }
      allowedViolenceSeveritiesForCompletion: { value: ['Low'] }
    })
  }
}

resource selfharm 'Microsoft.Authorization/policyAssignments@2023-04-01' = {
  name: '${namePrefix}-self-harm'
  properties: {
    displayName: 'self-harm'
    description: 'Enforces self-harm content filtering at severity Low (blocking) on both Prompt and Completion.'
    policyDefinitionId: guardrailInitiativeId
    definitionVersion: definitionVersion
    enforcementMode: 'Default'
    parameters: union(permissiveBase, {
      allowedSelfharmEnabledForPrompt: { value: ['true'] }
      allowedSelfharmEnabledForCompletion: { value: ['true'] }
      allowedSelfharmBlockingForPrompt: { value: ['true'] }
      allowedSelfharmBlockingForCompletion: { value: ['true'] }
      allowedSelfharmSeveritiesForPrompt: { value: ['Low'] }
      allowedSelfharmSeveritiesForCompletion: { value: ['Low'] }
    })
  }
}

resource profanity 'Microsoft.Authorization/policyAssignments@2023-04-01' = {
  name: '${namePrefix}-profanity'
  properties: {
    displayName: 'profanity'
    description: 'Enforces profanity filtering (blocking) on both Prompt and Completion.'
    policyDefinitionId: guardrailInitiativeId
    definitionVersion: definitionVersion
    enforcementMode: 'Default'
    parameters: union(permissiveBase, {
      allowedProfanityEnabledForPrompt: { value: ['true'] }
      allowedProfanityEnabledForCompletion: { value: ['true'] }
      allowedProfanityBlockingForPrompt: { value: ['true'] }
      allowedProfanityBlockingForCompletion: { value: ['true'] }
    })
  }
}

resource protectedMaterialText 'Microsoft.Authorization/policyAssignments@2023-04-01' = {
  name: '${namePrefix}-protected-material-text'
  properties: {
    displayName: 'protected-material-text'
    description: 'Enforces protected-material-text filtering (blocking) on Completion. Catches copyrighted lyrics/articles regurgitation.'
    policyDefinitionId: guardrailInitiativeId
    definitionVersion: definitionVersion
    enforcementMode: 'Default'
    parameters: union(permissiveBase, {
      allowedProtectedMaterialTextEnabledForCompletion: { value: ['true'] }
      allowedProtectedMaterialTextBlockingForCompletion: { value: ['true'] }
    })
  }
}

resource protectedMaterialCode 'Microsoft.Authorization/policyAssignments@2023-04-01' = {
  name: '${namePrefix}-protected-material-code'
  properties: {
    displayName: 'protected-material-code'
    description: 'Enforces protected-material-code filtering (blocking) on Completion. Catches licensed source-code regurgitation.'
    policyDefinitionId: guardrailInitiativeId
    definitionVersion: definitionVersion
    enforcementMode: 'Default'
    parameters: union(permissiveBase, {
      allowedProtectedMaterialCodeEnabledForCompletion: { value: ['true'] }
      allowedProtectedMaterialCodeBlockingForCompletion: { value: ['true'] }
    })
  }
}

resource spotlighting 'Microsoft.Authorization/policyAssignments@2023-04-01' = {
  name: '${namePrefix}-spotlighting'
  properties: {
    displayName: 'spotlighting'
    description: 'Enforces spotlighting (indirect-attack delimitation marking) on Prompt. Required when grounding docs are injected into the prompt.'
    policyDefinitionId: guardrailInitiativeId
    definitionVersion: definitionVersion
    enforcementMode: 'Default'
    parameters: union(permissiveBase, {
      allowedSpotlightingEnabledForPrompt: { value: ['true'] }
      allowedSpotlightingBlockingForPrompt: { value: ['true'] }
    })
  }
}

// ── Outputs ─────────────────────────────────────────────────────────────────

output perRiskAssignmentIds array = [
  indirectAttack.id
  hate.id
  sexual.id
  violence.id
  selfharm.id
  profanity.id
  protectedMaterialText.id
  protectedMaterialCode.id
  spotlighting.id
]
