# Copilot Instructions — n8n-aca

## Architecture

This repo deploys **n8n on Azure Container Apps** with **Entra Agent ID** integration and a **Microsoft Graph MCP Server** connection, all from a single `azd provision` command.

### Deployment flow

```
azd provision
  ├─ Bicep (infra/main.bicep) → deploys all Azure resources
  └─ postprovision hook (scripts/postprovision.ps1)
       ├─ Setup-EntraAgentId.ps1 → creates Entra objects (Blueprint, Agent Identity, Agent User, SPA app reg)
       └─ Configure-N8n.ps1 → creates owner, credentials, imports workflows, activates triggers
```

Bicep outputs flow into scripts via **azd environment variables** (stored in `.azure/{env}/.env`, gitignored). The postprovision script reads them as `$env:VAR_NAME` and also writes Entra object IDs back with `azd env set`.

### Key components

| Layer | What | Where |
|-------|------|-------|
| **IaC** | Bicep modules (Container Apps, PostgreSQL, Storage, OpenAI, Static Web App) | `infra/` |
| **Automation** | PowerShell 7+ scripts for Entra + n8n configuration | `scripts/` |
| **Workflows** | n8n workflow JSON templates with credential placeholders | `workflows/` |
| **Test SPA** | Vanilla JS + MSAL chat app for the OBO webhook demo | `test-spa/` |

### Module dependency graph

```
main.bicep
├── postgres.bicep        → PostgreSQL Flexible Server + database
├── storage.bicep          → Storage Account + File Share (n8ndata)
├── environment.bicep      → Container Apps Environment + storage mount
├── n8n-app.bicep          → n8n Container App (depends on environment, postgres, storage)
├── swa.bicep              → Static Web App for test SPA
├── openai.bicep           → Azure OpenAI account + model deployment
└── openai-key.bicep       → Fetches API key (separate module to avoid 409 race condition)
```

The n8n container uses the official `n8nio/n8n` Docker image with its default entrypoint — no startup command override. Community node installation is handled by `Configure-N8n.ps1` via the n8n public API.

## Commands

### Provision everything (infrastructure + configuration)

```powershell
azd provision
```

### Run postprovision scripts standalone

```powershell
# Full end-to-end (Entra + n8n)
.\scripts\Run-All.ps1 -TenantId "<guid>" -N8nUrl "https://ca-n8n-<token>.<region>.azurecontainerapps.io"

# n8n configuration only (skip Entra)
.\scripts\Configure-N8n.ps1 -N8nUrl "<url>" -OwnerEmail "admin@contoso.com" -OwnerPassword "P@ssw0rd!"

# Entra setup only
.\scripts\Setup-EntraAgentId.ps1 -TenantId "<guid>" -N8nUrl "<url>"
```

### Deploy the test SPA

```powershell
azd deploy spa
```

### Tear down

```powershell
azd down --purge
```

There are no build, test, or lint commands. The SPA is static files (no build step).

## Conventions

### PowerShell scripts

All scripts follow this boilerplate:

```powershell
#Requires -Version 7
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
```

Shared output helpers are defined in each script (not a shared module):

- `Write-Step` (cyan) — phase headers
- `Write-OK` (green) — success confirmations
- `Write-Note` (yellow) — informational
- `Write-Err` (red) — errors

Parameters use `[ValidatePattern(...)]` for GUIDs and `[ValidateRange(...)]` for numeric bounds. A `[switch]` flag controls optional behaviors (e.g., `-SkipNodeInstall`, `-SkipAzdUp`).

HTTP calls use a shared `$session` (`WebRequestSession`) for the initial owner setup phase (unofficial `/rest/` endpoints). After API key creation, all subsequent operations use the official `/api/v1/` public API with `X-N8N-API-KEY` header authentication.

Only these operations use unofficial `/rest/` endpoints (no official alternative):
- Readiness poll (`GET /rest/settings`)
- Owner account creation (`POST /rest/owner/setup`)
- Login + session validation (`POST /rest/login`, `GET /rest/me`)
- API key creation (`POST /rest/api-keys`)

Everything else uses the official public API (`/api/v1/`):
- Community node install (`POST /api/v1/community-packages`, with fallback to `POST /rest/community-packages` for older n8n versions)
- Credential CRUD (`GET/POST/DELETE /api/v1/credentials`)
- Workflow import (`POST /api/v1/workflows`)
- Workflow activation (`POST /api/v1/workflows/{id}/activate`)

Transient errors (HTTP 500/502/503/504) retry with exponential backoff.

### Idempotency patterns

- **Entra objects**: IDs stored in azd env (`.azure/{env}/.env`); skipped on re-run if already present.
- **n8n workflows**: Fetched by name before import; skipped if a workflow with the same name exists.
- **n8n credentials**: Deleted and recreated on each run (names must stay consistent).
- **Bicep resources**: Azure Resource Manager handles idempotency natively.

### Azure resource naming

All resources use a `resourceToken` suffix generated from `uniqueString(resourceGroup().id, location)`:

- Container App: `ca-n8n-{token}`
- PostgreSQL: `psql-n8n-{token}`
- Storage: `st{token}` (no dashes, max 24 chars)
- Static Web App: `swa-{token}`
- OpenAI: `oai-{token}`

### Workflow JSON templates

Workflow files in `workflows/` contain placeholder credential IDs like `REPLACE_WITH_AUTONOMOUS_CREDENTIAL_ID`. `Configure-N8n.ps1` substitutes these with real IDs after credential creation.

### SPA configuration

`test-spa/authConfig.template.js` uses placeholders (`__SPA_CLIENT_ID__`, `__SPA_TENANT_ID__`, etc.) that `postprovision.ps1` replaces to generate `authConfig.js`. The generated file is gitignored.

### Secrets handling

- No secrets in source code — templates use placeholders, `.env` files are gitignored.
- n8n API keys are generated with 1-day expiry and regenerated on each provisioning run.
- The Blueprint client secret is stored only in the azd environment file.
- Azure OpenAI keys are fetched post-deployment via Bicep `listKeys()`.
