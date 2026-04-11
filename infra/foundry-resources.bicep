// foundry-resources.bicep — Foundry account, model deployment, project
// Deployed at resource group scope (called as a module from foundry-core.bicep).

param location string
param accountName string
param projectName string
param modelDeploymentName string
param modelVersion string
param modelCapacity int

@description('Embeddings model deployment name')
param embeddingsModelName string = 'text-embedding-3-small'

// ── Foundry Account (CognitiveServices AIServices) ──────────────────────────

resource account 'Microsoft.CognitiveServices/accounts@2025-04-01-preview' = {
  name: accountName
  location: location
  kind: 'AIServices'
  sku: {
    name: 'S0'
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    allowProjectManagement: true
    publicNetworkAccess: 'Enabled'
    customSubDomainName: accountName
  }
}

// ── Model Deployment (gpt-4o GlobalStandard) ────────────────────────────────

resource modelDeployment 'Microsoft.CognitiveServices/accounts/deployments@2025-04-01-preview' = {
  parent: account
  name: modelDeploymentName
  sku: {
    name: 'GlobalStandard'
    capacity: modelCapacity
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: 'gpt-4o'
      version: modelVersion
    }
  }
}

// ── Embeddings Model Deployment ─────────────────────────────────────────────

resource embeddingsDeployment 'Microsoft.CognitiveServices/accounts/deployments@2025-04-01-preview' = {
  parent: account
  name: embeddingsModelName
  sku: {
    name: 'GlobalStandard'
    capacity: 10
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: 'text-embedding-3-small'
      version: '1'
    }
  }
  dependsOn: [modelDeployment]
}

// NOTE: Foundry Project is created via direct ARM REST in FoundryInfra.psm1
// (not Bicep) because the project resource provider has transient failures
// that require retry logic and async polling not available in Bicep.

// ── Outputs ─────────────────────────────────────────────────────────────────

output accountId string = account.id
output projectEndpoint string = 'https://${accountName}.services.ai.azure.com/api/projects/${projectName}'
output accountName string = account.name
output embeddingsDeploymentName string = embeddingsDeployment.name
output accountPrincipalId string = account.identity.principalId
