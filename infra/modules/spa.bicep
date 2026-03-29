@description('Azure region for all resources')
param location string

@description('Unique suffix for resource names')
param resourceToken string

@description('Container Apps Environment resource ID')
param environmentId string

@description('ACR login server (e.g. acr1234.azurecr.io)')
param registryLoginServer string

@description('ACR admin username')
param registryUsername string

@secure()
@description('ACR admin password')
param registryPassword string

// ── SPA configuration (injected into the container as env vars at startup) ──
@description('Entra app registration client ID for the SPA (MSAL clientId).')
param spaClientId string = ''

@description('Entra tenant ID.')
param tenantId string = ''

@description('''
Blueprint OAuth2 app ID (NOT the Blueprint object ID).
Used to construct the API scope: api://<blueprintAppId>/access_as_user.
''')
param blueprintAppId string = ''

@description('n8n production webhook URL for the OBO workflow.')
param n8nWebhookUrl string = ''

@description('n8n test webhook URL for the OBO workflow.')
param n8nWebhookTestUrl string = ''

@description('Tags to apply to all resources')
param tags object = {}

// Reference the managed environment to get its default domain for the redirect URI
resource environment 'Microsoft.App/managedEnvironments@2025-01-01' existing = {
  name: last(split(environmentId, '/'))
}

var appName = take('ca-spa-${resourceToken}', 32)
var appFqdn = '${appName}.${environment.properties.defaultDomain}'

resource spaApp 'Microsoft.App/containerApps@2025-01-01' = {
  name: appName
  location: location
  // azd-service-name tag lets `azd deploy spa` identify this Container App
  tags: union(tags, { 'azd-service-name': 'spa' })
  properties: {
    managedEnvironmentId: environmentId
    configuration: {
      ingress: {
        external: true
        targetPort: 80
        transport: 'http'
        allowInsecure: false
      }
      registries: [
        {
          server: registryLoginServer
          username: registryUsername
          passwordSecretRef: 'registry-password'
        }
      ]
      secrets: [
        {
          name: 'registry-password'
          value: registryPassword
        }
      ]
    }
    template: {
      containers: [
        {
          name: 'spa'
          // Initial placeholder image — `azd deploy spa` replaces this with the built image.
          image: 'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest'
          resources: {
            cpu: json('0.25')
            memory: '0.5Gi'
          }
          env: [
            { name: 'SPA_CLIENT_ID',        value: spaClientId }
            { name: 'SPA_TENANT_ID',        value: tenantId }
            { name: 'SPA_REDIRECT_URI',     value: 'https://${appFqdn}/redirect.html' }
            { name: 'SPA_BLUEPRINT_APP_ID', value: blueprintAppId }
            { name: 'N8N_WEBHOOK_URL',      value: n8nWebhookUrl }
            { name: 'N8N_WEBHOOK_TEST_URL', value: n8nWebhookTestUrl }
          ]
        }
      ]
      scale: {
        // Scale to zero when idle to minimise cost (test app only)
        minReplicas: 0
        maxReplicas: 1
      }
    }
  }
}

output appUrl string = 'https://${spaApp.properties.configuration.ingress.fqdn}'
output appName string = spaApp.name
output appFqdn string = appFqdn
