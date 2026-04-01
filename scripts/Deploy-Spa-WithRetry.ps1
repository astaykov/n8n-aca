#Requires -Version 7
<#
.SYNOPSIS
    Deploys the SPA service with retries for transient SWA CLI/network failures.

.DESCRIPTION
    Wraps `azd deploy spa` and retries when known transient Static Web Apps CLI
    errors occur (e.g., StaticSitesClient metadata/download issues).

.EXAMPLE
    ./scripts/Deploy-Spa-WithRetry.ps1

.EXAMPLE
    ./scripts/Deploy-Spa-WithRetry.ps1 -MaxAttempts 5 -InitialDelaySeconds 10
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 20)]
    [int]$MaxAttempts = 5,

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 300)]
    [int]$InitialDelaySeconds = 8,

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 1800)]
    [int]$MaxDelaySeconds = 90,

    [Parameter(Mandatory = $false)]
    [switch]$VerboseAzd
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-IsTransientSpaDeployFailure {
    param(
        [Parameter(Mandatory = $true)]
        [string]$OutputText
    )

    $patterns = @(
        'Could not load StaticSitesClient metadata from remote',
        'Could not find StaticSitesClient local binary',
        'StaticSitesClient',
        'Deployment Failed :\(',
        'ENOTFOUND',
        'ECONNRESET',
        'ETIMEDOUT',
        'EAI_AGAIN',
        'temporary failure',
        'timed out',
        '429',
        '503',
        '504'
    )

    foreach ($pattern in $patterns) {
        if ($OutputText -match $pattern) {
            return $true
        }
    }

    return $false
}

function Invoke-AzdSpaDeploy {
    param(
        [Parameter(Mandatory = $false)]
        [switch]$EnableDebug
    )

    $azdArgs = @('deploy', 'spa')
    if ($EnableDebug) {
        $azdArgs += '--debug'
    }

    $output = & azd @azdArgs 2>&1 | Out-String
    $exitCode = $LASTEXITCODE

    return [pscustomobject]@{
        ExitCode = $exitCode
        Output   = $output
    }
}

Write-Host ""
Write-Host ('=' * 70) -ForegroundColor Cyan
Write-Host "  SPA Deploy With Retry" -ForegroundColor Cyan
Write-Host ('=' * 70) -ForegroundColor Cyan
Write-Host "  Max attempts : $MaxAttempts"
Write-Host "  Initial delay: $InitialDelaySeconds s"
Write-Host "  Max delay    : $MaxDelaySeconds s"
Write-Host ""

$attempt = 1
$delay = $InitialDelaySeconds

while ($attempt -le $MaxAttempts) {
    Write-Host ("Attempt {0}/{1}: azd deploy spa" -f $attempt, $MaxAttempts) -ForegroundColor Cyan

    $result = Invoke-AzdSpaDeploy -EnableDebug:$VerboseAzd

    if ($result.ExitCode -eq 0) {
        Write-Host "SPA deployment succeeded." -ForegroundColor Green
        exit 0
    }

    $transient = Test-IsTransientSpaDeployFailure -OutputText $result.Output

    Write-Host "azd deploy spa failed with exit code $($result.ExitCode)." -ForegroundColor Yellow
    Write-Host $result.Output

    if (-not $transient) {
        Write-Error "Failure does not look transient. Stopping without retry."
        exit $result.ExitCode
    }

    if ($attempt -ge $MaxAttempts) {
        Write-Error "Exceeded retry limit ($MaxAttempts attempts)."
        exit $result.ExitCode
    }

    Write-Host "Transient failure detected. Retrying in $delay second(s)..." -ForegroundColor Yellow
    Start-Sleep -Seconds $delay
    $delay = [Math]::Min($delay * 2, $MaxDelaySeconds)
    $attempt++
}

Write-Error "Unexpected retry loop termination."
exit 1
