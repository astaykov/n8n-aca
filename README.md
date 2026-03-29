# n8n on Azure Container Apps + Entra Agent ID

> Fully-automated end-to-end deployment: n8n on Azure Container Apps, Entra Agent ID, and Microsoft Graph MCP Server for Enterprise — configured from a single command.

---

## What this deploys

`azd provision` provisions all Azure infrastructure **and** fully configures n8n in a single unattended run. There are no manual steps in the n8n UI.

### Azure infrastructure

| Resource | Purpose |
|---|---|
| **Container Apps Environment** | Hosts n8n and the test SPA |
| **n8n Container App** | Runs `n8n` with HTTPS ingress |
| **SPA Container App** | Test SPA for the OBO webhook flow |
| **PostgreSQL Flexible Server** | Persistent store for workflows, credentials, executions (Burstable B1ms) |
| **Storage Account + File Share** | Persistent `/home/node/.n8n` — community nodes and config survive restarts |
| **Azure OpenAI** | GPT model deployment used by the AI agent workflows |
| **Container Registry** | Hosts the SPA container image |
| **Log Analytics Workspace** | Diagnostics |

### Entra objects (created once, reused on re-runs)

| Object | Purpose |
|---|---|
| **Agent Identity Blueprint** | App registration that issues tokens on behalf of Agent Identities via Federated Identity Credentials |
| **Agent Identity SP** | The AI agent's service principal — acquires Graph/MCP tokens autonomously |
| **Agent User** | Cloud-only user identity that enables delegated (OBO) token flows |
| **SPA app registration** | Client app for the webhook demo — pre-configured with redirect URIs and Blueprint API permission |

### n8n configuration (fully automated)

Everything below is applied automatically by the postprovision hook — no browser interaction needed after Entra sign-in:

```
✓  Owner account created
✓  Community node installed and reloaded  (@astaykov/n8n-nodes-entraagentid)
✓  API key generated
✓  5 credentials created with real values wired in
✓  3 workflows imported with credential IDs already substituted
✓  Trigger workflow activated
```

**Credentials created:**

| Name | Type | Used for |
|---|---|---|
| `EntraAgentID - Autonomous` | `entraAgentIDApi` | App-only Graph API token (no user) |
| `EntraAgentID - Agent User OBO` | `entraAgentIDApi` | Delegated token on behalf of the Agent User |
| `Azure OpenAI - <deployment>` | `azureOpenAiApi` | LLM nodes in AI agent workflows |
| `AgentID Auth Manager - Access Token` | `httpHeaderAuth` | Token forwarding from Auth Manager to downstream nodes |
| `Bearer from AuthManager` | `httpBearerAuth` | Bearer token forwarding for MCP calls |

**Workflows imported:**

| Workflow | Active | Description |
|---|---|---|
| `Agent ID Auth Manager - Agent User with MCP Enterprise` | ✓ | Acquires a delegated MCP token for the Agent User and forwards it to a sub-workflow |
| `HTTP Request with autonomous agent token` | ✓ | Demonstrates an autonomous agent calling Microsoft Graph directly with an app-only token |
| `webhook - assistive agent (on-behalf-of)` | ✓ | Webhook entry point — receives a Bearer token from the SPA, calls the Auth Manager, and responds via the Graph MCP Server on behalf of the signed-in user |

---

## Prerequisites

- [Azure Developer CLI (`azd`)](https://learn.microsoft.com/azure/developer/azure-developer-cli/install-azd) v1.9+
- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) v2.60+
- PowerShell 7.4+ (comes with Windows 11 / available on all platforms)
- [Microsoft.Entra PowerShell module](https://learn.microsoft.com/powershell/entra-powershell/) v1.2+ — installed automatically if missing
- An Azure subscription with quota for Azure OpenAI (GPT-4o or similar)
- **Entra role:** Global Administrator **or** Application Administrator (needed to create app registrations and grant admin consent)

---

## Quick start

### 1. Clone and configure

```powershell
git clone https://github.com/<YOUR_GITHUB_ORG>/n8n-aca.git
cd n8n-aca
```

Open `infra/main.parameters.json` and set your Entra tenant ID:

```json
"entraTenantId": {
  "value": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
}
```

Optionally adjust `location`, `openAiLocation`, and `openAiDeploymentName` to match your subscription's available regions and quota.

### 2. Log in to Azure

```powershell
azd auth login
```

### 3. Create an azd environment and provision

```powershell
azd env new my-n8n
azd env set AZURE_SUBSCRIPTION_ID xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
azd env set AZURE_LOCATION northeurope
azd env set AZURE_RESOURCE_GROUP rg-my-n8n
azd provision
```

`azd env new` creates a local environment file (`.azure/<name>/.env`). The three `azd env set` calls pre-populate it so `azd provision` doesn't interactively prompt you for subscription, location, or resource group.

`azd provision` will:

1. Deploy all Azure resources
2. Trigger the `postprovision` hook automatically, which:
   - **Opens a browser** for a one-time Entra sign-in (Global Admin / App Admin required)
   - Creates or reuses the Blueprint app, Agent Identity SP, and Agent User
   - Enables the Microsoft Graph MCP Server for Enterprise in your tenant
   - Waits for n8n to become ready
   - Creates the owner account and logs in
   - Installs the `@astaykov/n8n-nodes-entraagentid` community node (n8n restarts)
   - Creates all 5 credentials with real values
   - Imports all 3 workflows with credential IDs already substituted
   - Activates the trigger workflows

When complete, the script prints your n8n URL and a summary.

### 4. (Optional) Deploy the test SPA

The test SPA is a static JavaScript app that demonstrates the OBO webhook flow from a browser. Deploy it after provisioning:

```powershell
azd deploy spa
```

---

## Re-running / idempotency

`azd provision` is fully idempotent:

- Azure resources that already exist are skipped by Bicep
- Entra object IDs (Blueprint, Agent Identity, Agent User, Blueprint secret) are saved to the azd environment after the first run and reused on subsequent runs — no re-creation, no extra Entra sign-in prompts
- n8n configuration (credentials, workflows) is applied fresh each run, which allows repairing a broken state

To re-run just the postprovision scripts without touching infrastructure:

```powershell
azd provision   # Bicep detects no changes, runs hooks only
```

---

## Running the scripts manually

The postprovision hook calls two scripts that can also be run standalone.

### Full end-to-end (Entra + n8n)

```powershell
.\scripts\Run-All.ps1 `
    -TenantId  "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
    -N8nUrl    "https://ca-n8n-<token>.northeurope.azurecontainerapps.io"
```

### n8n configuration only (no Entra)

```powershell
.\scripts\Configure-N8n.ps1 `
    -N8nUrl          "https://ca-n8n-<token>.northeurope.azurecontainerapps.io" `
    -OwnerEmail      "admin@contoso.com" `
    -OwnerPassword   "MyStr0ngPassword!" `
    -SkipNodeInstall                    # omit on first run
```

### Entra setup only

```powershell
.\scripts\Setup-EntraAgentId.ps1 `
    -TenantId  "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
    -N8nUrl    "https://ca-n8n-<token>.northeurope.azurecontainerapps.io"
```

---

## Architecture

```
                         ┌──────────────────────────────────────────────┐
Browser / SPA ──HTTPS──► │  webhook - assistive agent (on-behalf-of)    │
                         │                                              │
                         │  ① receive Bearer token from SPA            │
                         │  ② call Auth Manager workflow               │
                         │     └─ Blueprint creds ──FIC──► AgentID SP  │
                         │            └──OBO──► Agent User token        │
                         │  ③ call Graph MCP Server with Agent token    │
                         └────────────────────────┬─────────────────────┘
                                                  │ MCP (delegated token)
                                                  ▼
                                 ┌──────────────────────────────┐
                                 │  Graph MCP Server            │
                                 │  mcp.svc.cloud.microsoft     │
                                 └──────────────────────────────┘

                         ┌──────────────────────────────────────────────┐
                         │  HTTP Request with autonomous agent token     │
                         │                                              │
                         │  Blueprint creds ──FIC──► AgentID SP         │
                         │                    └──► app-only Graph token  │
                         └────────────────────────┬─────────────────────┘
                                                  │ REST (app token)
                                                  ▼
                                 ┌──────────────────────────────┐
                                 │  Microsoft Graph API         │
                                 │  graph.microsoft.com         │
                                 └──────────────────────────────┘
```

| Component | Description |
|---|---|
| **Agent Identity Blueprint** | App registration that acts as a token factory — issues tokens for Agent Identities without storing credentials on the agent |
| **Agent Identity SP** | Service principal with no credentials; Blueprint acquires tokens on its behalf via Federated Identity Credentials |
| **Agent User** | Cloud-only digital employee; enables delegated OBO flows with user-level Graph and MCP access |
| **Auth Manager node** | n8n community node that manages token acquisition and AES-256-GCM caching per workflow run |
| **Graph MCP Server for Enterprise** | Microsoft-hosted MCP endpoint (`https://mcp.svc.cloud.microsoft/enterprise`) that translates MCP tool calls into Microsoft Graph API requests |

---

## MCP Server scopes granted

The setup grants the following delegated `MCP.*` scopes to the Agent Identity SP:

| Scope | Allows |
|---|---|
| `MCP.User.Read.All` | Read all users |
| `MCP.Organization.Read.All` | Read tenant org info |
| `MCP.Group.Read.All` | Read all groups |
| `MCP.GroupMember.Read.All` | Read group memberships |
| `MCP.Application.Read.All` | Read app registrations and service principals |
| `MCP.AuditLog.Read.All` | Read sign-in and audit logs |
| `MCP.Reports.Read.All` | Read M365 usage reports |
| `MCP.Policy.Read.All` | Read conditional access policies |
| `MCP.Domain.Read.All` | Read verified domains |
| `MCP.Device.Read.All` | Read Entra-registered devices |

To add more scopes, edit the `$MCP_SCOPES` array in [scripts/Setup-EntraAgentId.ps1](scripts/Setup-EntraAgentId.ps1) and re-run `azd provision`.

> `MCP.*` scopes mirror their Graph counterparts (e.g. `MCP.User.Read.All` ↔ `User.Read.All`). The MCP Server only supports delegated permission flows — use the autonomous credential for app-only Graph calls.

---

## Cost estimate

| Resource | Configuration | Est. monthly |
|---|---|---|
| n8n Container App | 1 vCore, 2 GiB | ~$15 |
| SPA Container App | 0.25 vCore, 0.5 GiB | ~$4 |
| PostgreSQL Flexible Server | Burstable B1ms | ~$12 |
| Azure OpenAI | Pay-per-token (GPT-4o) | varies |
| Storage Account | LRS, < 1 GB | ~$1 |
| Log Analytics | Pay-as-you-go | ~$2 |
| **Total (ex. OpenAI)** | | **~$34/month** |

## Cleanup

```powershell
azd down --purge
```

This removes all Azure resources. Entra objects (Blueprint app, Agent Identity, Agent User) are **not** deleted automatically — remove them manually in the Entra portal if no longer needed.
