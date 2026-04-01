@description('Azure region for the Static Web App.')
param swaLocation string

@description('Unique suffix for resource names.')
param resourceToken string

@description('Tags to apply to all resources.')
param tags object = {}

resource swa 'Microsoft.Web/staticSites@2023-12-01' = {
  name: 'swa-${resourceToken}'
  location: swaLocation
  // azd-service-name must match the service key in azure.yaml so `azd deploy spa` targets this resource.
  tags: union(tags, { 'azd-service-name': 'spa' })
  sku: {
    name: 'Free'
    tier: 'Free'
  }
  properties: {}
}

output defaultHostname string = swa.properties.defaultHostname
output appName string = swa.name
output appUrl string = 'https://${swa.properties.defaultHostname}'
output resourceId string = swa.id
