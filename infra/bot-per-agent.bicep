// bot-per-agent.bicep — Bot Service + Teams channel for a single agent
// Called in a loop from the orchestrator for each agent.

@description('Bot Service display name and resource name')
param botName string

@description('Entra app (client) ID for the bot')
param msaAppId string

@description('Tenant ID for single-tenant bot')
param tenantId string

@description('Message endpoint URL (Function App route)')
param endpoint string

// ── Bot Service ─────────────────────────────────────────────────────────────

resource bot 'Microsoft.BotService/botServices@2023-09-15-preview' = {
  name: botName
  location: 'global'
  kind: 'azurebot'
  sku: {
    name: 'F0'
  }
  properties: {
    displayName: botName
    msaAppType: 'SingleTenant'
    msaAppId: msaAppId
    msaAppTenantId: tenantId
    endpoint: endpoint
  }
}

// ── Teams Channel ───────────────────────────────────────────────────────────

resource teamsChannel 'Microsoft.BotService/botServices/channels@2023-09-15-preview' = {
  parent: bot
  name: 'MsTeamsChannel'
  location: 'global'
  properties: {
    channelName: 'MsTeamsChannel'
    properties: {
      enableCalling: false
      isEnabled: true
    }
  }
}

// ── Outputs ─────────────────────────────────────────────────────────────────

output botName string = bot.name
output botId string = bot.id
