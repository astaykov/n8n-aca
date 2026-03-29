#Requires -Version 7
<#
.SYNOPSIS
    azd postprovision hook — runs automatically after `azd provision`.

.DESCRIPTION
    Reads the azd environment variables set by Bicep outputs and calls either:
      - Run-All.ps1   (if ENTRA_TENANT_ID is set)  → full Entra + n8n setup
      - Configure-N8n.ps1 (if not set)             → n8n-only setup

    azd sets these from main.bicep outputs:
      $env:N8N_URL          – HTTPS URL of the n8n Container App
      $env:ENTRA_TENANT_ID  – Entra tenant ID (from entraTenantId parameter)

    To trigger Entra Agent ID setup: set entraTenantId in infra/main.parameters.json,
    then run `azd provision` (or `azd env set ENTRA_TENANT_ID <guid>` manually).
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptsDir = $PSScriptRoot
$n8nUrl     = $env:N8N_URL
$tenantId   = $env:ENTRA_TENANT_ID

# Azure OpenAI — set by Bicep outputs via azd
$openAiResource   = $env:AZURE_OPENAI_RESOURCE
$openAiApiKey     = $env:AZURE_OPENAI_API_KEY
$openAiDeployment = $env:AZURE_OPENAI_DEPLOYMENT

# SPA Container App — set by Bicep outputs via azd
$spaFqdn    = $env:SPA_FQDN
$spaAppName = $env:SPA_APP_NAME
$rgName     = $env:AZURE_RESOURCE_GROUP

if (-not $n8nUrl) {
    Write-Error "N8N_URL environment variable is not set. Ensure azd provision completed successfully."
    exit 1
}

Write-Host ""
Write-Host "=" * 70 -ForegroundColor Cyan
Write-Host "  azd postprovision: n8n + Entra Agent ID setup" -ForegroundColor Cyan
Write-Host "=" * 70 -ForegroundColor Cyan
Write-Host "  n8n URL      : $n8nUrl"
Write-Host "  Tenant ID    : $(if ($tenantId) { $tenantId } else { '(not set — Entra setup skipped)' })"
Write-Host "  OpenAI       : $(if ($openAiResource) { "$openAiResource / deployment=$openAiDeployment" } else { '(not set)' })"
Write-Host "  SPA FQDN     : $(if ($spaFqdn) { $spaFqdn } else { '(not set)' })"
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
    if ($spaFqdn)                     { $resumeParams['SpaFqdn']          = $spaFqdn }

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
        -SkipNodeInstall `
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

        # Update the SPA Container App env vars with the now-known SPA client ID and Blueprint app ID.
        # The Container App was provisioned earlier with placeholder values; this brings them up-to-date
        # so the next `azd deploy spa` bakes the correct values into the container at startup.
        if ($spaAppName -and $rgName -and $entra.SpaClientId) {
            Write-Host ""
            Write-Host "  Updating SPA Container App env vars..." -ForegroundColor Cyan
            $spaEnvVars = [System.Collections.Generic.List[string]]::new()
            $spaEnvVars.Add("SPA_CLIENT_ID=$($entra.SpaClientId)")
            if ($entra.BlueprintAppId) { $spaEnvVars.Add("SPA_BLUEPRINT_APP_ID=$($entra.BlueprintAppId)") }
            try {
                az containerapp update `
                    --name           $spaAppName `
                    --resource-group $rgName `
                    --set-env-vars   @spaEnvVars `
                    --output none 2>&1
                Write-Host "  SPA Container App env vars updated." -ForegroundColor Green
                Write-Host "  Run `azd deploy spa` to build and push the SPA Docker image." -ForegroundColor Cyan
            } catch {
                Write-Host "  Could not update SPA Container App: $($_.Exception.Message)" -ForegroundColor Yellow
                Write-Host "  Update manually: az containerapp update --name $spaAppName --resource-group $rgName --set-env-vars SPA_CLIENT_ID=$($entra.SpaClientId)" -ForegroundColor Yellow
            }
        }
    }

} else {
    Write-Host "ENTRA_TENANT_ID is not set." -ForegroundColor Yellow
    Write-Host "Skipping Entra Agent ID setup. Only basic n8n configuration will run." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "To enable full Entra setup:" -ForegroundColor Cyan
    Write-Host "  1. Set entraTenantId in infra/main.parameters.json"
    Write-Host "  2. Run: azd provision"
    Write-Host "  OR run manually:"
    Write-Host "  3. cd scripts && .\Run-All.ps1 -TenantId <guid> -N8nUrl $n8nUrl -SkipNodeInstall"
    Write-Host ""

    # n8n-only: configure owner, import workflows, still create Azure OpenAI credential if available
    $noEntraParams = @{
        N8nUrl              = $n8nUrl
        OwnerEmail          = 'admin@contoso.com'
        OwnerPassword       = 'N8nAdm1n!Test'
        SkipNodeInstall     = $true
        SkipCredentialCreate = $true
    }
    if ($openAiResource)   { $noEntraParams['AzureOpenAiResourceName'] = $openAiResource }
    if ($openAiApiKey)     { $noEntraParams['AzureOpenAiApiKey']       = $openAiApiKey }
    if ($openAiDeployment) { $noEntraParams['AzureOpenAiDeployment']   = $openAiDeployment }

    & "$scriptsDir\Configure-N8n.ps1" @noEntraParams
}
