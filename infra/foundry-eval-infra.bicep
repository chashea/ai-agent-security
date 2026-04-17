// foundry-eval-infra.bicep — Evaluation infrastructure: AI Search, App Insights
// Deployed at resource group scope (called as a module from foundry-core.bicep).
// Note: Bing Search API has been retired (aka.ms/BingAPIsRetirement).
// Bing grounding uses the Foundry project's built-in web search capability instead.

param location string
param aiSearchName string = 'aisec-search'
param appInsightsName string = 'aisec-appinsights'
param logAnalyticsName string = 'aisec-logs'

// ── Azure AI Search ─────────────────────────────────────────────────────────

resource aiSearch 'Microsoft.Search/searchServices@2024-06-01-preview' = {
  name: aiSearchName
  location: location
  sku: {
    name: 'standard'
  }
  properties: {
    publicNetworkAccess: 'Enabled'
    // Enable AAD-based data-plane auth alongside API keys so the lab
    // populator (which uses DefaultAzureCredential bearer tokens) can
    // create indexes and upload documents without an admin key.
    authOptions: {
      aadOrApiKey: {
        aadAuthFailureMode: 'http401WithBearerChallenge'
      }
    }
    semanticSearch: 'standard'
  }
}

// ── Log Analytics Workspace ──────────────────────────────────────────────────

resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: logAnalyticsName
  location: location
  properties: {
    sku: {
      name: 'PerGB2018'
    }
  }
}

// ── Application Insights ─────────────────────────────────────────────────────

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: appInsightsName
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logAnalytics.id
  }
}

// ── Outputs ──────────────────────────────────────────────────────────────────

output aiSearchId string = aiSearch.id
output aiSearchEndpoint string = 'https://${aiSearch.name}.search.windows.net'
output appInsightsConnectionString string = appInsights.properties.ConnectionString
