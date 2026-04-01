#Requires -Version 7
<#
.SYNOPSIS
    Runs azd provision and then deploys SPA with transient retry handling.

.DESCRIPTION
    Use this script when `azd up` intermittently fails during the final SWA deploy
    step because of temporary StaticSitesClient download/metadata issues.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 20)]
    [int]$SpaMaxAttempts = 5,

    [Parameter(Mandatory = $false)]
    [switch]$VerboseAzd
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot

Write-Host ""
Write-Host ('=' * 70) -ForegroundColor Cyan
Write-Host "  azd provision + SPA deploy retry" -ForegroundColor Cyan
Write-Host ('=' * 70) -ForegroundColor Cyan
Write-Host ""

Push-Location $repoRoot
try {
    Write-Host "Step 1/2: azd provision" -ForegroundColor Cyan
    & azd provision
    if ($LASTEXITCODE -ne 0) {
        throw "azd provision failed with exit code $LASTEXITCODE"
    }

    Write-Host ""
    Write-Host "Step 2/2: Deploy SPA with retry" -ForegroundColor Cyan

    $retryScript = Join-Path $PSScriptRoot 'Deploy-Spa-WithRetry.ps1'
    & $retryScript -MaxAttempts $SpaMaxAttempts -VerboseAzd:$VerboseAzd
    if ($LASTEXITCODE -ne 0) {
        throw "SPA deployment failed with exit code $LASTEXITCODE"
    }

    Write-Host ""
    Write-Host "Completed successfully." -ForegroundColor Green
}
finally {
    Pop-Location
}
