targetScope = 'resourceGroup'

@description('Azure region for all resources. Defaults to the resource group location.')
param location string = resourceGroup().location

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

var tags = {
  'azd-env-name': resourceToken
  application: 'n8n'
}

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

// ── Outputs ────────────────────────────────────────────────────────────────
output N8N_URL string = n8nApp.outputs.appUrl
output CONTAINER_APP_NAME string = n8nApp.outputs.appName
output POSTGRES_SERVER string = postgres.outputs.serverName
output POSTGRES_DATABASE string = postgres.outputs.databaseName
output STORAGE_ACCOUNT_NAME string = storage.outputs.storageAccountName
