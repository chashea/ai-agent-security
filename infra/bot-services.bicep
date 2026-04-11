// bot-services.bicep — Storage, Function App, role assignments for bot infrastructure
// Deployed at resource group scope.

param location string
param storageAccountName string
param funcAppName string

@description('Foundry account resource ID for Cognitive Services User role assignment')
param foundryAccountId string

// ── Storage Account ─────────────────────────────────────────────────────────

resource storage 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: storageAccountName
  location: location
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
}

// ── Function App ────────────────────────────────────────────────────────────

resource funcApp 'Microsoft.Web/sites@2023-01-01' = {
  name: funcAppName
  location: location
  kind: 'functionapp,linux'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    reserved: true
    siteConfig: {
      pythonVersion: '3.11'
      linuxFxVersion: 'python|3.11'
      appSettings: [
        { name: 'FUNCTIONS_WORKER_RUNTIME', value: 'python' }
        { name: 'FUNCTIONS_EXTENSION_VERSION', value: '~4' }
        { name: 'AzureWebJobsStorage__accountName', value: storage.name }
      ]
    }
  }
}

// ── SCM Basic Auth Policies ─────────────────────────────────────────────────

resource scmPolicy 'Microsoft.Web/sites/basicPublishingCredentialsPolicies@2023-12-01' = {
  parent: funcApp
  name: 'scm'
  properties: {
    allow: true
  }
}

resource ftpPolicy 'Microsoft.Web/sites/basicPublishingCredentialsPolicies@2023-12-01' = {
  parent: funcApp
  name: 'ftp'
  properties: {
    allow: true
  }
}

// ── Role Assignments (Function App MSI) ─────────────────────────────────────

// Cognitive Services User on Foundry account
resource roleCognitiveServicesUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(funcApp.id, 'CognitiveServicesUser', foundryAccountId)
  scope: resourceGroup()
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'a97b65f3-24c7-4388-baec-2e87135dc908')
    principalId: funcApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// Storage Blob Data Owner on storage account
resource roleStorageBlobOwner 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(funcApp.id, 'StorageBlobDataOwner', storage.id)
  scope: storage
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b')
    principalId: funcApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// Storage Queue Data Contributor on storage account
resource roleStorageQueueContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(funcApp.id, 'StorageQueueDataContributor', storage.id)
  scope: storage
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '974c5e8b-45b9-4653-ba55-5f855dd0fb88')
    principalId: funcApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// Storage Table Data Contributor on storage account
resource roleStorageTableContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(funcApp.id, 'StorageTableDataContributor', storage.id)
  scope: storage
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3')
    principalId: funcApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// ── Outputs ─────────────────────────────────────────────────────────────────

output funcAppName string = funcApp.name
output funcAppPrincipalId string = funcApp.identity.principalId
output storageAccountName string = storage.name
