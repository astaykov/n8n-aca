@description('Azure region for all resources')
param location string

@description('Unique suffix for resource names')
param resourceToken string

@description('PostgreSQL administrator password')
@secure()
param adminPassword string

@description('Tags to apply to all resources')
param tags object = {}

var serverName = 'psql-n8n-${resourceToken}'
var adminUsername = 'n8nadmin'

resource postgresServer 'Microsoft.DBforPostgreSQL/flexibleServers@2023-12-01-preview' = {
  name: serverName
  location: location
  tags: tags
  sku: {
    name: 'Standard_B1ms'  // Cheapest tier: 1 vCore, 2 GiB RAM
    tier: 'Burstable'
  }
  properties: {
    version: '16'
    administratorLogin: adminUsername
    administratorLoginPassword: adminPassword
    storage: {
      storageSizeGB: 32      // Minimum size
      autoGrow: 'Disabled'   // Keep costs predictable
    }
    backup: {
      backupRetentionDays: 7
      geoRedundantBackup: 'Disabled'  // Save costs
    }
    highAvailability: {
      mode: 'Disabled'       // Single instance for cost savings
    }
    // Enable auto-stop for dev/test (commented out for production)
    // maintenanceWindow: {
    //   customWindow: 'Enabled'
    //   dayOfWeek: 0
    //   startHour: 2
    //   startMinute: 0
    // }
  }
}

// Allow Azure services to connect (for Container Apps)
resource firewallRuleAzure 'Microsoft.DBforPostgreSQL/flexibleServers/firewallRules@2023-12-01-preview' = {
  parent: postgresServer
  name: 'AllowAllAzureServicesAndResourcesWithinAzureIps'
  properties: {
    startIpAddress: '0.0.0.0'
    endIpAddress: '0.0.0.0'
  }
}

resource database 'Microsoft.DBforPostgreSQL/flexibleServers/databases@2023-12-01-preview' = {
  parent: postgresServer
  name: 'n8n'
  properties: {
    charset: 'UTF8'
    collation: 'en_US.utf8'
  }
}

output serverName string = postgresServer.name
output serverFqdn string = postgresServer.properties.fullyQualifiedDomainName
output databaseName string = database.name
output adminUsername string = adminUsername
