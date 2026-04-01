targetScope = 'resourceGroup'

@description('Azure region for most resources.')
param location string = 'northeurope'

@description('Azure region for the Azure OpenAI resource. US regions support GlobalStandard SKU and latest models.')
param openAiLocation string = 'eastus2'

@description('Azure region for the PostgreSQL flexible server.')
param swaLocation string = 'westeurope'

@description('A unique token used to generate globally unique resource names.')
param resourceToken string = toLower(uniqueString(resourceGroup().id, location))

@description('Name of the Azure File share for n8n data directory.')
param fileShareName string = 'n8ndata'

@description('PostgreSQL administrator password. If not provided, a random password will be generated.')
@secure()
param postgresAdminPassword string = newGuid()

@description('n8n Admin email')
param n8nAdminEmail string

@description('n8n Admin password (min 8 chars, mixed case, number)')
@secure()
param n8nAdminPassword string


@description('n8n container image to deploy.')
param n8nImage string = 'docker.n8n.io/n8nio/n8n:latest'

@description('CPU cores allocated to the n8n container.')
param cpuCores string = '1'

@description('Memory allocated to the n8n container.')
param memorySize string = '2Gi'

@description('Entra tenant ID where Agent ID objects (Blueprint, Agent Identity, Agent User) will be provisioned. Leave empty to skip Entra setup.')
param entraTenantId string = ''

@description('Azure OpenAI model deployment name. Must match the deployment name used in n8n workflow nodes (default: gpt-5.4).')
param openAiDeploymentName string = 'gpt-4o'

@description('Azure OpenAI model to deploy. Must be available in the target region.')
param openAiModelName string = 'gpt-4o'

@description('Azure OpenAI model version.')
param openAiModelVersion string = '2024-11-20'

@description('Azure OpenAI deployment SKU. Standard works in all regions; GlobalStandard only in select US regions.')
param openAiDeploymentSku string = 'GlobalStandard'

@description('Tokens-per-minute capacity (in thousands). 50 = 50K TPM.')
param openAiTpmCapacity int = 50

var tags = {
  'azd-env-name': resourceToken
  application: 'n8n'
}
// Note: tags var is used above in the rg resource — Bicep allows forward references to vars

// ── PostgreSQL Database ────────────────────────────────────────────────────
module postgres 'modules/postgres.bicep' = {
  name: 'postgres'
  params: {
    location: location
    resourceToken: resourceToken
    adminPassword: postgresAdminPassword
    tags: tags
  }
}

// ── Storage Account + File Share (for custom nodes) ───────────────────────
module storage 'modules/storage.bicep' = {
  name: 'storage'
  params: {
    location: location
    resourceToken: resourceToken
    fileShareName: fileShareName
    tags: tags
  }
}

// ── Container Apps Environment + Storage Mount ─────────────────────────────
module environment 'modules/environment.bicep' = {
  name: 'environment'
  params: {
    location: location
    resourceToken: resourceToken
    storageAccountName: storage.outputs.storageAccountName
    storageAccountKey: storage.outputs.storageAccountKey
    fileShareName: storage.outputs.fileShareName
    tags: tags
  }
}

// ── Azure OpenAI ─────────────────────────────────────────────────────────────
module openAi 'modules/openai.bicep' = {
  name: 'openai'
  params: {
    location: openAiLocation
    resourceToken: resourceToken
    deploymentName: openAiDeploymentName
    modelName: openAiModelName
    modelVersion: openAiModelVersion
    deploymentSku: openAiDeploymentSku
    tpmCapacity: openAiTpmCapacity
    tags: tags
  }
}

// ── Azure Static Web App (Test SPA) ──────────────────────────────────────
module swa 'modules/swa.bicep' = {
  name: 'swa'
  params: {
    swaLocation: swaLocation
    resourceToken: resourceToken
    tags: tags
  }
}

// ── n8n Container App ──────────────────────────────────────────────────────
module n8nApp 'modules/n8n-app.bicep' = {
  name: 'n8n-app'
  params: {
    location: location
    resourceToken: resourceToken
    environmentId: environment.outputs.environmentId
    storageMountName: environment.outputs.storageMountName
    postgresHost: postgres.outputs.serverFqdn
    postgresDatabaseName: postgres.outputs.databaseName
    postgresUsername: postgres.outputs.adminUsername
    postgresPassword: postgresAdminPassword
    n8nAdminEmail: n8nAdminEmail
    n8nAdminPassword: n8nAdminPassword
    n8nImage: n8nImage
    cpuCores: cpuCores
    memorySize: memorySize
    corsOrigin: 'https://${swa.outputs.defaultHostname}'
    tags: tags
  }
}

// ── Azure OpenAI key (separate module to avoid listKeys() race condition) ────
// dependsOn ensures the entire openai module (account + model deployment) is fully
// terminal before listKeys() is evaluated. Without this, ARM returns RequestConflict 409.
module openAiKey 'modules/openai-key.bicep' = {
  name: 'openai-key'
  dependsOn: [openAi]
  params: {
    openAiName: openAi.outputs.resourceName
  }
}

// ── Outputs ────────────────────────────────────────────────────────────────
output N8N_URL string = n8nApp.outputs.appUrl
output N8N_ADMIN_EMAIL string = n8nAdminEmail
output N8N_ADMIN_PASSWORD string = n8nAdminPassword
output CONTAINER_APP_NAME string = n8nApp.outputs.appName
output POSTGRES_SERVER string = postgres.outputs.serverName
output POSTGRES_DATABASE string = postgres.outputs.databaseName
output STORAGE_ACCOUNT_NAME string = storage.outputs.storageAccountName
output ENTRA_TENANT_ID string = entraTenantId

// Azure OpenAI — used by postprovision.ps1 to create the azureOpenAiApi credential in n8n
output AZURE_OPENAI_RESOURCE string = openAi.outputs.resourceName
output AZURE_OPENAI_API_KEY string = openAiKey.outputs.apiKey
output AZURE_OPENAI_DEPLOYMENT string = openAi.outputs.deploymentName

// SWA — used by postprovision.ps1 to generate authConfig.js and configure Entra redirect URIs
output SWA_HOSTNAME string = swa.outputs.defaultHostname
output SWA_URL string = swa.outputs.appUrl
output SWA_RESOURCE_ID string = swa.outputs.resourceId
