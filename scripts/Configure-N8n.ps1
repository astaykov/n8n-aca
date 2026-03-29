#Requires -Version 7
<#
.SYNOPSIS
    Configures a freshly deployed n8n instance: creates the owner account,
    generates an API key, and imports all workflow JSON files.

.DESCRIPTION
    Automates the post-deployment n8n setup so no manual browser interaction
    is required:

      1. Waits for n8n to become healthy (retries for up to 10 min)
      2. Checks whether the owner account has already been created
      3. Creates the n8n owner account via the setup API
      4. Logs in and retrieves an API key
      5. Imports every *.json file found in the workflows/ folder

    Designed to run immediately after 'azd up' completes.

.PARAMETER N8nUrl
    The base HTTPS URL of the deployed n8n instance, e.g.:
    https://ca-n8n-abc123.eastus2.azurecontainerapps.io

.PARAMETER OwnerEmail
    Email address for the n8n owner (admin) account.

.PARAMETER OwnerPassword
    Password for the n8n owner account. Must meet n8n requirements:
    minimum 8 characters, mixed case, number.

.PARAMETER OwnerFirstName
    First name for the n8n owner account (default: n8n).

.PARAMETER OwnerLastName
    Last name for the n8n owner account (default: Admin).

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
    [string]$OwnerFirstName = 'n8n',

    [Parameter(Mandatory = $false)]
    [string]$OwnerLastName = 'Admin',

    [Parameter(Mandatory = $false)]
    [string]$WorkflowsPath = (Join-Path $PSScriptRoot '..\workflows'),

    [Parameter(Mandatory = $false)]
    [switch]$SkipWorkflowImport,

    [Parameter(Mandatory = $false)]
    [string]$CommunityNodePackage = '@astaykov/n8n-nodes-entraagentid',

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
    [string]$AzureOpenAiDeployment = 'gpt-5.4'
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
        [switch]$UseSession
    )
    $uri  = "$N8nUrl$Path"
    $baseHeaders = @{ 'Content-Type' = 'application/json' } + $Headers

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

    try {
        $response = Invoke-RestMethod @params
        return $response
    } catch {
        $statusCode = $_.Exception.Response.StatusCode.value__
        $detail     = $_.ErrorDetails.Message
        throw "n8n API error [$Method $Path] HTTP $statusCode : $detail"
    }
}

# ─── Phase 1 + 2: Wait for n8n to be fully ready, then read setup state ──────
# We poll /rest/settings rather than /healthz because /healthz fires as soon as
# the HTTP server starts — before DB migrations finish and REST routes register.
# /rest/settings only succeeds when n8n is truly ready to accept API calls.
Write-Step "[1/4]" "Waiting for n8n at $N8nUrl to become ready (polling /rest/settings)..."

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

# ─── Phase 2: Determine setup state from the settings response ────────────────
Write-Step "[2/4]" "Checking n8n owner setup status..."

$needsSetup = $false
if ($settings) {
    $dataProp = $settings.PSObject.Properties['data']
    $settingsData = if ($dataProp) { $dataProp.Value } else { $settings }
    $umProp = $settingsData.PSObject.Properties['userManagement']
    if ($umProp) {
        $showProp = $umProp.Value.PSObject.Properties['showSetupOnFirstLoad']
        $needsSetup = $showProp -and $showProp.Value -eq $true
    }
}

# n8n login body — field name changed to emailOrLdapLoginId in recent versions
$loginBody = @{ emailOrLdapLoginId = $OwnerEmail; password = $OwnerPassword }

if (-not $needsSetup) {
    Write-Note "Owner account already set up — skipping account creation."
    Write-Note "Attempting login with provided credentials..."

    try {
        $loginResp = Invoke-N8n -Method POST -Path '/rest/login' -Body $loginBody -UseSession
        Write-OK "Logged in as $OwnerEmail"
    } catch {
        Write-Err "Login failed. If you forgot the password, reset it via the n8n UI."
        throw $_
    }
} else {
    # ─── Phase 2a: Create owner account ──────────────────────────────────────
    Write-Step "[2/4]" "Creating n8n owner account ($OwnerEmail)..."

    $setupBody = @{
        email     = $OwnerEmail
        firstName = $OwnerFirstName
        lastName  = $OwnerLastName
        password  = $OwnerPassword
    }

    $setupResp = Invoke-N8n -Method POST -Path '/rest/owner/setup' -Body $setupBody -UseSession
    Write-OK "Owner account created: $OwnerEmail"

    # Log in to establish a session cookie
    Invoke-N8n -Method POST -Path '/rest/login' -Body $loginBody -UseSession | Out-Null
    Write-OK "Logged in"
}

# ─── Phase 3: Install community node ─────────────────────────────────────────
# Even when -SkipNodeInstall is set, verify the node is actually present.
# If it's missing (fresh deploy), install it anyway.
$_nodeAlreadyPresent = $false
if ($SkipNodeInstall) {
    try {
        $pkgCheck = Invoke-N8n -Method GET -Path '/rest/community-packages' -UseSession -ErrorAction Stop
        $_nodeAlreadyPresent = ($pkgCheck.data | Where-Object {
            $_.packageName -like '*entraagentid*' -or $_.name -like '*entraagentid*'
        }) -as [bool]
    } catch { $_nodeAlreadyPresent = $false }
}

if ($SkipNodeInstall -and $_nodeAlreadyPresent) {
    Write-Step "[3/5]" "Skipping community node install — node already present (-SkipNodeInstall set)."
} else {
    if ($SkipNodeInstall -and -not $_nodeAlreadyPresent) {
        Write-Step "[3/5]" "Node not installed despite -SkipNodeInstall — installing now..."
    }
    Write-Step "[3/5]" "Installing community node: $CommunityNodePackage"

    $nodeInstalled = $false
    try {
        $pkgList = Invoke-N8n -Method GET -Path '/rest/community-packages' -UseSession
        $alreadyThere = $pkgList.data | Where-Object {
            $_.packageName -like '*entraagentid*' -or $_.name -like '*entraagentid*'
        }
        if ($alreadyThere) {
            # DB entry exists — force a PATCH update so npm reinstalls and n8n reloads the node types.
            # Without this, the node can appear "installed" in the DB but remain unrecognised in workflows.
            Write-Note "Package registered (v$($alreadyThere.installedVersion)) — forcing reload via update..."
            try {
                Invoke-N8n -Method PATCH -Path '/rest/community-packages' `
                    -Body @{ name = $CommunityNodePackage } `
                    -UseSession | Out-Null
                Write-OK "Package updated/reloaded — waiting for n8n to restart..."
            } catch {
                Write-Note "PATCH update skipped (already latest): $($_.ErrorDetails.Message)"
                $nodeInstalled = $true   # up-to-date, no restart needed
            }
        }
    } catch {
        Write-Note "Could not list community packages — will attempt fresh install."
    }

    if (-not $nodeInstalled) {
        try {
            Write-Note "Installing $CommunityNodePackage — n8n will restart..."
            try {
                Invoke-N8n -Method POST -Path '/rest/community-packages' `
                    -Body @{ name = $CommunityNodePackage } `
                    -UseSession | Out-Null
            } catch {
                if ($_.ErrorDetails.Message -like '*already installed*') {
                    # Registered but not loaded — PATCH forces npm reinstall + restart
                    Write-Note "Package registered but not loaded — forcing reinstall via PATCH..."
                    Invoke-N8n -Method PATCH -Path '/rest/community-packages' `
                        -Body @{ name = $CommunityNodePackage } `
                        -UseSession | Out-Null
                } else {
                    throw
                }
            }

            # n8n restarts after any community package install/update — wait for it
            Write-Note "Waiting for n8n to restart (up to 5 min)..."
            Start-Sleep -Seconds 20
            $maxWaitSec2 = 300
            $elapsed2    = 0
            while ($elapsed2 -lt $maxWaitSec2) {
                try {
                    $h = Invoke-RestMethod -Uri "$N8nUrl/healthz" -Method GET -TimeoutSec 10
                    if ($h.status -eq 'ok') { break }
                } catch {}
                Start-Sleep -Seconds 10
                $elapsed2 += 10
            }
            if ($elapsed2 -ge $maxWaitSec2) {
                throw "n8n did not come back online within ${maxWaitSec2}s after node install."
            }
            Write-OK "n8n back online — re-logging in after restart..."

            # Session cookie is invalidated on restart — create a new session
            $session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
            Invoke-N8n -Method POST -Path '/rest/login' -Body $loginBody -UseSession | Out-Null
            Write-OK "Re-logged in"
            $nodeInstalled = $true
        } catch {
            Write-Err "Community node install failed: $($_.Exception.Message)"
            Write-Note "Install manually: n8n UI → Settings → Community Nodes → $CommunityNodePackage"
        }
    }
}

# ─── Phase 4: Create API key ──────────────────────────────────────────────────
Write-Step "[4/5]" "Creating n8n API key..."

$browserId  = [System.Guid]::NewGuid().ToString()
$apiKey     = $null
$keyLabel   = 'automation'
# Expires 10 years from now (Unix timestamp in milliseconds)
$expiresAt  = [long]([System.DateTimeOffset]::UtcNow.AddYears(10).ToUnixTimeMilliseconds())

# Delete any existing key with the same label to avoid "entry already exists" error
try {
    $existingKeys = Invoke-N8n -Method GET -Path '/rest/api-keys' `
        -Headers @{ 'browser-id' = $browserId } -UseSession
    $existingKeys.data | Where-Object { $_.label -eq $keyLabel } | ForEach-Object {
        Write-Note "Deleting existing API key '$keyLabel' (id: $($_.id))..."
        Invoke-N8n -Method DELETE -Path "/rest/api-keys/$($_.id)" `
            -Headers @{ 'browser-id' = $browserId } -UseSession | Out-Null
    }
} catch {
    # Best-effort — proceed even if listing/deleting fails
}

$apiKeyBody = @{
    label     = $keyLabel
    scopes    = @(
        'workflow:create', 'workflow:read', 'workflow:update',
        'workflow:delete', 'workflow:list', 'workflow:execute'
    )
    expiresAt = $expiresAt
}

try {
    $apiKeyResp = Invoke-N8n -Method POST -Path '/rest/api-keys' `
        -Body $apiKeyBody `
        -Headers @{ 'browser-id' = $browserId } `
        -UseSession
    $apiKey = $apiKeyResp.data.rawApiKey ?? $apiKeyResp.rawApiKey ?? $apiKeyResp.data.apiKey ?? $apiKeyResp.apiKey
} catch {
    Write-Note "Could not auto-create an API key: $($_.Exception.Message)"
    Write-Note "Please create one manually: n8n → Settings → API → Create API Key"
    Write-Note "Then re-run this script with -SkipWorkflowImport."
}

if ($apiKey) {
    Write-OK "API key created"
} else {
    Write-Note "Continuing without API key — workflow import will be skipped."
    $SkipWorkflowImport = $true
}

# ─── Phase 5: Create n8n credentials ─────────────────────────────────────────
# Credentials are created BEFORE workflow import so their real IDs can be
# substituted directly into the workflow JSON at import time — no patching needed.
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

# ── 5a: Entra Agent ID credentials ──────────────────────────────────────────
$_canCreateCreds = $EntraTenantId -and $EntraBlueprintId -and $EntraBlueprintSecret -and $EntraAgentId -and $EntraAgentUserUpn
if ($SkipCredentialCreate -or -not $_canCreateCreds) {
    Write-Step "[5a/7]" "Skipping Entra credential creation (-SkipCredentialCreate or missing parameters)."
    if (-not $SkipCredentialCreate -and -not $_canCreateCreds) {
        Write-Note "Supply -EntraTenantId, -EntraBlueprintId, -EntraBlueprintSecret, -EntraAgentId, -EntraAgentUserUpn to auto-create credentials."
    }
} else {
    Write-Step "[5a/7]" "Creating Entra Agent ID credentials in n8n..."
    $tokenEndpoint = "https://login.microsoftonline.com/$EntraTenantId/oauth2/v2.0/token"
    $credNames = @($autonomousCredName, $oboCredName)
    try {
        $existing = Invoke-N8n -Method GET -Path '/rest/credentials' -UseSession
        $existing.data | Where-Object { $_.name -in $credNames } | ForEach-Object {
            Invoke-N8n -Method DELETE -Path "/rest/credentials/$($_.id)" -UseSession | Out-Null
            Write-Note "Deleted existing credential: $($_.name)"
        }
    } catch { <# best-effort #> }
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
            name        = $cred.name
            type        = "entraAgentIDApi"
            data        = $cred.data
            nodesAccess = @()
        }
        $r = Invoke-N8n -Method POST -Path '/rest/credentials' -Body $body -UseSession
        $createdId = $r.data.id
        if ($cred.name -like '*Autonomous*') { $autonomousCredId = $createdId }
        else                                 { $oboCredId        = $createdId }
        Write-OK "Created credential '$($r.data.name)' (id=$createdId)"
    }
}

# ── 5b: Azure OpenAI credential ──────────────────────────────────────────────
$_canCreateOpenAiCred = $AzureOpenAiResourceName -and $AzureOpenAiApiKey
if (-not $_canCreateOpenAiCred) {
    Write-Step "[5b/7]" "Skipping Azure OpenAI credential creation (no -AzureOpenAiResourceName / -AzureOpenAiApiKey supplied)."
} else {
    Write-Step "[5b/7]" "Creating Azure OpenAI credential '$openAiCredName' in n8n..."
    try {
        $existing = Invoke-N8n -Method GET -Path '/rest/credentials' -UseSession
        $existing.data | Where-Object { $_.name -eq $openAiCredName } | ForEach-Object {
            Invoke-N8n -Method DELETE -Path "/rest/credentials/$($_.id)" -UseSession | Out-Null
            Write-Note "Deleted existing credential: $($_.name)"
        }
    } catch { <# best-effort #> }
    $body = @{
        name        = $openAiCredName
        type        = 'azureOpenAiApi'
        data        = @{
            resourceName = $AzureOpenAiResourceName
            apiKey       = $AzureOpenAiApiKey
            apiVersion   = $AzureOpenAiApiVersion
        }
        nodesAccess = @()
    }
    $r = Invoke-N8n -Method POST -Path '/rest/credentials' -Body $body -UseSession
    $openAiCredId = $r.data.id
    Write-OK "Created credential '$($r.data.name)' (id=$openAiCredId)"
}

# ── 5c: MCP token-forwarding credential (httpHeaderAuth) ─────────────────────
Write-Step "[5c/7]" "Creating MCP token-forwarding credential '$mcpTokenCredName' in n8n..."
try {
    $existing = Invoke-N8n -Method GET -Path '/rest/credentials' -UseSession
    $existing.data | Where-Object { $_.name -eq $mcpTokenCredName } | ForEach-Object {
        Invoke-N8n -Method DELETE -Path "/rest/credentials/$($_.id)" -UseSession | Out-Null
        Write-Note "Deleted existing credential: $($_.name)"
    }
} catch { <# best-effort #> }
$body = @{
    name        = $mcpTokenCredName
    type        = 'httpHeaderAuth'
    data        = @{
        name  = 'Authorization'
        value = "=Bearer {{ `$('Entra Agent ID Authentication Manager').item.json.agent_id_access_token }}"
    }
    nodesAccess = @()
}
$r = Invoke-N8n -Method POST -Path '/rest/credentials' -Body $body -UseSession
$mcpTokenCredId = $r.data.id
Write-OK "Created credential '$($r.data.name)' (id=$mcpTokenCredId)"

# ── 5d: Bearer token-forwarding credential (httpBearerAuth) ──────────────────
Write-Step "[5d/7]" "Creating Bearer token-forwarding credential '$bearerTokenCredName' in n8n..."
try {
    $existing = Invoke-N8n -Method GET -Path '/rest/credentials' -UseSession
    $existing.data | Where-Object { $_.name -eq $bearerTokenCredName } | ForEach-Object {
        Invoke-N8n -Method DELETE -Path "/rest/credentials/$($_.id)" -UseSession | Out-Null
        Write-Note "Deleted existing credential: $($_.name)"
    }
} catch { <# best-effort #> }
$body = @{
    name        = $bearerTokenCredName
    type        = 'httpBearerAuth'
    data        = @{
        token = "={{ `$('Entra Agent ID Authentication Manager').item.json.agent_id_access_token }}"
    }
    nodesAccess = @()
}
$r = Invoke-N8n -Method POST -Path '/rest/credentials' -Body $body -UseSession
$bearerTokenCredId = $r.data.id
Write-OK "Created credential '$($r.data.name)' (id=$bearerTokenCredId)"

# ─── Phase 6: Import workflows ───────────────────────────────────────────────
# Credential IDs are substituted into the raw JSON before parsing, so imported
# workflows already have the correct credential IDs — no post-import patching needed.
if ($SkipWorkflowImport) {
    Write-Step "[6/7]" "Skipping workflow import (-SkipWorkflowImport set or no API key available)."
} else {
    Write-Step "[6/7]" "Importing workflows from: $WorkflowsPath"

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

# ─── Phase 8: Activate trigger workflows ────────────────────────────────────
# Uses the session-based /rest/ endpoint (proven reliable) rather than the
# public API, which has version-dependent versionId requirements and scope issues.
# Brief pause — n8n needs a moment after credential PUTs before allowing activation.
Start-Sleep -Seconds 3

Write-Step "[8/7]" "Activating trigger workflows..."
try {
    $activationList = (Invoke-N8n -Method GET -Path '/rest/workflows' -UseSession)
    $activationData = if ($activationList.PSObject.Properties['data']) { $activationList.data } else { $activationList }
} catch {
    Write-Err "Could not list workflows for activation: $($_.Exception.Message)"
    $activationData = $null
}

if ($activationData) {
    $activatedCount = 0
    foreach ($wfSummary in $activationData) {
        if ($wfSummary.active) { continue }

        try {
            $wfResp = Invoke-N8n -Method GET -Path "/rest/workflows/$($wfSummary.id)" -UseSession -ErrorAction Stop
            $fullWf = if ($wfResp.PSObject.Properties['data']) { $wfResp.data } else { $wfResp }
        } catch { continue }

        $hasTrigger = $fullWf.nodes | Where-Object {
            $_.type -like '*webhook*' -or $_.type -like '*chatTrigger*'
        }
        if (-not $hasTrigger) { continue }

        $versionIdProp = $fullWf.PSObject.Properties['versionId']
        $activateBody  = if ($versionIdProp) { @{ versionId = $versionIdProp.Value } } else { @{} }

        try {
            Invoke-N8n -Method POST -Path "/rest/workflows/$($wfSummary.id)/activate" `
                -Body $activateBody -UseSession -ErrorAction Stop | Out-Null
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
