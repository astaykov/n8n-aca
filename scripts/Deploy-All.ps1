#Requires -Version 7
<#
.SYNOPSIS
    Full end-to-end setup: deploys n8n to Azure, configures the owner account,
    installs Entra Agent ID, and imports demo workflows.

.DESCRIPTION
    Runs all setup steps in the correct order:

      Step 1  azd up            → provision infra + deploy n8n container
      Step 2  Configure-N8n.ps1 → wait for health, create owner, get API key, import workflows
      Step 3  Setup-EntraAgentId.ps1 → create Blueprint / Agent Identity / Agent User,
                                        enable MCP Server, print n8n credentials table

    After this script completes you only need to:
      a) Copy the printed credential values into n8n
      b) Open each imported workflow and assign credentials to the Auth Manager nodes

.PARAMETER TenantId
    Your Entra tenant ID (GUID).

.PARAMETER OwnerEmail
    Email for the n8n admin account that will be created.

.PARAMETER OwnerPassword
    Password for the n8n admin account. Min 8 chars, mixed case, digit.

.PARAMETER SkipAzdUp
    Skip running 'azd up' (use if infra is already deployed).

.PARAMETER SkipMcpServer
    Skip enabling the Microsoft Graph MCP Server for Enterprise in your tenant.

.PARAMETER N8nUrl
    Override the n8n URL instead of reading it from azd env output.
    Required when using -SkipAzdUp and the URL is not in azd env.

.EXAMPLE
    # Full first-time setup
    .\Deploy-All.ps1 `
        -TenantId     "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
        -OwnerEmail   "admin@contoso.com" `
        -OwnerPassword "MyStr0ngPassword!"

.EXAMPLE
    # Infra already deployed — skip azd up
    .\Deploy-All.ps1 `
        -TenantId     "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
        -OwnerEmail   "admin@contoso.com" `
        -OwnerPassword "MyStr0ngPassword!" `
        -SkipAzdUp `
        -N8nUrl       "https://ca-n8n-abc123.eastus2.azurecontainerapps.io"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
    [string]$TenantId,

    [Parameter(Mandatory = $true)]
    [string]$OwnerEmail,

    [Parameter(Mandatory = $true)]
    [string]$OwnerPassword,

    [Parameter(Mandatory = $false)]
    [switch]$SkipAzdUp,

    [Parameter(Mandatory = $false)]
    [switch]$SkipMcpServer,

    [Parameter(Mandatory = $false)]
    [string]$N8nUrl
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptsDir = $PSScriptRoot

function Write-Banner {
    param([string]$Text)
    $line = "=" * 70
    Write-Host ""
    Write-Host $line -ForegroundColor Magenta
    Write-Host "  $Text" -ForegroundColor Magenta
    Write-Host $line -ForegroundColor Magenta
    Write-Host ""
}

# ─── Step 1: azd up ───────────────────────────────────────────────────────────
Write-Banner "STEP 1/3 — Infrastructure deployment (azd up)"

if ($SkipAzdUp) {
    Write-Host "  Skipping azd up (-SkipAzdUp flag set)." -ForegroundColor Yellow
} else {
    Write-Host "  Running 'azd up' from repo root..." -ForegroundColor Cyan
    Write-Host "  You will be prompted for environment name, subscription, and location." -ForegroundColor Yellow
    Write-Host ""

    $repoRoot = Join-Path $scriptsDir '..'
    Push-Location $repoRoot
    try {
        & azd up
        if ($LASTEXITCODE -ne 0) {
            throw "'azd up' exited with code $LASTEXITCODE"
        }
    } finally {
        Pop-Location
    }
    Write-Host ""
    Write-Host "  [OK] azd up completed" -ForegroundColor Green
}

# Resolve n8n URL
if (-not $N8nUrl) {
    Write-Host "  Reading N8N_URL from azd environment output..." -ForegroundColor Cyan
    $azdOutput = & azd env get-values 2>$null
    $urlLine   = $azdOutput | Select-String 'N8N_URL=(.+)'
    if ($urlLine) {
        $N8nUrl = $urlLine.Matches[0].Groups[1].Value.Trim('"').Trim("'")
        Write-Host "  [OK] N8N_URL = $N8nUrl" -ForegroundColor Green
    } else {
        Write-Host ""
        Write-Host "  Could not read N8N_URL from azd env output." -ForegroundColor Red
        $N8nUrl = (Read-Host "  Enter the n8n URL manually (from Azure portal or azd output)").Trim()
    }
}

# ─── Step 2: Configure n8n ───────────────────────────────────────────────────
Write-Banner "STEP 2/3 — n8n configuration (owner account + workflows)"

$n8nScript = Join-Path $scriptsDir 'Configure-N8n.ps1'
$n8nResult = & $n8nScript `
    -N8nUrl        $N8nUrl `
    -OwnerEmail    $OwnerEmail `
    -OwnerPassword $OwnerPassword

# ─── Step 3: Entra Agent ID setup ────────────────────────────────────────────
Write-Banner "STEP 3/3 — Microsoft Entra Agent ID + MCP Server setup"

$entraScript = Join-Path $scriptsDir 'Setup-EntraAgentId.ps1'
$entraArgs   = @{ TenantId = $TenantId }
if ($SkipMcpServer) { $entraArgs['SkipMcpServer'] = $true }

& $entraScript @entraArgs

# ─── Done ─────────────────────────────────────────────────────────────────────
Write-Banner "ALL STEPS COMPLETE"

Write-Host "  n8n URL : $N8nUrl"
Write-Host ""
Write-Host "  Remaining manual steps:" -ForegroundColor Cyan
Write-Host "  1. Open n8n and go to Settings → Community Nodes"
Write-Host "     Install: @astaykov/n8n-nodes-entraagentid"
Write-Host ""
Write-Host "  2. Go to Settings → Credentials → New Credential"
Write-Host "     Create the two credentials from the table printed above"
Write-Host "     (EntraAgentID - Autonomous  and  EntraAgentID - Agent User OBO)"
Write-Host ""
Write-Host "  3. Open each imported workflow and select the matching credential"
Write-Host "     on the 'Entra Agent ID Authentication Manager' nodes"
Write-Host ""
Write-Host "  4. Run the workflow — you should see tenant org data and MCP results"
Write-Host ""
