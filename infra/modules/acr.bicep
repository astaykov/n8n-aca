@description('Azure region for all resources')
param location string

@description('Unique suffix for resource names')
param resourceToken string

@description('Tags to apply to all resources')
param tags object = {}

// ACR name: max 50 chars, alphanumeric only, minimum 5 chars
// resourceToken is typically 13 chars (uniqueString output), so 'acr' prefix gives at least 16.
var registryName = take('acr${replace(resourceToken, '-', '')}', 50)

resource registry 'Microsoft.ContainerRegistry/registries@2023-11-01-preview' = {
  name: registryName
  location: location
  tags: union(tags, { 'azd-env-name': resourceToken })
  sku: {
    name: 'Basic'
  }
  properties: {
    adminUserEnabled: true
  }
}

output registryId string = registry.id
output registryName string = registry.name
output loginServer string = registry.properties.loginServer
output adminUsername string = registry.listCredentials().username

@secure()
output adminPassword string = registry.listCredentials().passwords[0].value
