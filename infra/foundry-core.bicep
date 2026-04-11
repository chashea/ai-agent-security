// foundry-core.bicep — Foundry account, model deployment, and project
// Deployed at subscription scope so it can create the resource group.

targetScope = 'subscription'

@description('Azure region for all resources')
param location string

@description('Resource group name')
param resourceGroupName string

@description('Foundry account name (also used as custom subdomain)')
param accountName string

@description('Foundry project name')
param projectName string

@description('Model deployment name')
param modelDeploymentName string = 'gpt-4o'

@description('Model version')
param modelVersion string = '2024-11-20'

@description('Model capacity (tokens per minute in thousands)')
param modelCapacity int = 10

@description('Azure AI Search resource name')
param aiSearchName string = 'aisec-search'

@description('Application Insights resource name')
param appInsightsName string = 'aisec-appinsights'

@description('Log Analytics workspace name')
param logAnalyticsName string = 'aisec-logs'

@description('Embeddings model deployment name')
param embeddingsModelName string = 'text-embedding-3-small'

// ── Resource Group ──────────────────────────────────────────────────────────

resource rg 'Microsoft.Resources/resourceGroups@2021-04-01' = {
  name: resourceGroupName
  location: location
}

// ── Module: Foundry resources (deployed into the resource group) ─────────────

module foundry 'foundry-resources.bicep' = {
  name: 'foundry-resources'
  scope: rg
  params: {
    location: location
    accountName: accountName
    projectName: projectName
    modelDeploymentName: modelDeploymentName
    modelVersion: modelVersion
    modelCapacity: modelCapacity
    embeddingsModelName: embeddingsModelName
  }
}

// ── Module: Eval infrastructure (deployed into the resource group) ───────────

module evalInfra 'foundry-eval-infra.bicep' = {
  name: 'eval-infra'
  scope: rg
  params: {
    location: location
    aiSearchName: aiSearchName
    appInsightsName: appInsightsName
    logAnalyticsName: logAnalyticsName
  }
}

// ── Outputs ─────────────────────────────────────────────────────────────────

output resourceGroupName string = rg.name
output accountId string = foundry.outputs.accountId
output projectEndpoint string = foundry.outputs.projectEndpoint
output accountName string = foundry.outputs.accountName
output embeddingsDeploymentName string = foundry.outputs.embeddingsDeploymentName
output aiSearchEndpoint string = evalInfra.outputs.aiSearchEndpoint
output appInsightsConnectionString string = evalInfra.outputs.appInsightsConnectionString
output accountPrincipalId string = foundry.outputs.accountPrincipalId
