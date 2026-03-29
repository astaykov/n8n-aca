@description('Azure region for all resources')
param location string

@description('Unique suffix for resource names')
param resourceToken string

@description('Container Apps Environment resource ID')
param environmentId string

@description('Name of the storage mount registered on the environment for n8n data')
param storageMountName string

@description('PostgreSQL server FQDN')
param postgresHost string

@description('PostgreSQL database name')
param postgresDatabaseName string

@description('PostgreSQL admin username')
param postgresUsername string

@secure()
@description('PostgreSQL admin password')
param postgresPassword string

@description('n8n container image')
param n8nImage string = 'docker.n8n.io/n8nio/n8n:latest'

@description('CPU cores allocated to the container (e.g. 0.5, 1, 2)')
param cpuCores string = '1'

@description('Memory allocated to the container (e.g. 1Gi, 2Gi)')
param memorySize string = '2Gi'

@description('Tags to apply to all resources')
param tags object = {}

var appName = 'ca-n8n-${resourceToken}'

// Reference the existing Container Apps Environment to get its default domain
resource environment 'Microsoft.App/managedEnvironments@2025-01-01' existing = {
  name: last(split(environmentId, '/'))
}

resource n8nApp 'Microsoft.App/containerApps@2025-01-01' = {
  name: length(appName) > 32 ? substring(appName, 0, 32) : appName
  location: location
  tags: tags
  properties: {
    managedEnvironmentId: environmentId
    configuration: {
      ingress: {
        external: true
        targetPort: 5678
        transport: 'http'
        allowInsecure: false
      }
    }
    template: {
      volumes: [
        {
          name: 'n8n-data'
          storageName: storageMountName
          storageType: 'AzureFile'
        }
      ]
      containers: [
        {  
          name: 'n8n'
          image: n8nImage
          resources: {
            cpu: json(cpuCores)
            memory: memorySize
          }
          // On startup: install community node into the Azure Files mount, then launch n8n.
          // The node_modules directory persists on Azure Files so reinstalls are skipped on restart.
          command: [
            '/bin/sh'
            '-c'
            'mkdir -p /home/node/.n8n/nodes && cd /home/node/.n8n/nodes && (test -d node_modules/@astaykov/n8n-nodes-entraagentid || npm install @astaykov/n8n-nodes-entraagentid --no-save 2>&1 | head -20) || true; exec n8n'
          ]
          env: [
            {
              name: 'N8N_PORT'
              value: '5678'
            }
            {
              name: 'N8N_PROTOCOL'
              value: 'https'
            }
            // Tell n8n its public URL for webhooks and chat
            {
              name: 'WEBHOOK_URL'
              value: 'https://${length(appName) > 32 ? substring(appName, 0, 32) : appName}.${environment.properties.defaultDomain}'
            }
            {
              name: 'N8N_EDITOR_BASE_URL'
              value: 'https://${length(appName) > 32 ? substring(appName, 0, 32) : appName}.${environment.properties.defaultDomain}'
            }
            {
              name: 'GENERIC_TIMEZONE'
              value: 'UTC'
            }
            // Azure Files doesn't support Unix chmod operations (SMB/CIFS limitation)
            // This is required for Azure Files compatibility, not a security issue
            {
              name: 'N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS'
              value: 'false'
            }
            // PostgreSQL Database Configuration
            {
              name: 'DB_TYPE'
              value: 'postgresdb'
            }
            {
              name: 'DB_POSTGRESDB_HOST'
              value: postgresHost
            }
            {
              name: 'DB_POSTGRESDB_PORT'
              value: '5432'
            }
            {
              name: 'DB_POSTGRESDB_DATABASE'
              value: postgresDatabaseName
            }
            {
              name: 'DB_POSTGRESDB_USER'
              value: postgresUsername
            }
            {
              name: 'DB_POSTGRESDB_PASSWORD'
              value: postgresPassword
            }
            // PostgreSQL requires SSL/TLS encryption
            {
              name: 'DB_POSTGRESDB_SSL_ENABLED'
              value: 'true'
            }
            {
              name: 'DB_POSTGRESDB_SSL_REJECT_UNAUTHORIZED'
              value: 'false'
            }
            // Enable the public REST API (required for workflow import and API key creation)
            {
              name: 'N8N_PUBLIC_API_DISABLED'
              value: 'false'
            }
            // Allow community nodes (e.g. @astaykov/n8n-nodes-EntraAgentID) to be used as AI tools
            {
              name: 'N8N_COMMUNITY_PACKAGES_ALLOW_TOOL_USAGE'
              value: 'true'
            }
          ]
          volumeMounts: [
            {
              volumeName: 'n8n-data'
              mountPath: '/home/node/.n8n'
            }
          ]
        }
      ]
      scale: {
        minReplicas: 1
        maxReplicas: 1
      }
    }
  }
}

output appUrl string = 'https://${n8nApp.properties.configuration.ingress.fqdn}'
output appName string = n8nApp.name
