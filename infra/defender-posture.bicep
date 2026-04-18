// defender-posture.bicep — Enable Microsoft Defender for Cloud pricing tiers
// Deployed at subscription scope to enable Defender plans for resource types
// used by the Foundry workload (storage, app services, key vaults, ARM).

targetScope = 'subscription'

@description('Enable Defender for Storage Accounts')
param enableStorageDefender bool = true

@description('Enable Defender for App Services')
param enableAppServiceDefender bool = true

@description('Enable Defender for Key Vaults')
param enableKeyVaultDefender bool = true

@description('Enable Defender for ARM (Resource Manager)')
param enableArmDefender bool = true

@description('Enable Defender for AI services (Data security for AI interactions)')
param enableAIDefender bool = true

// ── Defender for Storage ────────────────────────────────────────────────────

resource storageDefender 'Microsoft.Security/pricings@2024-01-01' = if (enableStorageDefender) {
  name: 'StorageAccounts'
  properties: {
    pricingTier: 'Standard'
  }
}

// ── Defender for App Services ───────────────────────────────────────────────

resource appServiceDefender 'Microsoft.Security/pricings@2024-01-01' = if (enableAppServiceDefender) {
  name: 'AppServices'
  properties: {
    pricingTier: 'Standard'
  }
}

// ── Defender for Key Vaults ─────────────────────────────────────────────────

resource keyVaultDefender 'Microsoft.Security/pricings@2024-01-01' = if (enableKeyVaultDefender) {
  name: 'KeyVaults'
  properties: {
    pricingTier: 'Standard'
  }
}

// ── Defender for ARM ────────────────────────────────────────────────────────

resource armDefender 'Microsoft.Security/pricings@2024-01-01' = if (enableArmDefender) {
  name: 'Arm'
  properties: {
    pricingTier: 'Standard'
  }
}

// ── Defender for AI — "Data security for AI interactions" ───────────────────
// Enables Purview DSPM for AI visibility into Foundry prompt/response traffic
// and populates the Defender XDR "AI agents" inventory. Extensions:
//   AIModelScanner             — model supply-chain scanning
//   AIPromptEvidence           — prompt/response capture in XDR alerts
//   AIPromptSharingWithPurview — forward activity to Purview DSPM for AI
//
// Replaces post-deploy manual step 3 from docs/post-deploy-steps.md.

resource aiDefender 'Microsoft.Security/pricings@2024-01-01' = if (enableAIDefender) {
  name: 'AI'
  properties: {
    pricingTier: 'Standard'
    extensions: [
      { name: 'AIModelScanner', isEnabled: 'True' }
      { name: 'AIPromptEvidence', isEnabled: 'True' }
      { name: 'AIPromptSharingWithPurview', isEnabled: 'True' }
    ]
  }
}
