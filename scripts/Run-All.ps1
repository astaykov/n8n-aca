#Requires -Version 7
<#
.SYNOPSIS
    End-to-end setup: Entra Agent ID + n8n credentials + workflow import.

.DESCRIPTION
    Runs Setup-EntraAgentId.ps1 then Configure-N8n.ps1 back-to-back.
    A single browser sign-in is required for Entra; n8n is configured fully
    automatically using the values captured from the Entra setup.

.PARAMETER TenantId
    Your Entra tenant ID (GUID). Required.

.PARAMETER N8nUrl
    The base HTTPS URL of the deployed n8n instance. Required.

.PARAMETER OwnerEmail
    n8n owner email (default: admin@contoso.com).

.PARAMETER OwnerPassword
    n8n owner password (default: N8nAdm1n!Test).

.PARAMETER SkipMcpServer
    Pass through to Setup-EntraAgentId.ps1 — skips MCP Server provisioning.

.PARAMETER SkipNodeInstall
    Pass through to Configure-N8n.ps1 — skips community node install/reload.

.EXAMPLE
    # Full end-to-end run (one browser sign-in required)
    .\Run-All.ps1 `
        -TenantId "<your-entra-tenant-id>" `
        -N8nUrl   "https://ca-n8n-xxxxxxxx.northeurope.azurecontainerapps.io"

.EXAMPLE
    # Skip community node reinstall (already installed)
    .\Run-All.ps1 `
        -TenantId        "<your-entra-tenant-id>" `
        -N8nUrl          "https://ca-n8n-xxxxxxxx.northeurope.azurecontainerapps.io" `
        -SkipNodeInstall
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
    [string]$TenantId,

    [Parameter(Mandatory = $true)]
    [string]$N8nUrl,

    [Parameter(Mandatory = $false)]
    [string]$OwnerEmail = 'admin@contoso.com',

    [Parameter(Mandatory = $false)]
    [string]$OwnerPassword = 'N8nAdm1n!Test',

    [Parameter(Mandatory = $false)]
    [switch]$SkipMcpServer,

    [Parameter(Mandatory = $false)]
    [switch]$SkipNodeInstall,

    # ── Resume params: supply all four to skip Entra Phase 3 (object creation) ─
    [Parameter(Mandatory = $false)]
    [string]$BlueprintId,

    [Parameter(Mandatory = $false)]
    [string]$AgentIdentityId,

    [Parameter(Mandatory = $false)]
    [string]$AgentUserUpn,

    [Parameter(Mandatory = $false)]
    [string]$BlueprintSecret,

    # ── Azure OpenAI: supply to auto-create azureOpenAiApi credential in n8n ────
    [Parameter(Mandatory = $false)]
    [string]$AzureOpenAiResourceName,

    # ── SPA: supply to configure SPA app registration with the deployed FQDN ────
    [Parameter(Mandatory = $false)]
    [string]$SpaFqdn,

    # Supply on re-runs to avoid re-querying the Blueprint SP appId
    [Parameter(Mandatory = $false)]
    [string]$BlueprintAppId,

    [Parameter(Mandatory = $false)]
    [string]$AzureOpenAiApiKey,

    [Parameter(Mandatory = $false)]
    [string]$AzureOpenAiApiVersion = '2024-12-01-preview',

    [Parameter(Mandatory = $false)]
    [string]$AzureOpenAiDeployment = 'gpt-5.4'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptsDir = $PSScriptRoot

$sep = '=' * 70
Write-Host ""
Write-Host $sep -ForegroundColor Cyan
Write-Host "  RUN-ALL: Entra Agent ID + n8n full setup" -ForegroundColor Cyan
Write-Host $sep -ForegroundColor Cyan
Write-Host ""

# ─── Step 1: Entra Agent ID setup ────────────────────────────────────────────
Write-Host "[STEP 1/2] Running Setup-EntraAgentId.ps1..." -ForegroundColor Cyan
Write-Host ""

$setupParams = @{ TenantId = $TenantId }
if ($SkipMcpServer)    { $setupParams['SkipMcpServer']    = $true }
if ($BlueprintId)      { $setupParams['BlueprintId']      = $BlueprintId }
if ($AgentIdentityId)  { $setupParams['AgentIdentityId']  = $AgentIdentityId }
if ($AgentUserUpn)     { $setupParams['AgentUserUpn']     = $AgentUserUpn }
if ($BlueprintSecret)  { $setupParams['BlueprintSecret']  = $BlueprintSecret }
if ($SpaFqdn)          { $setupParams['SpaFqdn']          = $SpaFqdn }
if ($BlueprintAppId)   { $setupParams['BlueprintAppId']   = $BlueprintAppId }

$entraRaw = & "$scriptsDir\Setup-EntraAgentId.ps1" @setupParams
# The script may emit multiple pipeline objects (from cmdlets); pick the hashtable return value.
$entra = if ($entraRaw -is [array]) {
    $entraRaw | Where-Object { $_ -is [hashtable] } | Select-Object -Last 1
} else {
    $entraRaw
}

if (-not $entra -or -not $entra.BlueprintId) {
    throw "Setup-EntraAgentId.ps1 did not return expected values. Check for errors above."
}

Write-Host ""
Write-Host "[STEP 1/2] Entra setup complete:" -ForegroundColor Green
Write-Host "  BlueprintId     : $($entra.BlueprintId)"
Write-Host "  AgentIdentityId : $($entra.AgentIdentityId)"
Write-Host "  AgentUserUpn    : $($entra.AgentUserUpn)"
Write-Host ""

# ─── Step 2: n8n configuration ───────────────────────────────────────────────
Write-Host "[STEP 2/2] Running Configure-N8n.ps1..." -ForegroundColor Cyan
Write-Host ""

$n8nParams = @{
    N8nUrl               = $N8nUrl
    OwnerEmail           = $OwnerEmail
    OwnerPassword        = $OwnerPassword
    EntraTenantId        = $entra.TenantId
    EntraBlueprintId     = $entra.BlueprintId
    EntraBlueprintSecret = $entra.BlueprintSecret
    EntraAgentId         = $entra.AgentIdentityId
    EntraAgentUserUpn    = $entra.AgentUserUpn
}
if ($SkipNodeInstall) { $n8nParams['SkipNodeInstall'] = $true }
if ($AzureOpenAiResourceName) { $n8nParams['AzureOpenAiResourceName'] = $AzureOpenAiResourceName }
if ($AzureOpenAiApiKey)       { $n8nParams['AzureOpenAiApiKey']       = $AzureOpenAiApiKey }
if ($AzureOpenAiApiVersion)   { $n8nParams['AzureOpenAiApiVersion']   = $AzureOpenAiApiVersion }
if ($AzureOpenAiDeployment)   { $n8nParams['AzureOpenAiDeployment']   = $AzureOpenAiDeployment }

$n8n = & "$scriptsDir\Configure-N8n.ps1" @n8nParams

# ─── Final summary ────────────────────────────────────────────────────────────
Write-Host ""
Write-Host $sep -ForegroundColor Magenta
Write-Host "  ALL DONE" -ForegroundColor Magenta
Write-Host $sep -ForegroundColor Magenta
Write-Host ""
Write-Host "  n8n URL         : $N8nUrl"
Write-Host "  Owner           : $OwnerEmail"
if ($n8n.ApiKey) { Write-Host "  API Key         : $($n8n.ApiKey)" -ForegroundColor Yellow }
Write-Host ""
Write-Host "  Entra Blueprint : $($entra.BlueprintId)"
Write-Host "  Blueprint AppId : $(if ($entra.BlueprintAppId) { $entra.BlueprintAppId } else { '(not resolved)' })"
Write-Host "  Agent Identity  : $($entra.AgentIdentityId)"
Write-Host "  Agent User      : $($entra.AgentUserUpn)"
if ($entra.SpaClientId) {
Write-Host "  SPA Client ID   : $($entra.SpaClientId)" -ForegroundColor Cyan
}
Write-Host ""
Write-Host "  Open n8n and activate the imported workflows." -ForegroundColor Cyan
Write-Host $sep -ForegroundColor Magenta
Write-Host ""

# Return the Entra result so callers (e.g. postprovision.ps1) can persist the IDs.
return $entra
