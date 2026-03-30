targetScope = 'resourceGroup'

@description('Azure region for all resources.')
param location string = 'northeurope'

@description('A unique token used to generate globally unique resource names.')
param resourceToken string = toLower(uniqueString(resourceGroup().id, location))

@description('Name of the Azure File share for n8n data directory.')
param fileShareName string = 'n8ndata'

@description('PostgreSQL administrator password. If not provided, a random password will be generated.')
@secure()
param postgresAdminPassword string = newGuid()

@description('n8n container image to deploy.')
param n8nImage string = 'docker.n8n.io/n8nio/n8n:latest'

@description('CPU cores allocated to the n8n container.')
param cpuCores string = '1'

@description('Memory allocated to the n8n container.')
param memorySize string = '2Gi'

@description('Entra tenant ID where Agent ID objects (Blueprint, Agent Identity, Agent User) will be provisioned. Leave empty to skip Entra setup.')
param entraTenantId string = ''

@description('OAuth2 app ID (appId) of the Blueprint Service Principal. Set after first Entra provisioning to wire the SPA scope correctly.')
param spaBlueprintAppId string = ''

@description('Client ID of the SPA app registration. Set after first Entra provisioning.')
param spaClientId string = ''

@description('Azure OpenAI model deployment name. Must match the deployment name used in n8n workflow nodes (default: gpt-5.4).')
param openAiDeploymentName string = 'gpt-5.4'

@description('Azure OpenAI model to deploy. Must be available in the target region.')
param openAiModelName string = 'gpt-4o'

@description('Azure OpenAI model version.')
param openAiModelVersion string = '2024-11-20'

@description('Azure OpenAI deployment SKU. Standard works in all regions; GlobalStandard only in select US regions.')
param openAiDeploymentSku string = 'GlobalStandard'

@description('Tokens-per-minute capacity (in thousands). 230 = 230K TPM.')
param openAiTpmCapacity int = 230

@description('Separate resource group for Azure OpenAI (deployed in a US region for model availability).')
param openAiResourceGroupName string = 'rg-n8n-openai'

@description('Azure region for the Azure OpenAI resource. US regions support GlobalStandard SKU and latest models.')
param openAiLocation string = 'eastus2'

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
    n8nImage: n8nImage
    cpuCores: cpuCores
    memorySize: memorySize
    tags: tags
  }
}

// ── Azure Container Registry ──────────────────────────────────────────────
module acr 'modules/acr.bicep' = {
  name: 'acr'
  params: {
    location: location
    resourceToken: resourceToken
    tags: tags
  }
}

// ── Test SPA Container App ─────────────────────────────────────────────────
// Webhook path is fixed by the workflow JSON (deterministic on every import).
var webhookPath = 'caef5339-caaa-4228-999d-89abf943bfe2'
module spa 'modules/spa.bicep' = {
  name: 'spa'
  params: {
    location: location
    resourceToken: resourceToken
    environmentId: environment.outputs.environmentId
    registryLoginServer: acr.outputs.loginServer
    registryUsername: acr.outputs.adminUsername
    registryPassword: acr.outputs.adminPassword
    spaClientId: spaClientId
    tenantId: entraTenantId
    blueprintAppId: spaBlueprintAppId
    n8nWebhookUrl: '${n8nApp.outputs.appUrl}/webhook/${webhookPath}'
    n8nWebhookTestUrl: '${n8nApp.outputs.appUrl}/webhook-test/${webhookPath}'
    tags: tags
  }
}

// ── Outputs ────────────────────────────────────────────────────────────────
output N8N_URL string = n8nApp.outputs.appUrl
output CONTAINER_APP_NAME string = n8nApp.outputs.appName
output POSTGRES_SERVER string = postgres.outputs.serverName
output POSTGRES_DATABASE string = postgres.outputs.databaseName
output STORAGE_ACCOUNT_NAME string = storage.outputs.storageAccountName
output ENTRA_TENANT_ID string = entraTenantId

// Azure OpenAI — used by postprovision.ps1 to create the azureOpenAiApi credential in n8n
output AZURE_OPENAI_RESOURCE string = openAi.outputs.resourceName
output AZURE_OPENAI_API_KEY string = openAi.outputs.apiKey
output AZURE_OPENAI_DEPLOYMENT string = openAi.outputs.deploymentName

// ACR — used by `azd deploy spa` to push the SPA Docker image
output AZURE_CONTAINER_REGISTRY_ENDPOINT string = acr.outputs.loginServer
output ACR_NAME string = acr.outputs.registryName

// SPA — used by postprovision.ps1 to update env vars after Entra provisioning
output SPA_URL string = spa.outputs.appUrl
output SPA_APP_NAME string = spa.outputs.appName
output SPA_FQDN string = spa.outputs.appFqdn
