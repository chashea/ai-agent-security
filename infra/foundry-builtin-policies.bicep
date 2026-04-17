// foundry-builtin-policies.bicep
//
// Subscription-scoped assignments of Microsoft built-in Azure AI / Cognitive
// Services security policies + regulatory-framework initiatives, intended to
// surface alongside the custom Foundry guardrail baseline in
// Defender for Cloud / Policy Compliance.
//
// All effects default to Audit / AuditIfNotExists so the lab environment
// remains usable. Promote to Deny only after remediating findings.

targetScope = 'subscription'

@description('Prefix for assignment names.')
param namePrefix string = 'aisec'

@description('Display-name prefix shown in the portal.')
param displayPrefix string = 'AISec Foundry Compliance'

var metadataCommon = {
  category: 'Microsoft Foundry'
  version: '1.0.0'
  source: 'github.com/chashea/ai-agent-security/infra/foundry-builtin-policies.bicep'
}

// ── Built-in policy definition IDs ──────────────────────────────────────────
var pDiagnosticLogs       = tenantResourceId('Microsoft.Authorization/policyDefinitions', '1b4d1c4e-934c-4703-944c-27c82c06bebb')
var pRestrictNetwork      = tenantResourceId('Microsoft.Authorization/policyDefinitions', '037eea7a-bd0a-46c5-9a66-03aea78705d3')
var pDisableLocalKeys     = tenantResourceId('Microsoft.Authorization/policyDefinitions', '71ef260a-8f18-47b7-abcb-62d0673d94dc')
var pCmkEncryption        = tenantResourceId('Microsoft.Authorization/policyDefinitions', '67121cc7-ff39-4ab8-b7e3-95b84dab487d')
var pDefenderForAi        = tenantResourceId('Microsoft.Authorization/policyDefinitions', 'c2c0c6d8-007b-4a48-8d9b-3539bddd8e87')
var pPrivateLink          = tenantResourceId('Microsoft.Authorization/policyDefinitions', 'd6759c02-b87f-42b7-892e-71b3f471d782')

// ── Initiative: Azure AI security baseline (6 controls) ─────────────────────

resource securityBaseline 'Microsoft.Authorization/policySetDefinitions@2023-04-01' = {
  name: '${namePrefix}-foundry-ai-security-baseline'
  properties: {
    displayName: '${displayPrefix}: Azure AI security baseline (6 controls)'
    description: 'Microsoft built-in security controls for Azure AI Services / Foundry accounts: diagnostic logging, network restriction, local key disablement, CMK encryption, Defender for AI Services, and Private Link.'
    metadata: metadataCommon
    policyType: 'Custom'
    policyDefinitions: [
      {
        policyDefinitionReferenceId: 'diagnosticLogsAi'
        policyDefinitionId: pDiagnosticLogs
        parameters: { effect: { value: 'AuditIfNotExists' } }
      }
      {
        policyDefinitionReferenceId: 'restrictNetworkAi'
        policyDefinitionId: pRestrictNetwork
        parameters: { effect: { value: 'Audit' } }
      }
      {
        policyDefinitionReferenceId: 'disableLocalKeysAi'
        policyDefinitionId: pDisableLocalKeys
        parameters: { effect: { value: 'Audit' } }
      }
      {
        policyDefinitionReferenceId: 'cmkEncryptionAi'
        policyDefinitionId: pCmkEncryption
        parameters: { effect: { value: 'Audit' } }
      }
      {
        policyDefinitionReferenceId: 'defenderForAi'
        policyDefinitionId: pDefenderForAi
        parameters: { effect: { value: 'AuditIfNotExists' } }
      }
      {
        policyDefinitionReferenceId: 'privateLinkAi'
        policyDefinitionId: pPrivateLink
        parameters: { effect: { value: 'Audit' } }
      }
    ]
  }
}

resource securityBaselineAssign 'Microsoft.Authorization/policyAssignments@2023-04-01' = {
  name: '${namePrefix}-ai-security-baseline-assign'
  properties: {
    displayName: '${displayPrefix}: Azure AI security baseline assignment'
    description: 'Assigns the Azure AI security baseline (6 built-in controls) to the current subscription.'
    policyDefinitionId: securityBaseline.id
    enforcementMode: 'Default'
  }
}

// ── Regulatory framework: NIST AI RMF v1.0 ──────────────────────────────────

resource nistAiRmf 'Microsoft.Authorization/policyAssignments@2023-04-01' = {
  name: '${namePrefix}-nist-ai-rmf-assign'
  properties: {
    displayName: '${displayPrefix}: NIST AI RMF v1.0'
    description: 'Audits compliance with the NIST AI Risk Management Framework v1.0.'
    policyDefinitionId: tenantResourceId('Microsoft.Authorization/policySetDefinitions', 'f58a876c-ec25-417e-9634-58d2a93e3fe2')
    enforcementMode: 'Default'
  }
}

// ── Regulatory framework: EU AI Act 2024/1689 ───────────────────────────────

resource euAiAct 'Microsoft.Authorization/policyAssignments@2023-04-01' = {
  name: '${namePrefix}-eu-ai-act-assign'
  properties: {
    displayName: '${displayPrefix}: EU AI Act 2024/1689'
    description: 'Audits compliance with the EU AI Act (Regulation 2024/1689).'
    policyDefinitionId: tenantResourceId('Microsoft.Authorization/policySetDefinitions', '1308bccf-446a-4283-a4e0-0c983fe7a572')
    enforcementMode: 'Default'
  }
}

// ── Outputs ─────────────────────────────────────────────────────────────────

output securityBaselineInitiativeId string = securityBaseline.id
output securityBaselineAssignmentId string = securityBaselineAssign.id
output nistAiRmfAssignmentId string = nistAiRmf.id
output euAiActAssignmentId string = euAiAct.id
