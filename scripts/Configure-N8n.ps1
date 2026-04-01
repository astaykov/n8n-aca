#Requires -Version 7
<#
.SYNOPSIS
    Configures a freshly deployed n8n instance: creates the owner account,
    generates an API key, and imports all workflow JSON files.

.DESCRIPTION
    Automates the post-deployment n8n setup so no manual browser interaction
    is required:

      1. Waits for n8n to become healthy (retries for up to 10 min)
      2. Logs in and retrieves an API key
      3. Imports every *.json file found in the workflows/ folder

    Designed to run immediately after 'azd up' completes.

.PARAMETER N8nUrl
    The base HTTPS URL of the deployed n8n instance, e.g.:
    https://ca-n8n-abc123.eastus2.azurecontainerapps.io

.PARAMETER OwnerEmail
    Email address for the n8n owner (admin) account.

.PARAMETER OwnerPassword
    Password for the n8n owner account. Must meet n8n requirements:
    minimum 8 characters, mixed case, number.

.PARAMETER WorkflowsPath
    Path to the folder containing workflow JSON files to import.
    Defaults to the 'workflows' folder relative to this script.

.PARAMETER SkipWorkflowImport
    Skip importing workflow JSON files (only configure the account and API key).

.EXAMPLE
    .\Configure-N8n.ps1 `
        -N8nUrl   "https://ca-n8n-abc123.eastus2.azurecontainerapps.io" `
        -OwnerEmail "admin@contoso.com" `
        -OwnerPassword "MyStr0ngPassword!"

.EXAMPLE
    # Get the URL from azd output automatically
    $url = (azd env get-values | Select-String 'N8N_URL=(.+)').Matches.Groups[1].Value.Trim('"')
    .\Configure-N8n.ps1 -N8nUrl $url -OwnerEmail "admin@contoso.com" -OwnerPassword "MyStr0ngPassword!"

.NOTES
    Uses n8n's internal REST API for setup/login and the public API v1 for
    workflow import. If n8n's API endpoints change in future versions, check
    the network requests in your browser's DevTools.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$N8nUrl,

    [Parameter(Mandatory = $true)]
    [string]$OwnerEmail,

    [Parameter(Mandatory = $true)]
    [string]$OwnerPassword,

    [Parameter(Mandatory = $false)]
    [string]$WorkflowsPath = (Join-Path $PSScriptRoot '..\workflows'),

    [Parameter(Mandatory = $false)]
    [switch]$SkipWorkflowImport,

    [Parameter(Mandatory = $false)]
    [switch]$SkipNodeInstall,

    # ── Entra Agent ID credential creation (Phase 6) ──────────────────────────
    # Supply all four to auto-create the entraAgentIDApi credentials in n8n.
    [Parameter(Mandatory = $false)]
    [string]$EntraTenantId,

    [Parameter(Mandatory = $false)]
    [string]$EntraBlueprintId,

    [Parameter(Mandatory = $false)]
    [string]$EntraBlueprintSecret,

    [Parameter(Mandatory = $false)]
    [string]$EntraAgentId,

    [Parameter(Mandatory = $false)]
    [string]$EntraAgentUserUpn,

    [Parameter(Mandatory = $false)]
    [switch]$SkipCredentialCreate,

    # ── Azure OpenAI (azureOpenAiApi) credential creation ─────────────────────────────
    # Supply all three to auto-create the azureOpenAiApi credential used by LLM nodes.
    [Parameter(Mandatory = $false)]
    [string]$AzureOpenAiResourceName,

    [Parameter(Mandatory = $false)]
    [string]$AzureOpenAiApiKey,

    [Parameter(Mandatory = $false)]
    [string]$AzureOpenAiApiVersion = '2024-12-01-preview',

    [Parameter(Mandatory = $false)]
    [string]$AzureOpenAiDeployment = 'gpt-4o'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Strip trailing slash
$N8nUrl = $N8nUrl.TrimEnd('/')

# ─── Helpers ──────────────────────────────────────────────────────────────────
function Write-Step { param([string]$s, [string]$t); Write-Host "`n$s $t" -ForegroundColor Cyan }
function Write-OK   { param([string]$t); Write-Host "  [OK] $t" -ForegroundColor Green }
function Write-Note { param([string]$t); Write-Host "  [>>] $t" -ForegroundColor Yellow }
function Write-Err  { param([string]$t); Write-Host "  [!!] $t" -ForegroundColor Red }

# Shared web session object (carries cookies between requests)
$session = New-Object Microsoft.PowerShell.Commands.WebRequestSession

function Invoke-N8n {
    param(
        [string]$Method,
        [string]$Path,
        [object]$Body,
        [hashtable]$Headers = @{},
        [switch]$UseSession,
        [string]$ApiKey,
        [int]$MaxAttempts = 1,
        [int]$InitialRetryDelaySeconds = 3,
        [switch]$RetryOnTransient
    )
    $uri  = "$N8nUrl$Path"
    $baseHeaders = @{ 'Content-Type' = 'application/json' } + $Headers

    if ($ApiKey) {
        $baseHeaders['X-N8N-API-KEY'] = $ApiKey
    }

    $params = @{
        Uri     = $uri
        Method  = $Method
        Headers = $baseHeaders
    }

    if ($UseSession) {
        $params['WebSession'] = $session
    }

    if ($Body) {
        $params['Body'] = ($Body | ConvertTo-Json -Depth 20 -Compress)
    }

    $attempt = 1
    $delay = $InitialRetryDelaySeconds

    while ($attempt -le $MaxAttempts) {
        try {
            return (Invoke-RestMethod @params)
        } catch {
            $responseProp = $_.Exception.PSObject.Properties['Response']
            $statusCode = if ($responseProp -and $responseProp.Value) { $responseProp.Value.StatusCode.value__ } else { 0 }
            $detail = if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $_.ErrorDetails.Message } else { $_.Exception.Message }

            $isTransient = $statusCode -in @(0, 404, 408, 409, 425, 429, 500, 502, 503, 504)
            if ($RetryOnTransient -and $isTransient -and $attempt -lt $MaxAttempts) {
                Write-Note "Transient n8n API response [$Method $Path] HTTP $statusCode. Retry $attempt/$MaxAttempts in ${delay}s."
                Start-Sleep -Seconds $delay
                $delay = [Math]::Min($delay * 2, 30)
                $attempt++
                continue
            }

            throw "n8n API error [$Method $Path] HTTP $statusCode : $detail"
        }
    }
}

function Invoke-N8nLogin {
    param(
        [string]$Email,
        [string]$Password
    )

    $loginBodies = @(
        @{ emailOrLdapLoginId = $Email; password = $Password },
        @{ email = $Email; password = $Password }
    )

    foreach ($loginBody in $loginBodies) {
        try {
            Invoke-N8n -Method POST -Path '/rest/login' -Body $loginBody -UseSession -RetryOnTransient -MaxAttempts 12 -InitialRetryDelaySeconds 5 | Out-Null
            return
        } catch {
            $msg = $_.Exception.Message
            # If this payload shape isn't accepted, try the fallback payload shape.
            if ($msg -match 'HTTP 400' -or $msg -match 'HTTP 422') {
                continue
            }
            throw
        }
    }

    throw "Unable to authenticate to n8n using supported login payloads."
}

# ─── Phase 1 + 2: Wait for n8n to be fully ready, then read setup state ──────
# We poll /rest/settings rather than /healthz because /healthz fires as soon as
# the HTTP server starts — before DB migrations finish and REST routes register.
# /rest/settings only succeeds when n8n is truly ready to accept API calls.
Write-Step "[1/1]" "Waiting for n8n at $N8nUrl to become ready (polling /rest/settings)..."

$maxWaitSec  = 600   # 10 minutes total
$intervalSec = 10
$elapsed     = 0
$settings    = $null
$settingsReady = $false

while ($elapsed -lt $maxWaitSec) {
    try {
        $settings = Invoke-RestMethod -Uri "$N8nUrl/rest/settings" -Method GET -TimeoutSec 10 -ErrorAction Stop
        $settingsReady = $true
        break
    } catch {
        $resp = $_.Exception.PSObject.Properties['Response']
        $sc = if ($resp) { $resp.Value.StatusCode.value__ } else { 0 }
        if ($sc -eq 401 -or $sc -eq 403) {
            # Auth required — n8n is up and owner is already configured
            Write-Note "/rest/settings returned $sc (auth required); n8n is ready and owner already configured."
            $settingsReady = $true
            break
        }
        # 404 during startup = routes not registered yet; keep waiting
        # Any other error (connection refused, 502, etc.) → keep waiting
    }
    Write-Host "  ... not ready yet, retrying in ${intervalSec}s (${elapsed}s elapsed)" -ForegroundColor DarkGray
    Start-Sleep -Seconds $intervalSec
    $elapsed += $intervalSec
}

if (-not $settingsReady) {
    throw "n8n did not become ready within ${maxWaitSec}s. Check the Container App logs."
}
Write-OK "n8n is ready"

Write-Step "[1/3]" "Creating n8n owner account ($OwnerEmail)..."

$setupBody = @{
    email     = $OwnerEmail
    firstName = 'n8n'
    lastName  = 'Admin'
    password  = $OwnerPassword

}
try {
    $setupResp = Invoke-N8n -Method POST -Path '/rest/owner/setup' -Body $setupBody -UseSession -RetryOnTransient -MaxAttempts 6 -InitialRetryDelaySeconds 5
    Write-OK "Owner account created: $OwnerEmail"

} catch {
    if ($_.Exception.Message -match 'HTTP 400' -or $_.Exception.Message -match 'HTTP 409') {
        Write-Note "Owner account already exists; continuing with login."
    } else {
        throw
    }
}

Invoke-N8nLogin -Email $OwnerEmail -Password $OwnerPassword
Write-OK "Logged in as $OwnerEmail"


# ─── Phase 4: Create API key ──────────────────────────────────────────────────
Write-Step "[2/3]" "Creating n8n API key..."

$browserId  = [System.Guid]::NewGuid().ToString()
$apiKey     = $null
$keyLabel   = $browserId
# Expires 1 day from now (Unix timestamp in milliseconds)
$expiresAt  = [long]([System.DateTimeOffset]::UtcNow.AddDays(1).ToUnixTimeMilliseconds())

$apiKeyBody = @{
    label     = $keyLabel
    scopes    = @(
        'workflow:create', 'workflow:read', 'workflow:update',
        'workflow:delete', 'workflow:list', 'workflow:activate'
    )
    expiresAt = $expiresAt
}

try {
    $apiKeyResp = Invoke-N8n -Method POST -Path '/rest/api-keys' `
        -Body $apiKeyBody `
        -Headers @{ 'browser-id' = $browserId } `
        -UseSession `
        -Debug
    $apiKey = $apiKeyResp.data?.rawApiKey ?? $apiKeyResp.rawApiKey
} catch {
    Write-Note "Could not auto-create an API key: $($_.Exception.Message)"
    Write-Note "Please create one manually: n8n → Settings → API → Create API Key"
    Write-Note "Then re-run this script with -SkipWorkflowImport."
}

if ($apiKey) {
    Write-OK "API key created"
    Start-Sleep -Seconds 5 # Brief pause to ensure n8n is ready for login after setup

} else {
    Write-Note "Continuing without API key — workflow import will be skipped."
    $SkipWorkflowImport = $true
}

# ─── Phase 4b: Install community node ─────────────────────────────────────────
# The community node must be installed BEFORE credential or workflow operations
# because credential types (entraAgentIDApi) and workflow node types depend on it.
# Community package management uses the session-based /rest/ endpoint — the
# communityPackage:* scopes are not available as API key scopes.
$communityPackageName = '@astaykov/n8n-nodes-entraagentid'

if ($SkipNodeInstall) {
    Write-Step "[2.5/3]" "Skipping community node install (-SkipNodeInstall set)."
} else {
    Write-Step "[2.5/3]" "Installing community node '$communityPackageName'..."

    # Check if already installed
    $_alreadyInstalled = $false
    try {
        $installedPkgs = Invoke-N8n -Method GET -Path '/rest/community-packages' -UseSession `
            -RetryOnTransient -MaxAttempts 3 -InitialRetryDelaySeconds 3
        $pkgList = if ($installedPkgs.PSObject.Properties['data']) { $installedPkgs.data } else { $installedPkgs }
        if ($pkgList | Where-Object { $_.packageName -eq $communityPackageName }) {
            $_alreadyInstalled = $true
        }
    } catch { <# best-effort check #> }

    if ($_alreadyInstalled) {
        Write-OK "Community node '$communityPackageName' already installed — skipping."
    } else {
        try {
            Invoke-N8n -Method POST -Path '/rest/community-packages' `
                -Body @{ name = $communityPackageName } `
                -UseSession `
                -RetryOnTransient -MaxAttempts 3 -InitialRetryDelaySeconds 10 | Out-Null
            Write-OK "Community node '$communityPackageName' installed"
        } catch {
            Write-Err "Failed to install community node: $($_.Exception.Message)"
            Write-Note "You can install it manually: n8n → Settings → Community Nodes → Install"
        }

        # n8n may need a moment after community node install to register new node types
        Write-Note "Waiting for n8n to register new node types..."
        Start-Sleep -Seconds 10
    }
}

# ─── Phase 5: Create n8n credentials ─────────────────────────────────────────
# Credentials are created BEFORE workflow import so their real IDs can be
# substituted directly into the workflow JSON at import time — no patching needed.
# Always uses session-based /rest/credentials — the public API rejects community
# node credential types (e.g. entraAgentIDApi) via its validCredentialType middleware.
$autonomousCredId    = $null
$autonomousCredName  = 'EntraAgentID - Autonomous'
$oboCredId           = $null
$oboCredName         = 'EntraAgentID - Agent User OBO'
$openAiCredId        = $null
$openAiCredName      = "Azure OpenAI - $AzureOpenAiDeployment"
$mcpTokenCredId      = $null
$mcpTokenCredName    = 'AgentID Auth Manager - Access Token'
$bearerTokenCredId   = $null
$bearerTokenCredName = 'Bearer from AuthManager'

# Fetch all existing credentials once for dedup/delete across all phases
$existingCreds = @()
try {
    $credResp = Invoke-N8n -Method GET -Path '/rest/credentials' -UseSession `
        -RetryOnTransient -MaxAttempts 6 -InitialRetryDelaySeconds 3
    $existingCreds = if ($credResp.PSObject.Properties['data']) { $credResp.data } else { @($credResp) }
} catch { <# best-effort #> }

function Remove-ExistingCredential {
    param([string]$Name)
    $existingCreds | Where-Object { $_.name -eq $Name } | ForEach-Object {
        try {
            Invoke-N8n -Method DELETE -Path "/rest/credentials/$($_.id)" -UseSession | Out-Null
            Write-Note "Deleted existing credential: $($_.name)"
        } catch { <# best-effort #> }
    }
}

function New-N8nCredential {
    param([hashtable]$Body)
    $r = Invoke-N8n -Method POST -Path '/rest/credentials' -Body $Body -UseSession
    return @{ id = $r.data.id; name = $r.data.name }
}

# ── 5a: Entra Agent ID credentials ──────────────────────────────────────────
$_canCreateCreds = $EntraTenantId -and $EntraBlueprintId -and $EntraBlueprintSecret -and $EntraAgentId -and $EntraAgentUserUpn
if ($SkipCredentialCreate -or -not $_canCreateCreds) {
    Write-Step "[3a/3]" "Skipping Entra credential creation (-SkipCredentialCreate or missing parameters)."
    if (-not $SkipCredentialCreate -and -not $_canCreateCreds) {
        Write-Note "Supply -EntraTenantId, -EntraBlueprintId, -EntraBlueprintSecret, -EntraAgentId, -EntraAgentUserUpn to auto-create credentials."
    }
} else {
    Write-Step "[3a/3]" "Creating Entra Agent ID credentials in n8n..."
    $tokenEndpoint = "https://login.microsoftonline.com/$EntraTenantId/oauth2/v2.0/token"
    Remove-ExistingCredential $autonomousCredName
    Remove-ExistingCredential $oboCredName
    $credDefs = @(
        @{
            name = $autonomousCredName
            data = @{
                entraIdTokenEndpoint = $tokenEndpoint
                blueprintId          = $EntraBlueprintId
                blueprintSecret      = $EntraBlueprintSecret
                agentId              = $EntraAgentId
                onBehalfOf           = ""
                scope                = "https://graph.microsoft.com/.default"
            }
        },
        @{
            name = $oboCredName
            data = @{
                entraIdTokenEndpoint = $tokenEndpoint
                blueprintId          = $EntraBlueprintId
                blueprintSecret      = $EntraBlueprintSecret
                agentId              = $EntraAgentId
                onBehalfOf           = $EntraAgentUserUpn
                scope                = "https://mcp.svc.cloud.microsoft/.default"
            }
        }
    )
    foreach ($cred in $credDefs) {
        $body = @{
            name = $cred.name
            type = "entraAgentIDApi"
            data = $cred.data
        }
        $result = New-N8nCredential -Body $body
        if ($cred.name -like '*Autonomous*') { $autonomousCredId = $result.id }
        else                                 { $oboCredId        = $result.id }
        Write-OK "Created credential '$($result.name)' (id=$($result.id))"
    }
}

# ── 5b: Azure OpenAI credential ──────────────────────────────────────────────
$_canCreateOpenAiCred = $AzureOpenAiResourceName -and $AzureOpenAiApiKey
if (-not $_canCreateOpenAiCred) {
    Write-Step "[3b/3]" "Skipping Azure OpenAI credential creation (no -AzureOpenAiResourceName / -AzureOpenAiApiKey supplied)."
} else {
    Write-Step "[3b/3]" "Creating Azure OpenAI credential '$openAiCredName' in n8n..."
    Remove-ExistingCredential $openAiCredName
    $body = @{
        name = $openAiCredName
        type = 'azureOpenAiApi'
        data = @{
            resourceName = $AzureOpenAiResourceName
            apiKey       = $AzureOpenAiApiKey
            apiVersion   = $AzureOpenAiApiVersion
        }
    }
    $r = New-N8nCredential -Body $body
    $openAiCredId = $r.id
    Write-OK "Created credential '$($r.name)' (id=$openAiCredId)"
}

# ── 5c: MCP token-forwarding credential (httpHeaderAuth) ─────────────────────
Write-Step "[5c/7]" "Creating MCP token-forwarding credential '$mcpTokenCredName' in n8n..."
Remove-ExistingCredential $mcpTokenCredName
$body = @{
    name = $mcpTokenCredName
    type = 'httpHeaderAuth'
    data = @{
        name  = 'Authorization'
        value = "=Bearer {{ `$('Entra Agent ID Authentication Manager').item.json.agent_id_access_token }}"
    }
}
$r = New-N8nCredential -Body $body
$mcpTokenCredId = $r.id
Write-OK "Created credential '$($r.name)' (id=$mcpTokenCredId)"

# ── 5d: Bearer token-forwarding credential (httpBearerAuth) ──────────────────
Write-Step "[5d/7]" "Creating Bearer token-forwarding credential '$bearerTokenCredName' in n8n..."
Remove-ExistingCredential $bearerTokenCredName
$body = @{
    name = $bearerTokenCredName
    type = 'httpBearerAuth'
    data = @{
        token = "={{ `$('Entra Agent ID Authentication Manager').item.json.agent_id_access_token }}"
    }
}
$r = New-N8nCredential -Body $body
$bearerTokenCredId = $r.id
Write-OK "Created credential '$($r.name)' (id=$bearerTokenCredId)"

# ─── Phase 6: Import workflows ───────────────────────────────────────────────
# Credential IDs are substituted into the raw JSON before parsing, so imported
# workflows already have the correct credential IDs — no post-import patching needed.
if ($SkipWorkflowImport) {
    Write-Step "[3/3]" "Skipping workflow import (-SkipWorkflowImport set or no API key available)."
} else {
    Write-Step "[3/3]" "Importing workflows from: $WorkflowsPath"

    $workflowFiles = Get-ChildItem -Path $WorkflowsPath -Filter '*.json' -ErrorAction SilentlyContinue

    if (-not $workflowFiles) {
        Write-Note "No *.json files found in '$WorkflowsPath' — skipping import."
    } else {
        $importedCount = 0
        $skippedCount  = 0

        # Fetch existing workflow names once so we can skip duplicates on re-runs
        $existingNames = @{}
        try {
            $existingWfs = Invoke-RestMethod "$N8nUrl/api/v1/workflows?limit=250" `
                -Headers @{ 'X-N8N-API-KEY' = $apiKey } -ErrorAction Stop
            $existingWfs.data | ForEach-Object { $existingNames[$_.name] = $_.id }
        } catch {
            Write-Note "Could not fetch existing workflows for dedup check: $($_.Exception.Message)"
        }

        foreach ($file in $workflowFiles) {
            Write-Host "  Importing: $($file.Name)" -ForegroundColor White
            try {
                # Substitute credential placeholders in the raw JSON before parsing,
                # so imported workflows already have real IDs from the start.
                $rawJson = Get-Content $file.FullName -Raw
                $credSubs = [ordered]@{
                    'REPLACE_WITH_AUTONOMOUS_CREDENTIAL_ID'      = $autonomousCredId
                    'REPLACE_WITH_AUTONOMOUS_CREDENTIAL_NAME'    = $autonomousCredName
                    'REPLACE_WITH_AGENTUSER_OBO_CREDENTIAL_ID'   = $oboCredId
                    'REPLACE_WITH_AGENTUSER_OBO_CREDENTIAL_NAME' = $oboCredName
                    'REPLACE_WITH_AZURE_OPENAI_CREDENTIAL_ID'    = $openAiCredId
                    'REPLACE_WITH_AZURE_OPENAI_CREDENTIAL_NAME'  = $openAiCredName
                    'REPLACE_WITH_AZURE_OPENAI_DEPLOYMENT'       = $AzureOpenAiDeployment
                    'REPLACE_WITH_MCP_TOKEN_CREDENTIAL_ID'       = $mcpTokenCredId
                    'REPLACE_WITH_MCP_TOKEN_CREDENTIAL_NAME'     = $mcpTokenCredName
                    'REPLACE_WITH_BEARER_TOKEN_CREDENTIAL_ID'    = $bearerTokenCredId
                    'REPLACE_WITH_BEARER_TOKEN_CREDENTIAL_NAME'  = $bearerTokenCredName
                }
                foreach ($ph in $credSubs.Keys) {
                    $val = $credSubs[$ph]
                    if ($val) { $rawJson = $rawJson.Replace($ph, $val) }
                }
                $workflowJson = $rawJson | ConvertFrom-Json -Depth 30

                # Skip if a workflow with the same name already exists (idempotent re-runs)
                if ($existingNames.ContainsKey($workflowJson.name)) {
                    Write-Note "  Skipped '$($workflowJson.name)' — already exists (id: $($existingNames[$workflowJson.name]))"
                    $skippedCount++
                    continue
                }

                # Build a clean payload — only the properties accepted by the public API POST schema
                # Note: 'tags' is read-only on creation; 'active' and 'meta' are not accepted
                $allowed = @('name','nodes','connections','settings')
                $payload  = [PSCustomObject]@{}
                foreach ($prop in $allowed) {
                    if ($workflowJson.PSObject.Properties[$prop]) {
                        $payload | Add-Member -NotePropertyName $prop -NotePropertyValue $workflowJson.$prop
                    }
                }

                # Strip settings properties not accepted by the public API schema
                if ($payload.PSObject.Properties['settings'] -and $payload.settings) {
                    @('availableInMCP', 'binaryMode') | ForEach-Object {
                        $payload.settings.PSObject.Properties.Remove($_)
                    }
                }

                $importResp = Invoke-RestMethod `
                    -Uri     "$N8nUrl/api/v1/workflows" `
                    -Method  POST `
                    -Headers @{
                        'Content-Type'  = 'application/json'
                        'X-N8N-API-KEY' = $apiKey
                    } `
                    -Body    ($payload | ConvertTo-Json -Depth 30 -Compress)

                Write-OK "  Imported '$($importResp.name)' (id: $($importResp.id))"
                $importedCount++
            } catch {
                $errBody = $_.ErrorDetails.Message
                $respObj = $_.Exception.PSObject.Properties['Response']
                $scProp  = if ($respObj) { $respObj.Value.PSObject.Properties['StatusCode'] } else { $null }
                $status  = if ($scProp) { $scProp.Value.value__ } else { 0 }
                Write-Err "  Failed to import $($file.Name): HTTP $status - $errBody"
                $skippedCount++
            }
        }

        Write-Host ""
        Write-OK "Workflow import complete: $importedCount imported, $skippedCount skipped"
    }
}

# ─── Phase 8: Activate trigger workflows ─────────────────────────────────────
# Brief pause — n8n needs a moment after credential creation before allowing activation.
Start-Sleep -Seconds 3

Write-Step "[3/3]" "Activating trigger workflows..."

# Use public API with API key if available, otherwise session-based /rest/
if ($apiKey) {
    $wfListPath    = '/api/v1/workflows?limit=250'
    $wfAuth        = @{ ApiKey = $apiKey }
    $wfActivateBase = '/api/v1/workflows'
} else {
    $wfListPath    = '/rest/workflows'
    $wfAuth        = @{ UseSession = $true }
    $wfActivateBase = '/rest/workflows'
}

$activationData = $null
try {
    $activationList = Invoke-N8n -Method GET -Path $wfListPath @wfAuth `
        -RetryOnTransient -MaxAttempts 6 -InitialRetryDelaySeconds 3
    $activationData = if ($activationList.PSObject.Properties['data']) { $activationList.data } else { $activationList }
} catch {
    Write-Err "Could not list workflows for activation: $($_.Exception.Message)"
}

if ($activationData) {
    $activatedCount = 0
    foreach ($wfSummary in $activationData) {
        if ($wfSummary.active) { continue }

        $hasTrigger = $wfSummary.nodes | Where-Object {
            $_.type -like '*webhook*' -or $_.type -like '*chatTrigger*'
        }
        if (-not $hasTrigger) { continue }

        try {
            Invoke-N8n -Method POST -Path "$wfActivateBase/$($wfSummary.id)/activate" @wfAuth `
                -RetryOnTransient -MaxAttempts 3 -InitialRetryDelaySeconds 3 | Out-Null
            Write-OK "  Activated '$($wfSummary.name)'"
            $activatedCount++
        } catch {
            $errBody = if ($_.ErrorDetails) { $_.ErrorDetails.Message } else { $_.Exception.Message }
            Write-Err "  Could not activate '$($wfSummary.name)': $errBody"
        }
    }
    if ($activatedCount -eq 0) {
        Write-Note "  No inactive trigger workflows found to activate"
    }
}

# ─── Final Summary ────────────────────────────────────────────────────────────
$separator = "=" * 70

Write-Host ""
Write-Host $separator -ForegroundColor Magenta
Write-Host "  n8n CONFIGURATION COMPLETE" -ForegroundColor Magenta
Write-Host $separator -ForegroundColor Magenta
Write-Host ""
Write-Host "  n8n URL   : $N8nUrl"
Write-Host "  Owner     : $OwnerEmail"
if ($apiKey) {
    Write-Host "  API Key   : $apiKey"
    Write-Host ""
    Write-Host "  Save the API key above — you will not see it again unless you" -ForegroundColor Yellow
    Write-Host "  go to n8n → Settings → API in the UI." -ForegroundColor Yellow
}
Write-Host ""
  Write-Host "  NEXT: Open n8n to activate workflows and test them." -ForegroundColor Cyan
Write-Host ""
Write-Host $separator -ForegroundColor Magenta
Write-Host ""

# Return the API key so callers (e.g. a wrapper script) can capture it
return @{
    N8nUrl = $N8nUrl
    ApiKey = $apiKey
    Email  = $OwnerEmail
}
