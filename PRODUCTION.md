# Production Deployment with PostgreSQL

The default deployment uses **ephemeral storage** with SQLite, which means:
- ⚠️ **Workflows and data are lost** when the container restarts
- ⚠️ Not suitable for production use

## Why Not Azure Files with SQLite?

SQLite requires proper file locking, which **doesn't work reliably on Azure Files** (or any network file share). You'll encounter:
- `SQLITE_BUSY: database is locked` errors
- Permission errors (`EPERM: operation not permitted`)
- Data corruption risks

## Production-Ready Solution: PostgreSQL

For production deployments, use **Azure Database for PostgreSQL** instead of SQLite.

### Option 1: Quick PostgreSQL Setup

Add these parameters to your n8n container app:

```bicep
env: [
  {
    name: 'DB_TYPE'
    value: 'postgresdb'
  }
  {
    name: 'DB_POSTGRESDB_HOST'
    value: '<your-postgres-server>.postgres.database.azure.com'
  }
  {
    name: 'DB_POSTGRESDB_PORT'
    value: '5432'
  }
  {
    name: 'DB_POSTGRESDB_DATABASE'
    value: 'n8n'
  }
  {
    name: 'DB_POSTGRESDB_USER'
    value: '<username>'
  }
  {
    name: 'DB_POSTGRESDB_PASSWORD'
    secretRef: 'postgres-password'
  }
]
```

### Option 2: Full Bicep Module (Recommended)

Create `infra/modules/postgres.bicep`:

```bicep
@description('Azure region for all resources')
param location string

@description('Unique suffix for resource names')
param resourceToken string

@description('Tags to apply to all resources')
param tags object = {}

var serverName = 'psql-n8n-${resourceToken}'

resource postgresServer 'Microsoft.DBforPostgreSQL/flexibleServers@2023-12-01-preview' = {
  name: serverName
  location: location
  tags: tags
  sku: {
    name: 'Standard_B1ms'
    tier: 'Burstable'
  }
  properties: {
    version: '16'
    administratorLogin: 'n8nadmin'
    administratorLoginPassword: newGuid() // Generate random password
    storage: {
      storageSizeGB: 32
    }
    backup: {
      backupRetentionDays: 7
      geoRedundantBackup: 'Disabled'
    }
    highAvailability: {
      mode: 'Disabled'
    }
  }
}

resource database 'Microsoft.DBforPostgreSQL/flexibleServers/databases@2023-12-01-preview' = {
  parent: postgresServer
  name: 'n8n'
}

// Allow Azure services to connect
resource firewallRule 'Microsoft.DBforPostgreSQL/flexibleServers/firewallRules@2023-12-01-preview' = {
  parent: postgresServer
  name: 'AllowAzureServices'
  properties: {
    startIpAddress: '0.0.0.0'
    endIpAddress: '0.0.0.0'
  }
}

output serverFqdn string = postgresServer.properties.fullyQualifiedDomainName
output databaseName string = database.name
output adminUsername string = postgresServer.properties.administratorLogin
```

Then update `infra/modules/n8n-app.bicep` to include the database connection environment variables.

### Option 3: Use Container Apps Built-in Service Connector

```bash
# After deploying the base infrastructure
az containerapp connection create postgres-flexible \
  --resource-group <your-rg> \
  --name <your-container-app-name> \
  --target-resource-group <your-rg> \
  --server <postgres-server-name> \
  --database n8n \
  --client-type dotnet
```

## Alternative: External PostgreSQL

You can also use:
- **Azure Database for PostgreSQL Flexible Server** (recommended)
- **Azure Database for PostgreSQL Single Server** (legacy)
- Any external PostgreSQL instance (e.g., Supabase, Neon, etc.)

Just provide the connection details via environment variables.

## Cost Considerations

| Service | Estimated Cost/Month |
|---------|---------------------|
| Container App (B1ms equivalent) | ~$15 |
| PostgreSQL Burstable B1ms | ~$12 |
| Storage Account (if needed) | ~$2 |
| **Total** | **~$29/month** |

## Migration Path

If you have existing workflows in the ephemeral deployment:

1. Export workflows from the UI (Settings → Workflows → Export)
2. Deploy the PostgreSQL-backed version
3. Import workflows to the new deployment

