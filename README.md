# n8n on Azure Container Apps + Entra Agent ID

> One-command deployment: n8n on Azure Container Apps with Entra Agent ID and Microsoft Graph MCP Server for Enterprise — fully automated from Azure Cloud Shell.

---
## Prerequisites

> *Important:* This is a demo oriented infrastrucure automation. It requires high privileges in your environment.

- An Azure subscription with quota for Azure OpenAI (GPT-4o or similar), PostgreSQL Flexible server, Azure Container Apps.
- **Entra role:** Global Administrator: this role is required because of the many entities created along with amdin consent to permissions. The automation will fail if you do not have active `Global Administrator` role.

**Azure Cloud Shell** (recommended) comes with everything pre-installed: Azure CLI, Azure Developer CLI (`azd`), PowerShell 7, and Git.

<details>
<summary>Running locally instead of Cloud Shell</summary>

- [Azure Developer CLI (`azd`)](https://learn.microsoft.com/azure/developer/azure-developer-cli/install-azd) v1.9+
- [Azure CLI (`az`)](https://learn.microsoft.com/cli/azure/install-azure-cli) v2.60+
- PowerShell 7.4+
- [Microsoft.Entra PowerShell module](https://learn.microsoft.com/powershell/entra-powershell/) v1.2+ — installed automatically if missing
- Git

Log in before running:

```bash
az login
azd auth login
```

Then:

```bash
git clone https://github.com/astaykov/n8n-aca.git && cd n8n-aca && azd up
```

</details>

---


## 📺 Video walkthrough

[![Watch the full setup walkthrough on YouTube](https://img.youtube.com/vi/DXKGgTTrsEc/maxresdefault.jpg)](https://www.youtube.com/watch?v=DXKGgTTrsEc)

---

## Quick start (Azure Cloud Shell)

Open [Azure Cloud Shell](https://shell.azure.com) (`PowerShell`) and run:

```bash
git clone https://github.com/astaykov/n8n-aca.git && cd n8n-aca && azd auth login && azd up
```

> In Azure Cloud Shell, `azd auth login` will display a device code — open the URL shown and enter the code to authenticate, then `azd up` continues automatically.

`azd up` will prompt you for:

| Prompt | What to enter |
|--------|--------------|
| **Environment name** | Any name (e.g. `my-n8n`) — used to isolate this deployment |
| **Azure subscription** | Select the subscription to deploy into |
| **Azure location** | Select a region (e.g. `northeurope`) |
| **n8n admin email** | Email for the n8n owner account |
| **n8n admin password** | Password for the n8n owner account (min 8 chars, mixed case, number) |

After infrastructure deploys, the postprovision hook runs automatically:

1. **Entra sign-in** — a device code is displayed; open the URL and enter the code (Global Admin or App Admin required)
2. Creates Entra Agent ID objects (Blueprint, Agent Identity, Agent User)
3. Enables the Microsoft Graph MCP Server for Enterprise
4. Waits for n8n to become ready
5. Creates the owner account
6. Installs the `@astaykov/n8n-nodes-entraagentid` community node
7. Creates all 5 credentials with real values wired in
8. Imports 3 workflows with credential IDs already substituted
9. Activates trigger workflows

When complete, the script prints your n8n URL and a summary.

> **Tenant ID** is auto-detected from your Azure login — no manual configuration needed.

---

## What this deploys

### Azure infrastructure

| Resource | Purpose |
|---|---|
| **Container Apps Environment** | Hosts n8n and the test SPA |
| **n8n Container App** | Runs the official `n8nio/n8n` image with HTTPS ingress |
| **Static Web App** | Test SPA for the OBO webhook flow |
| **PostgreSQL Flexible Server** | Persistent store for workflows, credentials, executions (Burstable B1ms) |
| **Storage Account + File Share** | Persistent `/home/node/.n8n` — community nodes and config survive restarts |
| **Azure OpenAI** | GPT model deployment used by the AI agent workflows |
| **Log Analytics Workspace** | Diagnostics |

### Entra objects (created once, reused on re-runs)

| Object | Purpose |
|---|---|
| **Agent Identity Blueprint** | App registration that issues tokens on behalf of Agent Identities via Federated Identity Credentials |
| **Agent Identity SP** | The AI agent's service principal — acquires Graph/MCP tokens autonomously |
| **Agent User** | Cloud-only user identity that enables delegated (OBO) token flows |
| **SPA app registration** | Client app for the webhook demo — pre-configured with redirect URIs and Blueprint API permission |

### n8n configuration (fully automated)

Everything below is applied automatically by the postprovision hook:

```
✓  Owner account created
✓  Community node installed  (@astaykov/n8n-nodes-entraagentid)
✓  API key generated
✓  5 credentials created with real values wired in
✓  3 workflows imported with credential IDs already substituted
✓  Trigger workflows activated
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

| Workflow | Description |
|---|---|
| `Agent ID Auth Manager - Agent User with MCP Enterprise` | Acquires a delegated MCP token for the Agent User and forwards it to a sub-workflow |
| `HTTP Request with autonomous agent token` | Demonstrates an autonomous agent calling Microsoft Graph directly with an app-only token |
| `webhook - assistive agent (on-behalf-of)` | Webhook entry point — receives a Bearer token from the SPA, calls the Auth Manager, and responds via the Graph MCP Server on behalf of the signed-in user |

---

## Deploy the test SPA (optional)

The test SPA is a static JavaScript app that demonstrates the OBO webhook flow from a browser. Deploy it after provisioning:

```bash
azd deploy spa
```

---

## Re-running / idempotency

`azd up` is fully idempotent:

- Azure resources that already exist are skipped by Bicep
- Entra object IDs (Blueprint, Agent Identity, Agent User, Blueprint secret) are saved to the azd environment after the first run and reused on subsequent runs — no re-creation, no extra Entra sign-in prompts
- n8n configuration (credentials, workflows) is applied fresh each run, which allows repairing a broken state

To re-run just the postprovision scripts without touching infrastructure:

```bash
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
    -OwnerPassword   "MyStr0ngPassword!"
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
| Static Web App | Free tier | $0 |
| PostgreSQL Flexible Server | Burstable B1ms | ~$12 |
| Azure OpenAI | Pay-per-token (GPT-4o) | varies |
| Storage Account | LRS, < 1 GB | ~$1 |
| Log Analytics | Pay-as-you-go | ~$2 |
| **Total (ex. OpenAI)** | | **~$30/month** |

## Cleanup

```bash
azd down --purge
```

This removes all Azure resources. Entra objects (Blueprint app, Agent Identity, Agent User) are **not** deleted automatically — remove them manually in the Entra portal if no longer needed.
