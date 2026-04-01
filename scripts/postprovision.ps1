#Requires -Version 7
<#
.SYNOPSIS
    azd postprovision hook — runs automatically after `azd provision`.

.DESCRIPTION
    Reads the azd environment variables set by Bicep outputs and calls either:
      - Run-All.ps1   (if tenant ID is available) → full Entra + n8n setup
      - Configure-N8n.ps1 (if not available)      → n8n-only setup

    Tenant ID is auto-detected from the current Azure login (`az account show`)
    if not explicitly set via ENTRA_TENANT_ID env var or Bicep parameter.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptsDir = $PSScriptRoot
$n8nUrl     = $env:N8N_URL
$tenantId   = $env:ENTRA_TENANT_ID

# Auto-detect tenant ID from the current Azure login if not explicitly set
if (-not $tenantId) {
    try {
        $acct = az account show --query tenantId -o tsv 2>$null
        if ($acct) { $tenantId = $acct.Trim() }
    } catch { <# best-effort #> }
}

# Azure OpenAI — set by Bicep outputs via azd
$openAiResource   = $env:AZURE_OPENAI_RESOURCE
$openAiApiKey     = $env:AZURE_OPENAI_API_KEY
$openAiDeployment = $env:AZURE_OPENAI_DEPLOYMENT
$shouldDeploySpa  = $false

# SPA Static Web App — set by Bicep outputs via azd
$swaHostname = $env:SWA_HOSTNAME

# n8n owner account credentials
$ownerEmail    = $env:N8N_ADMIN_EMAIL
$ownerPassword = $env:N8N_ADMIN_PASSWORD

if (-not $n8nUrl) {
    Write-Error "N8N_URL environment variable is not set. Ensure azd provision completed successfully."
    exit 1
}

if (-not $ownerEmail -or -not $ownerPassword) {
    Write-Error "N8N_ADMIN_EMAIL and/or N8N_ADMIN_PASSWORD are not set. Configure n8nAdminEmail/n8nAdminPassword in infra/main.bicep or infra/main.parameters.json."
    exit 1
}

Write-Host ""
Write-Host "=" * 70 -ForegroundColor Cyan
Write-Host "  azd postprovision: n8n + Entra Agent ID setup" -ForegroundColor Cyan
Write-Host "=" * 70 -ForegroundColor Cyan
Write-Host "  n8n URL      : $n8nUrl"
Write-Host "  n8n Admin    : $ownerEmail"
Write-Host "  Tenant ID    : $(if ($tenantId) { $tenantId } else { '(not set — Entra setup skipped)' })"
Write-Host "  OpenAI       : $(if ($openAiResource) { "$openAiResource / deployment=$openAiDeployment" } else { '(not set)' })"
Write-Host "  SWA Hostname : $(if ($swaHostname) { $swaHostname } else { '(not set)' })"
Write-Host ""

if ($tenantId) {
    # Full setup: Entra Agent ID + n8n credentials + workflows.
    # On re-runs, read previously stored IDs from azd env to skip object re-creation.
    $resumeParams = @{}
    if ($env:ENTRA_BLUEPRINT_ID)      { $resumeParams['BlueprintId']      = $env:ENTRA_BLUEPRINT_ID }
    if ($env:ENTRA_AGENT_IDENTITY_ID) { $resumeParams['AgentIdentityId']  = $env:ENTRA_AGENT_IDENTITY_ID }
    if ($env:ENTRA_AGENT_USER_UPN)    { $resumeParams['AgentUserUpn']     = $env:ENTRA_AGENT_USER_UPN }
    if ($env:ENTRA_BLUEPRINT_SECRET)  { $resumeParams['BlueprintSecret']  = $env:ENTRA_BLUEPRINT_SECRET }
    if ($env:ENTRA_BLUEPRINT_APP_ID)  { $resumeParams['BlueprintAppId']   = $env:ENTRA_BLUEPRINT_APP_ID }
    if ($swaHostname) { $resumeParams['SpaFqdn'] = $swaHostname }

    if ($resumeParams.Count -eq 4) {
        Write-Host "  Resuming: Entra objects already exist (IDs loaded from azd env)." -ForegroundColor Green
    } else {
        Write-Host "  First run: Entra objects will be created." -ForegroundColor Cyan
    }
    Write-Host ""

    $openAiParams = @{}
    if ($openAiResource)   { $openAiParams['AzureOpenAiResourceName'] = $openAiResource }
    if ($openAiApiKey)     { $openAiParams['AzureOpenAiApiKey']       = $openAiApiKey }
    if ($openAiDeployment) { $openAiParams['AzureOpenAiDeployment']   = $openAiDeployment }

    $entraRaw = & "$scriptsDir\Run-All.ps1" `
        -TenantId        $tenantId `
        -N8nUrl          $n8nUrl `
        -OwnerEmail      $ownerEmail `
        -OwnerPassword   $ownerPassword `
        @resumeParams `
        @openAiParams

    # Run-All.ps1 returns $entra; guard against extra pipeline objects.
    $entra = if ($entraRaw -is [array]) {
        $entraRaw | Where-Object { $_ -is [hashtable] } | Select-Object -Last 1
    } else {
        $entraRaw
    }

    # Persist IDs in the azd environment (.azure/<env>/.env, gitignored) for future re-runs.
    # This makes subsequent `azd provision` calls idempotent — no duplicate Entra objects.
    if ($entra -and $entra.BlueprintId) {
        azd env set ENTRA_BLUEPRINT_ID      $entra.BlueprintId
        azd env set ENTRA_AGENT_IDENTITY_ID $entra.AgentIdentityId
        azd env set ENTRA_AGENT_USER_UPN    $entra.AgentUserUpn
        # The secret is stored in plaintext in .azure/<env>/.env which is gitignored by azd.
        azd env set ENTRA_BLUEPRINT_SECRET  $entra.BlueprintSecret
        if ($entra.BlueprintAppId)  { azd env set ENTRA_BLUEPRINT_APP_ID $entra.BlueprintAppId }
        if ($entra.SpaClientId)     { azd env set ENTRA_SPA_CLIENT_ID    $entra.SpaClientId    }
        Write-Host ""
        Write-Host "  Entra object IDs saved to azd env — future `azd provision` runs will reuse them." -ForegroundColor Green

        # Generate authConfig.js from template so SPA deploy can run non-interactively.
        if ($swaHostname -and $entra.SpaClientId) {
            Write-Host ""
            Write-Host "  Generating SPA authConfig.js from template..." -ForegroundColor Cyan
            $webhookPath  = 'caef5339-caaa-4228-999d-89abf943bfe2'
            $redirectUri  = "https://$swaHostname/redirect.html"
            $templatePath = Join-Path $scriptsDir '..' 'test-spa' 'authConfig.template.js'
            $outputPath   = Join-Path $scriptsDir '..' 'test-spa' 'authConfig.js'
            $config = Get-Content $templatePath -Raw
            $config = $config -replace '__SPA_CLIENT_ID__',        $entra.SpaClientId
            $config = $config -replace '__SPA_TENANT_ID__',        $tenantId
            $config = $config -replace '__SPA_REDIRECT_URI__',     $redirectUri
            $config = $config -replace '__SPA_BLUEPRINT_APP_ID__', $entra.BlueprintAppId
            $config = $config -replace '__N8N_WEBHOOK_URL__',      "$n8nUrl/webhook/$webhookPath"
            $config = $config -replace '__N8N_WEBHOOK_TEST_URL__', "$n8nUrl/webhook-test/$webhookPath"
            $config | Set-Content $outputPath -Encoding UTF8
            $shouldDeploySpa = $true
            Write-Host "  authConfig.js generated." -ForegroundColor Green
        }
    }

} else {
    Write-Host "Tenant ID not detected (not logged into Azure or ENTRA_TENANT_ID not set)." -ForegroundColor Yellow
    Write-Host "Skipping Entra Agent ID setup. Only basic n8n configuration will run." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "To enable full Entra setup:" -ForegroundColor Cyan
    Write-Host "  1. Log in with: az login"
    Write-Host "  2. Run: azd provision"
    Write-Host "  OR run manually:"
    Write-Host "  3. cd scripts && .\Run-All.ps1 -TenantId <guid> -N8nUrl $n8nUrl"
    Write-Host ""

    # n8n-only: configure owner, import workflows, still create Azure OpenAI credential if available
    $noEntraParams = @{
        N8nUrl               = $n8nUrl
        OwnerEmail           = $ownerEmail
        OwnerPassword        = $ownerPassword
        SkipCredentialCreate = $true
    }
    if ($openAiResource)   { $noEntraParams['AzureOpenAiResourceName'] = $openAiResource }
    if ($openAiApiKey)     { $noEntraParams['AzureOpenAiApiKey']       = $openAiApiKey }
    if ($openAiDeployment) { $noEntraParams['AzureOpenAiDeployment']   = $openAiDeployment }

    & "$scriptsDir\Configure-N8n.ps1" @noEntraParams
}

# Deploy SPA with retry as part of the provisioning flow so `azd up` stays one-command.
if ($shouldDeploySpa) {
    Write-Host ""
    Write-Host "  Deploying SPA with retry..." -ForegroundColor Cyan
    & "$scriptsDir\Deploy-Spa-WithRetry.ps1" -MaxAttempts 5
    if ($LASTEXITCODE -ne 0) {
        Write-Error "SPA deployment failed after retries."
        exit $LASTEXITCODE
    }
} elseif ($swaHostname) {
    Write-Host ""
    Write-Host "  Skipping SPA deploy: missing Entra SPA values required to render authConfig.js." -ForegroundColor Yellow
}

# ── Final summary ─────────────────────────────────────────────────────────────
Write-Host ""
Write-Host ("=" * 70) -ForegroundColor Green
Write-Host "  DEPLOYMENT COMPLETE" -ForegroundColor Green
Write-Host ("=" * 70) -ForegroundColor Green
Write-Host "  n8n URL  : $n8nUrl" -ForegroundColor White
Write-Host "  Username : $ownerEmail" -ForegroundColor White
Write-Host "  Password : $ownerPassword" -ForegroundColor White
if ($swaHostname) {
    Write-Host "  SPA URL  : https://$swaHostname" -ForegroundColor White
}
Write-Host ("=" * 70) -ForegroundColor Green
Write-Host ""
