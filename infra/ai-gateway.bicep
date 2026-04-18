// ai-gateway.bicep — APIM-based AI Gateway in front of the Foundry account.
//
// Provisions an Azure API Management instance (v2 tier) and wires it as an
// AI Gateway for the existing Foundry AOAI endpoint. Applies the documented
// AI-gateway policy stack:
//
//   - llm-token-limit (per-subscription TPM rate limit + optional monthly quota)
//   - llm-emit-token-metric (ships prompt/completion/total token counts to
//     Application Insights as custom metrics)
//   - set-backend-service pointing at the Foundry account
//
// Auth between APIM and Foundry uses the APIM system-assigned managed identity
// with the Cognitive Services OpenAI User role on the account.
//
// Reference: https://learn.microsoft.com/azure/foundry/configuration/enable-ai-api-management-gateway-portal
// Reference: https://learn.microsoft.com/azure/api-management/genai-gateway-capabilities
// Reference: https://learn.microsoft.com/azure/api-management/llm-token-limit-policy

targetScope = 'resourceGroup'

@description('Name of the APIM instance (3-50 chars, lowercase alphanumeric + hyphens).')
param apimName string

@description('Azure region for the APIM instance.')
param location string = resourceGroup().location

@description('APIM SKU. BasicV2 is the portal default for AI Gateway (dev/test, with SLA). StandardV2 and PremiumV2 are production tiers.')
@allowed([
  'BasicV2'
  'StandardV2'
  'PremiumV2'
])
param skuName string = 'BasicV2'

@description('APIM capacity units (1 for BasicV2/StandardV2, 1-10 for PremiumV2).')
@minValue(1)
@maxValue(10)
param skuCapacity int = 1

@description('Publisher email attached to the APIM instance (shown in developer portal).')
param publisherEmail string

@description('Publisher display name attached to the APIM instance.')
param publisherName string

@description('Name of the existing Foundry (Cognitive Services) account to front.')
param foundryAccountName string

@description('Optional: existing Application Insights resource ID for token-metric emission. Leave blank to skip metric emission.')
param appInsightsResourceId string = ''

@description('TPM (tokens-per-minute) rate limit per APIM subscription key.')
@minValue(10)
param tokensPerMinute int = 1000

@description('Monthly token quota per APIM subscription key (0 disables the quota, use rate limit only).')
@minValue(0)
param monthlyTokenQuota int = 0

@description('Name of the OpenAI-compatible API inside APIM (appears in developer portal).')
param openaiApiName string = 'aoai'

@description('Path prefix the API is served under (e.g. <apim>.azure-api.net/openai).')
param openaiApiPath string = 'openai'

@description('Azure OpenAI API version surfaced through the gateway (matches the api-version query-string value).')
param openaiApiVersion string = '2024-10-21'

// ── APIM service ────────────────────────────────────────────────────────────

resource apim 'Microsoft.ApiManagement/service@2024-06-01-preview' = {
  name: apimName
  location: location
  sku: {
    name: skuName
    capacity: skuCapacity
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    publisherEmail: publisherEmail
    publisherName: publisherName
    virtualNetworkType: 'None'
    publicNetworkAccess: 'Enabled'
  }
}

// ── Reference to existing Foundry account (read-only; we don't manage its lifecycle here) ─

resource foundry 'Microsoft.CognitiveServices/accounts@2025-06-01' existing = {
  name: foundryAccountName
}

// ── Grant APIM MI the Cognitive Services OpenAI User role on Foundry ───────

var cognitiveServicesOpenAIUserRoleId = '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd' // built-in role

resource foundryRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(foundry.id, apim.id, cognitiveServicesOpenAIUserRoleId)
  scope: foundry
  properties: {
    principalId: apim.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', cognitiveServicesOpenAIUserRoleId)
  }
}

// ── Backend pointing at the Foundry AOAI endpoint ──────────────────────────

resource foundryBackend 'Microsoft.ApiManagement/service/backends@2024-06-01-preview' = {
  parent: apim
  name: 'foundry-aoai'
  properties: {
    protocol: 'http'
    url: '${foundry.properties.endpoint}openai'
    description: 'Foundry AOAI endpoint (${foundryAccountName})'
  }
}

// ── OpenAI-compatible API (imported spec skeleton — consumers call chat/completions) ─

resource openaiApi 'Microsoft.ApiManagement/service/apis@2024-06-01-preview' = {
  parent: apim
  name: openaiApiName
  properties: {
    displayName: 'Azure OpenAI (via AI Gateway)'
    description: 'Foundry AOAI chat completions + embeddings surfaced through APIM with llm-token-limit + llm-emit-token-metric policies.'
    path: openaiApiPath
    protocols: [
      'https'
    ]
    serviceUrl: '${foundry.properties.endpoint}openai'
    subscriptionRequired: true
    apiType: 'http'
    format: 'openapi+json'
    value: string({
      openapi: '3.0.1'
      info: {
        title: 'Azure OpenAI'
        version: openaiApiVersion
      }
      servers: [
        {
          url: '${foundry.properties.endpoint}openai'
        }
      ]
      paths: {
        '/deployments/{deployment-id}/chat/completions': {
          post: {
            operationId: 'chatCompletions'
            summary: 'Creates a chat completion for the given model deployment.'
            parameters: [
              { name: 'deployment-id', in: 'path', required: true, schema: { type: 'string' } }
              { name: 'api-version', in: 'query', required: true, schema: { type: 'string' } }
            ]
            requestBody: {
              required: true
              content: {
                'application/json': {
                  schema: { type: 'object' }
                }
              }
            }
            responses: {
              '200': {
                description: 'Chat completion response'
              }
            }
          }
        }
        '/deployments/{deployment-id}/embeddings': {
          post: {
            operationId: 'embeddings'
            summary: 'Creates an embedding vector for the given input.'
            parameters: [
              { name: 'deployment-id', in: 'path', required: true, schema: { type: 'string' } }
              { name: 'api-version', in: 'query', required: true, schema: { type: 'string' } }
            ]
            requestBody: {
              required: true
              content: {
                'application/json': {
                  schema: { type: 'object' }
                }
              }
            }
            responses: {
              '200': {
                description: 'Embeddings response'
              }
            }
          }
        }
      }
    })
  }
}

// ── AI-gateway policy on the OpenAI API ────────────────────────────────────
// - authentication-managed-identity: APIM MI → Foundry with the AOAI audience
// - set-backend-service: route to the Foundry backend we created above
// - llm-token-limit: per-subscription TPM + optional monthly quota (429/403)
// - llm-emit-token-metric: prompt/completion/total counters to App Insights (when logger attached)

var policyXml = '''
<policies>
  <inbound>
    <base />
    <authentication-managed-identity resource="https://cognitiveservices.azure.com" />
    <set-backend-service backend-id="foundry-aoai" />
    <llm-token-limit
      counter-key="@(context.Subscription.Id)"
      tokens-per-minute="{0}"
      estimate-prompt-tokens="false"
      {1}
      remaining-tokens-variable-name="remainingTokens" />
    {2}
  </inbound>
  <backend>
    <base />
  </backend>
  <outbound>
    <base />
  </outbound>
  <on-error>
    <base />
  </on-error>
</policies>
'''

var quotaAttributes = monthlyTokenQuota > 0 ? 'token-quota="${monthlyTokenQuota}" token-quota-period="Monthly" remaining-quota-tokens-variable-name="remainingQuotaTokens"' : ''
// Note: inside an XML attribute value the C# expression `context.Request.MatchedParameters["deployment-id"]`
// must encode its inner quotes as &quot; or APIM's XML parser terminates the attribute at the first inner `"`.
var emitMetricPolicy = empty(appInsightsResourceId) ? '' : '<llm-emit-token-metric namespace="aisec-aigateway"><dimension name="Subscription ID" /><dimension name="Deployment" value="@(context.Request.MatchedParameters[&quot;deployment-id&quot;])" /></llm-emit-token-metric>'

resource openaiApiPolicy 'Microsoft.ApiManagement/service/apis/policies@2024-06-01-preview' = {
  parent: openaiApi
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: format(policyXml, string(tokensPerMinute), quotaAttributes, emitMetricPolicy)
  }
  dependsOn: [
    foundryBackend
    foundryRoleAssignment
  ]
}

// ── Application Insights logger + diagnostic (optional) ────────────────────

resource appInsights 'Microsoft.Insights/components@2020-02-02' existing = if (!empty(appInsightsResourceId)) {
  name: last(split(appInsightsResourceId, '/'))
  scope: resourceGroup(split(appInsightsResourceId, '/')[4])
}

resource apimLogger 'Microsoft.ApiManagement/service/loggers@2024-06-01-preview' = if (!empty(appInsightsResourceId)) {
  parent: apim
  name: 'appinsights-logger'
  properties: {
    loggerType: 'applicationInsights'
    description: 'AI Gateway metrics + token counters'
    credentials: {
      #disable-next-line BCP318
      instrumentationKey: appInsights.properties.InstrumentationKey
    }
    resourceId: appInsightsResourceId
  }
}

resource openaiApiDiagnostic 'Microsoft.ApiManagement/service/apis/diagnostics@2024-06-01-preview' = if (!empty(appInsightsResourceId)) {
  parent: openaiApi
  name: 'applicationinsights'
  properties: {
    loggerId: apimLogger.id
    verbosity: 'information'
    sampling: {
      samplingType: 'fixed'
      percentage: 100
    }
    frontend: {
      request: {
        headers: [
          'Content-Type'
        ]
      }
      response: {
        headers: [
          'Content-Type'
        ]
      }
    }
    backend: {
      request: {
        headers: [
          'Content-Type'
        ]
      }
      response: {
        headers: [
          'Content-Type'
        ]
      }
    }
    httpCorrelationProtocol: 'W3C'
    alwaysLog: 'allErrors'
  }
}

// ── Starter subscription ───────────────────────────────────────────────────
// Provides a ready-to-use subscription key for smoke testing. Production
// consumers should have their own per-team subscriptions.

resource starterSubscription 'Microsoft.ApiManagement/service/subscriptions@2024-06-01-preview' = {
  parent: apim
  name: 'aisec-demo'
  properties: {
    displayName: 'AISec Demo Subscription'
    scope: openaiApi.id
    state: 'active'
    allowTracing: false
  }
}

// ── Outputs ────────────────────────────────────────────────────────────────

output apimName string = apim.name
output apimResourceId string = apim.id
output apimPrincipalId string = apim.identity.principalId
output gatewayUrl string = apim.properties.gatewayUrl
output openaiPath string = openaiApiPath
output starterSubscriptionId string = starterSubscription.name
