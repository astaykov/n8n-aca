@description('Azure region for all resources')
param location string

@description('Unique suffix for resource names')
param resourceToken string

@description('Storage account name for the Azure File share')
param storageAccountName string

@secure()
@description('Storage account key for Azure File share authentication')
param storageAccountKey string

@description('Name of the Azure File share')
param fileShareName string

@description('Tags to apply to all resources')
param tags object = {}

var environmentName = 'cae-${resourceToken}'
var logAnalyticsName = 'law-${resourceToken}'

resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: logAnalyticsName
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
  }
}

resource environment 'Microsoft.App/managedEnvironments@2025-01-01' = {
  name: environmentName
  location: location
  tags: tags
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logAnalytics.properties.customerId
        sharedKey: logAnalytics.listKeys().primarySharedKey
      }
    }
  }
}

resource envStorage 'Microsoft.App/managedEnvironments/storages@2025-01-01' = {
  parent: environment
  name: 'n8ndata'
  properties: {
    azureFile: {
      accountName: storageAccountName
      accountKey: storageAccountKey
      shareName: fileShareName
      accessMode: 'ReadWrite'
    }
  }
}

output environmentId string = environment.id
output environmentName string = environment.name
output storageMountName string = envStorage.name
