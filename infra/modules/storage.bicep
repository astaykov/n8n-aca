@description('Azure region for all resources')
param location string

@description('Unique suffix for resource names')
param resourceToken string

@description('Name of the file share for n8n data directory')
param fileShareName string = 'n8ndata'

@description('Tags to apply to all resources')
param tags object = {}

// Ensure name is 3–24 chars, starts with 'st', alphanumeric only
var rawName = 'st${replace(resourceToken, '-', '')}'
var storageAccountName = substring(rawName, 0, min(length(rawName), 24))

#disable-next-line BCP334
resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageAccountName
  location: location
  tags: tags
  kind: 'StorageV2'
  sku: {
    name: 'Standard_LRS'
  }
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    supportsHttpsTrafficOnly: true
  }
}

resource fileServices 'Microsoft.Storage/storageAccounts/fileServices@2023-05-01' = {
  parent: storageAccount
  name: 'default'
}

resource fileShare 'Microsoft.Storage/storageAccounts/fileServices/shares@2023-05-01' = {
  parent: fileServices
  name: fileShareName
  properties: {
    shareQuota: 5 // 5 GB for .n8n directory (config, nodes, static files) – adjust as needed
  }
}

output storageAccountName string = storageAccount.name
#disable-next-line outputs-should-not-contain-secrets
output storageAccountKey string = storageAccount.listKeys().keys[0].value
output fileShareName string = fileShare.name
