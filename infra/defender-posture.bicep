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
