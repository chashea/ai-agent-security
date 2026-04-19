// foundry-guardrail-policies.bicep
//
// Foundry Control Plane-style guardrail policies for Azure AI Foundry /
// Azure OpenAI model deployments. Mirrors the portal flow described at
// https://learn.microsoft.com/en-us/azure/foundry/control-plane/quickstart-create-guardrail-policy
// but as code: 8 custom Azure Policy definitions + one initiative + one
// subscription-scoped assignment.
//
// Each definition targets either:
//   - Microsoft.CognitiveServices/accounts/deployments  (model deployment)
//   - Microsoft.CognitiveServices/accounts/raiPolicies  (RAI policy shape)
//
// Effect is parameterised per policy (default Audit) so you can ramp up to
// Deny once existing resources have been remediated.
//
// Deployed at subscription scope.

targetScope = 'subscription'

@description('Prefix used on every policy definition, initiative, and assignment name.')
param namePrefix string = 'aisec'

@description('Display-name prefix shown in the portal.')
param displayPrefix string = 'AISec Foundry Guardrail'

@description('Default effect applied to every policy in the initiative unless overridden.')
@allowed([
  'Audit'
  'Deny'
  'Disabled'
])
param defaultEffect string = 'Audit'

@description('Skip creating the subscription-scope assignment (definitions + initiative only).')
param skipAssignment bool = false

var metadataCommon = {
  category: 'Microsoft Foundry'
  version: '1.0.0'
  source: 'github.com/chashea/ai-agent-security/infra/foundry-guardrail-policies.bicep'
}

// ── 1. Require RAI policy on every model deployment ─────────────────────────

resource p1 'Microsoft.Authorization/policyDefinitions@2023-04-01' = {
  name: '${namePrefix}-require-raipolicy-on-deployment'
  properties: {
    displayName: '${displayPrefix}: Model deployment must have an RAI policy attached'
    description: 'Denies or audits Azure AI Foundry / Azure OpenAI model deployments that do not reference a responsible-AI (raiPolicyName) policy. Equivalent to the "Content safety filters" control in the Foundry Control Plane guardrail wizard.'
    mode: 'All'
    metadata: metadataCommon
    parameters: {
      effect: {
        type: 'String'
        allowedValues: ['Audit', 'Deny', 'Disabled']
        defaultValue: 'Audit'
        metadata: { displayName: 'Effect' }
      }
    }
    policyRule: {
      if: {
        allOf: [
          { field: 'type', equals: 'Microsoft.CognitiveServices/accounts/deployments' }
          {
            anyOf: [
              { field: 'Microsoft.CognitiveServices/accounts/deployments/raiPolicyName', exists: 'false' }
              { field: 'Microsoft.CognitiveServices/accounts/deployments/raiPolicyName', equals: '' }
            ]
          }
        ]
      }
      then: { effect: '[parameters(\'effect\')]' }
    }
  }
}

// ── 2. Require Microsoft.DefaultV2 base policy ──────────────────────────────

resource p2 'Microsoft.Authorization/policyDefinitions@2023-04-01' = {
  name: '${namePrefix}-require-defaultv2-base'
  properties: {
    displayName: '${displayPrefix}: RAI policies must derive from Microsoft.DefaultV2'
    description: 'Denies or audits RAI policies that inherit from the legacy Microsoft.Default base (v0). DefaultV2 is required for Prompt Shields, indirect-attack detection, and protected-material filters.'
    mode: 'All'
    metadata: metadataCommon
    parameters: {
      effect: {
        type: 'String'
        allowedValues: ['Audit', 'Deny', 'Disabled']
        defaultValue: 'Audit'
        metadata: { displayName: 'Effect' }
      }
    }
    policyRule: {
      if: {
        allOf: [
          { field: 'type', equals: 'Microsoft.CognitiveServices/accounts/raiPolicies' }
          { field: 'Microsoft.CognitiveServices/accounts/raiPolicies/basePolicyName', notEquals: 'Microsoft.DefaultV2' }
        ]
      }
      then: { effect: '[parameters(\'effect\')]' }
    }
  }
}

// ── 3. Require Blocking mode (no Audit-only RAI policies) ───────────────────

resource p3 'Microsoft.Authorization/policyDefinitions@2023-04-01' = {
  name: '${namePrefix}-require-blocking-mode'
  properties: {
    displayName: '${displayPrefix}: RAI policies must run in Blocking mode'
    description: 'Denies or audits RAI policies whose mode is not "Blocking". Audit-only mode logs violations but lets traffic through — not suitable for production guardrails.'
    mode: 'All'
    metadata: metadataCommon
    parameters: {
      effect: {
        type: 'String'
        allowedValues: ['Audit', 'Deny', 'Disabled']
        defaultValue: 'Audit'
        metadata: { displayName: 'Effect' }
      }
    }
    policyRule: {
      if: {
        allOf: [
          { field: 'type', equals: 'Microsoft.CognitiveServices/accounts/raiPolicies' }
          { field: 'Microsoft.CognitiveServices/accounts/raiPolicies/mode', notEquals: 'Blocking' }
        ]
      }
      then: { effect: '[parameters(\'effect\')]' }
    }
  }
}

// ── 4. Require Prompt Shields: jailbreak filter blocking ────────────────────

resource p4 'Microsoft.Authorization/policyDefinitions@2023-04-01' = {
  name: '${namePrefix}-require-prompt-shield-jailbreak'
  properties: {
    displayName: '${displayPrefix}: Prompt Shields jailbreak filter must be blocking'
    description: 'Denies or audits RAI policies that do not include a Prompt-source "jailbreak" content filter with enabled=true and blocking=true. Required to catch DAN-style and role-reset attacks.'
    mode: 'All'
    metadata: metadataCommon
    parameters: {
      effect: {
        type: 'String'
        allowedValues: ['Audit', 'Deny', 'Disabled']
        defaultValue: 'Audit'
        metadata: { displayName: 'Effect' }
      }
    }
    policyRule: {
      if: {
        allOf: [
          { field: 'type', equals: 'Microsoft.CognitiveServices/accounts/raiPolicies' }
          {
            count: {
              field: 'Microsoft.CognitiveServices/accounts/raiPolicies/contentFilters[*]'
              where: {
                allOf: [
                  { field: 'Microsoft.CognitiveServices/accounts/raiPolicies/contentFilters[*].name', equals: 'jailbreak' }
                  { field: 'Microsoft.CognitiveServices/accounts/raiPolicies/contentFilters[*].source', equals: 'Prompt' }
                  { field: 'Microsoft.CognitiveServices/accounts/raiPolicies/contentFilters[*].enabled', equals: true }
                  { field: 'Microsoft.CognitiveServices/accounts/raiPolicies/contentFilters[*].blocking', equals: true }
                ]
              }
            }
            less: 1
          }
        ]
      }
      then: { effect: '[parameters(\'effect\')]' }
    }
  }
}

// ── 5. Require Prompt Shields: indirect-attack (XPIA) filter blocking ───────

resource p5 'Microsoft.Authorization/policyDefinitions@2023-04-01' = {
  name: '${namePrefix}-require-prompt-shield-indirect-attack'
  properties: {
    displayName: '${displayPrefix}: Prompt Shields indirect-attack (XPIA) filter must be blocking'
    description: 'Denies or audits RAI policies that do not include a Prompt-source "indirect_attack" filter with enabled=true and blocking=true. Required to defend tool-using agents against payloads hidden in grounding documents, web pages, or emails.'
    mode: 'All'
    metadata: metadataCommon
    parameters: {
      effect: {
        type: 'String'
        allowedValues: ['Audit', 'Deny', 'Disabled']
        defaultValue: 'Audit'
        metadata: { displayName: 'Effect' }
      }
    }
    policyRule: {
      if: {
        allOf: [
          { field: 'type', equals: 'Microsoft.CognitiveServices/accounts/raiPolicies' }
          {
            count: {
              field: 'Microsoft.CognitiveServices/accounts/raiPolicies/contentFilters[*]'
              where: {
                allOf: [
                  { field: 'Microsoft.CognitiveServices/accounts/raiPolicies/contentFilters[*].name', equals: 'indirect_attack' }
                  { field: 'Microsoft.CognitiveServices/accounts/raiPolicies/contentFilters[*].source', equals: 'Prompt' }
                  { field: 'Microsoft.CognitiveServices/accounts/raiPolicies/contentFilters[*].enabled', equals: true }
                  { field: 'Microsoft.CognitiveServices/accounts/raiPolicies/contentFilters[*].blocking', equals: true }
                ]
              }
            }
            less: 1
          }
        ]
      }
      then: { effect: '[parameters(\'effect\')]' }
    }
  }
}

// ── 6. Require harmful-content filters at severity Low on both sources ─────

resource p6 'Microsoft.Authorization/policyDefinitions@2023-04-01' = {
  name: '${namePrefix}-require-harmful-content-low-threshold'
  properties: {
    displayName: '${displayPrefix}: Hate/Sexual/Violence/Self-harm must block at severity Low on Prompt and Completion'
    description: 'Denies or audits RAI policies missing any of the four core Content Safety filters (hate, sexual, violence, selfharm) on both Prompt and Completion sources with enabled=true, blocking=true, severityThreshold=Low.'
    mode: 'All'
    metadata: metadataCommon
    parameters: {
      effect: {
        type: 'String'
        allowedValues: ['Audit', 'Deny', 'Disabled']
        defaultValue: 'Audit'
        metadata: { displayName: 'Effect' }
      }
    }
    policyRule: {
      if: {
        allOf: [
          { field: 'type', equals: 'Microsoft.CognitiveServices/accounts/raiPolicies' }
          {
            anyOf: [
              {
                count: {
                  field: 'Microsoft.CognitiveServices/accounts/raiPolicies/contentFilters[*]'
                  where: {
                    allOf: [
                      { field: 'Microsoft.CognitiveServices/accounts/raiPolicies/contentFilters[*].name', in: ['hate', 'sexual', 'violence', 'selfharm'] }
                      { field: 'Microsoft.CognitiveServices/accounts/raiPolicies/contentFilters[*].source', equals: 'Prompt' }
                      { field: 'Microsoft.CognitiveServices/accounts/raiPolicies/contentFilters[*].enabled', equals: true }
                      { field: 'Microsoft.CognitiveServices/accounts/raiPolicies/contentFilters[*].blocking', equals: true }
                      { field: 'Microsoft.CognitiveServices/accounts/raiPolicies/contentFilters[*].severityThreshold', equals: 'Low' }
                    ]
                  }
                }
                less: 4
              }
              {
                count: {
                  field: 'Microsoft.CognitiveServices/accounts/raiPolicies/contentFilters[*]'
                  where: {
                    allOf: [
                      { field: 'Microsoft.CognitiveServices/accounts/raiPolicies/contentFilters[*].name', in: ['hate', 'sexual', 'violence', 'selfharm'] }
                      { field: 'Microsoft.CognitiveServices/accounts/raiPolicies/contentFilters[*].source', equals: 'Completion' }
                      { field: 'Microsoft.CognitiveServices/accounts/raiPolicies/contentFilters[*].enabled', equals: true }
                      { field: 'Microsoft.CognitiveServices/accounts/raiPolicies/contentFilters[*].blocking', equals: true }
                      { field: 'Microsoft.CognitiveServices/accounts/raiPolicies/contentFilters[*].severityThreshold', equals: 'Low' }
                    ]
                  }
                }
                less: 4
              }
            ]
          }
        ]
      }
      then: { effect: '[parameters(\'effect\')]' }
    }
  }
}

// ── 7. Require protected-material filters (text + code) blocking ────────────

resource p7 'Microsoft.Authorization/policyDefinitions@2023-04-01' = {
  name: '${namePrefix}-require-protected-material-filters'
  properties: {
    displayName: '${displayPrefix}: Protected-material (text + code) filters must be blocking on Completion'
    description: 'Denies or audits RAI policies missing blocking "protected_material_text" and "protected_material_code" filters on the Completion source. These catch copyrighted content and licensed code regurgitation.'
    mode: 'All'
    metadata: metadataCommon
    parameters: {
      effect: {
        type: 'String'
        allowedValues: ['Audit', 'Deny', 'Disabled']
        defaultValue: 'Audit'
        metadata: { displayName: 'Effect' }
      }
    }
    policyRule: {
      if: {
        allOf: [
          { field: 'type', equals: 'Microsoft.CognitiveServices/accounts/raiPolicies' }
          {
            count: {
              field: 'Microsoft.CognitiveServices/accounts/raiPolicies/contentFilters[*]'
              where: {
                allOf: [
                  { field: 'Microsoft.CognitiveServices/accounts/raiPolicies/contentFilters[*].name', in: ['protected_material_text', 'protected_material_code'] }
                  { field: 'Microsoft.CognitiveServices/accounts/raiPolicies/contentFilters[*].source', equals: 'Completion' }
                  { field: 'Microsoft.CognitiveServices/accounts/raiPolicies/contentFilters[*].enabled', equals: true }
                  { field: 'Microsoft.CognitiveServices/accounts/raiPolicies/contentFilters[*].blocking', equals: true }
                ]
              }
            }
            less: 2
          }
        ]
      }
      then: { effect: '[parameters(\'effect\')]' }
    }
  }
}

// ── 8. Require at least one blocking custom blocklist (PII / secrets) ───────

resource p8 'Microsoft.Authorization/policyDefinitions@2023-04-01' = {
  name: '${namePrefix}-require-custom-blocklist'
  properties: {
    displayName: '${displayPrefix}: RAI policies must attach a blocking custom blocklist'
    description: 'Denies or audits RAI policies with no customBlocklists entry in blocking mode. Enforces the presence of an organisation-specific blocklist (e.g., PII regex: SSN, credit card, bank account) so sensitive patterns are stripped even when core filters miss them.'
    mode: 'All'
    metadata: metadataCommon
    parameters: {
      effect: {
        type: 'String'
        allowedValues: ['Audit', 'Deny', 'Disabled']
        defaultValue: 'Audit'
        metadata: { displayName: 'Effect' }
      }
    }
    policyRule: {
      if: {
        allOf: [
          { field: 'type', equals: 'Microsoft.CognitiveServices/accounts/raiPolicies' }
          {
            count: {
              field: 'Microsoft.CognitiveServices/accounts/raiPolicies/customBlocklists[*]'
              where: {
                field: 'Microsoft.CognitiveServices/accounts/raiPolicies/customBlocklists[*].blocking'
                equals: true
              }
            }
            less: 1
          }
        ]
      }
      then: { effect: '[parameters(\'effect\')]' }
    }
  }
}

// ── 9. Require PII (personally identifiable info) filter on Completion ──────
// Azure AI Content Safety PII detector runs on model completions and can
// annotate / filter / redact SSN, email, phone, credit-card, passport, etc.
// Policy requires a blocking "pii" filter on the Completion source.

resource p9 'Microsoft.Authorization/policyDefinitions@2023-04-01' = {
  name: '${namePrefix}-require-pii-filter'
  properties: {
    displayName: '${displayPrefix}: PII filter must be blocking on Completion'
    description: 'Denies or audits RAI policies missing a blocking "pii" content filter on the Completion source. Catches SSN / credit card / email / phone / passport patterns emitted by the model even when core harm filters miss them. Complements the custom blocklist policy: blocklist catches known patterns, PII detector catches novel ones.'
    mode: 'All'
    metadata: metadataCommon
    parameters: {
      effect: {
        type: 'String'
        allowedValues: ['Audit', 'Deny', 'Disabled']
        defaultValue: 'Audit'
        metadata: { displayName: 'Effect' }
      }
    }
    policyRule: {
      if: {
        allOf: [
          { field: 'type', equals: 'Microsoft.CognitiveServices/accounts/raiPolicies' }
          {
            count: {
              field: 'Microsoft.CognitiveServices/accounts/raiPolicies/contentFilters[*]'
              where: {
                allOf: [
                  { field: 'Microsoft.CognitiveServices/accounts/raiPolicies/contentFilters[*].name', equals: 'pii' }
                  { field: 'Microsoft.CognitiveServices/accounts/raiPolicies/contentFilters[*].source', equals: 'Completion' }
                  { field: 'Microsoft.CognitiveServices/accounts/raiPolicies/contentFilters[*].enabled', equals: true }
                  { field: 'Microsoft.CognitiveServices/accounts/raiPolicies/contentFilters[*].blocking', equals: true }
                ]
              }
            }
            less: 1
          }
        ]
      }
      then: { effect: '[parameters(\'effect\')]' }
    }
  }
}

// ── 10. Require groundedness filter on Completion ───────────────────────────
// Groundedness detection flags completions that aren't supported by the
// retrieval-augmented context (RAG grounding data). Critical for agents
// with file_search / azure_ai_search / bing_grounding tools where a
// hallucinated answer would bypass the knowledge base entirely.

resource p10 'Microsoft.Authorization/policyDefinitions@2023-04-01' = {
  name: '${namePrefix}-require-groundedness-filter'
  properties: {
    displayName: '${displayPrefix}: Groundedness filter must be enabled on Completion'
    description: 'Denies or audits RAI policies missing a "groundedness" filter on the Completion source. Groundedness detection catches fabricated / ungrounded responses in RAG pipelines. Default config emits annotations; flip blocking=true to hard-fail ungrounded completions instead of logging them.'
    mode: 'All'
    metadata: metadataCommon
    parameters: {
      effect: {
        type: 'String'
        allowedValues: ['Audit', 'Deny', 'Disabled']
        defaultValue: 'Audit'
        metadata: { displayName: 'Effect' }
      }
    }
    policyRule: {
      if: {
        allOf: [
          { field: 'type', equals: 'Microsoft.CognitiveServices/accounts/raiPolicies' }
          {
            count: {
              field: 'Microsoft.CognitiveServices/accounts/raiPolicies/contentFilters[*]'
              where: {
                allOf: [
                  { field: 'Microsoft.CognitiveServices/accounts/raiPolicies/contentFilters[*].name', equals: 'groundedness' }
                  { field: 'Microsoft.CognitiveServices/accounts/raiPolicies/contentFilters[*].source', equals: 'Completion' }
                  { field: 'Microsoft.CognitiveServices/accounts/raiPolicies/contentFilters[*].enabled', equals: true }
                ]
              }
            }
            less: 1
          }
        ]
      }
      then: { effect: '[parameters(\'effect\')]' }
    }
  }
}

// ── 11. Require tool-call intervention filters (agent deployments) ──────────
// Foundry agents have 4 intervention points per
// learn.microsoft.com/azure/foundry/guardrails/guardrails-overview:
//   User input (Prompt), Tool call (PreToolCall), Tool response
//   (PostToolCall), Output (Completion).
// This policy requires at least one filter on PreToolCall OR PostToolCall
// so agentic deployments aren't blind to tool-boundary risks (e.g. an
// openapi tool invoked with a payload that exfiltrates user data, or a
// malicious doc returned by a file_search tool response).

resource p11 'Microsoft.Authorization/policyDefinitions@2023-04-01' = {
  name: '${namePrefix}-require-toolcall-filters'
  properties: {
    displayName: '${displayPrefix}: Agentic RAI policies must filter tool-call / tool-response'
    description: 'Denies or audits RAI policies that have no content filter on the PreToolCall or PostToolCall intervention points. Foundry agent-service deployments should filter the action the agent proposes to send to a tool AND the content returned from a tool, not just the user prompt and final output. Preview intervention points per Foundry guardrail docs.'
    mode: 'All'
    metadata: metadataCommon
    parameters: {
      effect: {
        type: 'String'
        allowedValues: ['Audit', 'Deny', 'Disabled']
        defaultValue: 'Audit'
        metadata: { displayName: 'Effect' }
      }
    }
    policyRule: {
      if: {
        allOf: [
          { field: 'type', equals: 'Microsoft.CognitiveServices/accounts/raiPolicies' }
          {
            count: {
              field: 'Microsoft.CognitiveServices/accounts/raiPolicies/contentFilters[*]'
              where: {
                allOf: [
                  { field: 'Microsoft.CognitiveServices/accounts/raiPolicies/contentFilters[*].source', in: ['PreToolCall', 'PostToolCall'] }
                  { field: 'Microsoft.CognitiveServices/accounts/raiPolicies/contentFilters[*].enabled', equals: true }
                ]
              }
            }
            less: 1
          }
        ]
      }
      then: { effect: '[parameters(\'effect\')]' }
    }
  }
}

// ── 12. Deny audit-mode creep (any sub-filter enabled but not blocking) ─────
// Config-drift detector: if ANY individual content filter has enabled=true
// AND blocking=false (annotate-only), the RAI policy as a whole is flagged.
// Complements p3 (which enforces policy-level Blocking mode) — this catches
// the subtler case where someone flips one filter to annotate-only while
// leaving the policy mode itself in Blocking.

resource p12 'Microsoft.Authorization/policyDefinitions@2023-04-01' = {
  name: '${namePrefix}-deny-audit-mode-subfilter'
  properties: {
    displayName: '${displayPrefix}: No RAI sub-filter may be annotate-only (blocking=false)'
    description: 'Denies or audits RAI policies where any individual content filter has enabled=true and blocking=false. Annotate-only ("audit") filters log detections but let traffic through. This policy catches config drift — someone weakening a single filter while leaving the policy in Blocking mode. Excludes filters where enabled=false (intentionally off is fine).'
    mode: 'All'
    metadata: metadataCommon
    parameters: {
      effect: {
        type: 'String'
        allowedValues: ['Audit', 'Deny', 'Disabled']
        defaultValue: 'Audit'
        metadata: { displayName: 'Effect' }
      }
    }
    policyRule: {
      if: {
        allOf: [
          { field: 'type', equals: 'Microsoft.CognitiveServices/accounts/raiPolicies' }
          {
            count: {
              field: 'Microsoft.CognitiveServices/accounts/raiPolicies/contentFilters[*]'
              where: {
                allOf: [
                  { field: 'Microsoft.CognitiveServices/accounts/raiPolicies/contentFilters[*].enabled', equals: true }
                  { field: 'Microsoft.CognitiveServices/accounts/raiPolicies/contentFilters[*].blocking', equals: false }
                ]
              }
            }
            greater: 0
          }
        ]
      }
      then: { effect: '[parameters(\'effect\')]' }
    }
  }
}

// ── Initiative (policySet) ──────────────────────────────────────────────────

resource initiative 'Microsoft.Authorization/policySetDefinitions@2023-04-01' = {
  name: '${namePrefix}-foundry-guardrails'
  properties: {
    displayName: '${displayPrefix}: Baseline (12 controls)'
    description: 'Baseline guardrail controls for Azure AI Foundry / Azure OpenAI model deployments, aligned with the Microsoft Foundry Control Plane guardrail policy wizard: RAI policy present, DefaultV2 base, Blocking mode, Prompt Shields (jailbreak + indirect attack), core Content Safety filters at severity Low, protected-material filters, custom blocklist, PII filter, groundedness filter, tool-call intervention filters, and audit-creep detector.'
    metadata: metadataCommon
    policyType: 'Custom'
    parameters: {
      defaultEffect: {
        type: 'String'
        allowedValues: ['Audit', 'Deny', 'Disabled']
        defaultValue: 'Audit'
        metadata: { displayName: 'Default effect for every control' }
      }
    }
    policyDefinitions: [
      {
        policyDefinitionReferenceId: 'requireRaiPolicyOnDeployment'
        policyDefinitionId: p1.id
        parameters: { effect: { value: '[parameters(\'defaultEffect\')]' } }
      }
      {
        policyDefinitionReferenceId: 'requireDefaultV2Base'
        policyDefinitionId: p2.id
        parameters: { effect: { value: '[parameters(\'defaultEffect\')]' } }
      }
      {
        policyDefinitionReferenceId: 'requireBlockingMode'
        policyDefinitionId: p3.id
        parameters: { effect: { value: '[parameters(\'defaultEffect\')]' } }
      }
      {
        policyDefinitionReferenceId: 'requirePromptShieldJailbreak'
        policyDefinitionId: p4.id
        parameters: { effect: { value: '[parameters(\'defaultEffect\')]' } }
      }
      {
        policyDefinitionReferenceId: 'requirePromptShieldIndirectAttack'
        policyDefinitionId: p5.id
        parameters: { effect: { value: '[parameters(\'defaultEffect\')]' } }
      }
      {
        policyDefinitionReferenceId: 'requireHarmfulContentLowThreshold'
        policyDefinitionId: p6.id
        parameters: { effect: { value: '[parameters(\'defaultEffect\')]' } }
      }
      {
        policyDefinitionReferenceId: 'requireProtectedMaterialFilters'
        policyDefinitionId: p7.id
        parameters: { effect: { value: '[parameters(\'defaultEffect\')]' } }
      }
      {
        policyDefinitionReferenceId: 'requireCustomBlocklist'
        policyDefinitionId: p8.id
        parameters: { effect: { value: '[parameters(\'defaultEffect\')]' } }
      }
      {
        policyDefinitionReferenceId: 'requirePiiFilter'
        policyDefinitionId: p9.id
        parameters: { effect: { value: '[parameters(\'defaultEffect\')]' } }
      }
      {
        policyDefinitionReferenceId: 'requireGroundednessFilter'
        policyDefinitionId: p10.id
        parameters: { effect: { value: '[parameters(\'defaultEffect\')]' } }
      }
      {
        policyDefinitionReferenceId: 'requireToolCallFilters'
        policyDefinitionId: p11.id
        parameters: { effect: { value: '[parameters(\'defaultEffect\')]' } }
      }
      {
        policyDefinitionReferenceId: 'denyAuditModeSubfilter'
        policyDefinitionId: p12.id
        parameters: { effect: { value: '[parameters(\'defaultEffect\')]' } }
      }
    ]
  }
}

// ── Subscription-scope assignment ───────────────────────────────────────────

resource assignment 'Microsoft.Authorization/policyAssignments@2023-04-01' = if (!skipAssignment) {
  name: '${namePrefix}-foundry-guardrails-assign'
  properties: {
    displayName: '${displayPrefix}: Baseline assignment'
    description: 'Assigns the Foundry guardrail baseline initiative to the current subscription.'
    policyDefinitionId: initiative.id
    parameters: {
      defaultEffect: { value: defaultEffect }
    }
    enforcementMode: 'Default'
  }
}

// ── Outputs ─────────────────────────────────────────────────────────────────

output initiativeId string = initiative.id
output assignmentId string = skipAssignment ? '' : assignment.id
output policyDefinitionIds array = [
  p1.id
  p2.id
  p3.id
  p4.id
  p5.id
  p6.id
  p7.id
  p8.id
  p9.id
  p10.id
  p11.id
  p12.id
]
