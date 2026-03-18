# n8n on Azure Container Apps

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2F%3CYOUR_GITHUB_ORG%3E%2Fn8n-aca%2Fmain%2Finfra%2Fmain.json)

> **Note:** Replace `<YOUR_GITHUB_ORG>` in the button URL above with your GitHub username/org after pushing this repo. You also need to compile the Bicep to ARM JSON first (see [Publishing](#publishing-the-deploy-to-azure-button) below).

## Architecture

| Resource | Purpose |
|---|---|
| **PostgreSQL Flexible Server** | Persistent database for workflows, credentials, and execution history (Burstable B1ms - cheapest tier) |
| **Storage Account + File Share** | Persistent storage for n8n data directory (`/home/node/.n8n`) - config files, custom nodes, static assets |
| **Container App** | Runs the `n8n` container image with HTTPS ingress on port 5678 |
| **Container Apps Environment** | Serverless hosting environment with storage mount |
| **Log Analytics Workspace** | Diagnostics & monitoring for the Container Apps Environment |

```
┌────────────────────┐
│  Internet / User   │
└────────┬───────────┘
         │ HTTPS
┌────────▼───────────────────────────────────────────┐
│  Azure Container App  (n8n)                        │
│  - Image: docker.n8n.io/n8nio/n8n:latest           │
│  - Port 5678                                       │
│  - Volume: /home/node/.n8n → Azure File Share      │
└────────┬───────────────────────────────┬───────────┘
         │                               │
         │ PostgreSQL connection         │ .n8n data
         │                               │ (config, nodes)
┌────────▼───────────────────────┐  ┌────▼───────────┐
│  PostgreSQL Flexible Server    │  │  Storage Acct  │
│  - Tier: Burstable B1ms        │  │  + File Share  │
│  - Database: n8n               │  │  (n8ndata)     │
│  - Stores: workflows,          │  └────────────────┘
│    credentials, executions     │
└────────────────────────────────┘
```

### ✅ Persistent Storage

This deployment uses **production-ready persistent storage**:
- ✅ **Workflows** → stored in PostgreSQL (survives restarts)
- ✅ **Credentials** → stored in PostgreSQL (encrypted)
- ✅ **Custom nodes** → stored on Azure Files (persistent across deployments)
- ✅ **Configuration** → stored on Azure Files (`/home/node/.n8n/config`)
- ✅ **Execution history** → stored in PostgreSQL

> **Note:** Azure Files works perfectly here because we're using PostgreSQL. There are no SQLite database files on the file share, so no file locking issues!

## Prerequisites

- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) (v2.60+)
- [Azure Developer CLI (`azd`)](https://learn.microsoft.com/azure/developer/azure-developer-cli/install-azd)
- An Azure subscription

## Quick Start with `azd`

```bash
# 1. Clone and enter the repo
git clone https://github.com/<YOUR_GITHUB_ORG>/n8n-aca.git
cd n8n-aca

# 2. Log in to Azure
azd auth login

# 3. Provision infrastructure and deploy
azd up
```

`azd up` will prompt you for:
- **Environment name** — used as a prefix/suffix for resource names
- **Azure subscription**
- **Azure location** (e.g. `eastus2`)

After deployment completes, the n8n URL is printed as output (`N8N_URL`).

## Manual Deployment (Azure CLI only)

```bash
# Create a resource group
az group create --name rg-n8n --location eastus2

# Deploy the Bicep template
az deployment group create \
  --resource-group rg-n8n \
  --template-file infra/main.bicep \
  --parameters infra/main.parameters.json
```

## Configuration

| Parameter | Default | Description |
|---|---|---|
| `location` | Resource group location | Azure region |
| `postgresAdminPassword` | Auto-generated GUID | PostgreSQL admin password (secure parameter) |
| `n8nImage` | `docker.n8n.io/n8nio/n8n:latest` | n8n container image |
| `cpuCores` | `1` | CPU cores for the container |
| `memorySize` | `2Gi` | Memory for the container |
| `fileShareName` | `n8ndata` | Azure File share name for n8n data directory |

## Cost Estimate

| Resource | Configuration | Est. Monthly Cost |
|----------|--------------|-------------------|
| Container App | 1 vCore, 2 GiB RAM | ~$15 |
| PostgreSQL Flexible | Burstable B1ms | **~$12** |
| Storage Account | LRS, <1 GB | ~$1 |
| Log Analytics | Pay-as-you-go | ~$2 |
| **Total** | | **~$30/month** |

💡 **Cost Optimization**: Enable auto-stop on PostgreSQL for dev/test environments to reduce costs to ~$1-2/month when idle.

## Publishing the "Deploy to Azure" Button

The "Deploy to Azure" button requires a compiled ARM JSON template. To generate it:

```bash
# Compile Bicep → ARM JSON
az bicep build --file infra/main.bicep --outfile infra/main.json

# Commit and push
git add infra/main.json
git commit -m "Add compiled ARM template for Deploy to Azure button"
git push
```

Then update the button URL in this README with your actual GitHub org/user:

```markdown
[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2FYOUR_GITHUB_ORG%2Fn8n-aca%2Fmain%2Finfra%2Fmain.json)
```

## Cleanup

```bash
# Remove all resources
azd down --purge

# Or manually
az Installing Custom Nodes

Custom nodes are automatically persisted on Azure Files. Install them via the n8n UI:

1. Go to **Settings** → **Community Nodes**
2. Click **Install** and enter the npm package name
3. Nodes are stored in `/home/node/.n8n/custom` (on Azure File Share)
4. Survives container restarts and redeployments

The entire `/home/node/.n8n` directory is on Azure Files, so all n8n data (config, custom nodes, static files) persists across restarts.

## Security Notes

- Container App ingress is **HTTPS-only** (HTTP not allowed)
- PostgreSQL password is **auto-generated** and passed as a secure parameter
- PostgreSQL connections are **encrypted with SSL/TLS**
- Storage account enforces **TLS 1.2** and disables public blob access
- PostgreSQL firewall allows **Azure services only** (not public internet)
- For production: Enable **private endpoints** for PostgreSQL and Storage

### Azure Files Permission Limitation

Azure Files uses the SMB/CIFS protocol, which **doesn't support Unix file permissions** (chmod). For this reason, `N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS=false` is set in the deployment.

**This is not a security vulnerability** because:
- PostgreSQL stores all sensitive data (credentials are encrypted at rest)
- Azure Files access is controlled by storage account keys (already secure)
- The container environment is isolated within Azure Container Apps
- File share is only accessible to the container app via private mount

## Advanced Configuration

### Enable PostgreSQL Auto-Stop (Dev/Test)

Uncomment in [infra/modules/postgres.bicep](infra/modules/postgres.bicep):

```bicep
maintenanceWindow: {
  customWindow: 'Enabled'
  dayOfWeek: 0
  startHour: 2
  startMinute: 0
}
```

Then use Azure CLI to configure auto-stop:

```bash
az postgres flexible-server update \
  --resource-group <your-rg> \
  --name <postgres-server-name> \
  --auto-pause-delay 1440  # Minutes (24 hours)
```

### Scaling

```bash
# Scale the container app
az containerapp update \
  --name <app-name> \
  --resource-group <rg-name> \
  --min-replicas 1 \
  --max-replicas 3

# Scale PostgreSQL
az postgres flexible-server update \
  --resource-group <rg-name> \
  --name <postgres-server-name> \
  --sku-name Standard_B2s  # 2 vCores
```
- Storage account enforces **TLS 1.2** and disables public blob access
- **No persistent storage configured** (ephemeral only)
- For production with PostgreSQL, use **private endpoints** and **firewall rules**
