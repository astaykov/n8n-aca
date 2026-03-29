#Requires -Version 7
<#
.SYNOPSIS
    Sets up Microsoft Entra Agent ID for n8n and the Graph MCP Server for Enterprise.

.DESCRIPTION
    Fully automated (non-interactive) setup of Entra Agent ID:
      1. Installs Microsoft.Entra / Microsoft.Entra.Beta modules (v1.2.0+)
      2. Connects to your tenant (browser sign-in once)
      3. Creates Blueprint, Agent Identity, and Agent User automatically
      4. Adds a client secret to the Blueprint (captured in memory)
      4b. Grants Microsoft Graph app role assignments to the Agent Identity SP
      5. Enables the Microsoft Graph MCP Server for Enterprise in your tenant
      6. Grants the Agent Identity SP delegated access to the MCP Server
      7. Prints a ready-to-copy credential table for n8n

    At the end your n8n Blueprint can act:
      • Autonomously  → scope: https://graph.microsoft.com/.default
      • On behalf of the Agent User → scope: https://mcp.svc.cloud.microsoft/.default

.PARAMETER TenantId
    Your Entra tenant ID (GUID). Required.

.PARAMETER BlueprintName
    Display name for the Agent Identity Blueprint (default: n8n-agent-blueprint).

.PARAMETER AgentIdentityName
    Display name for the Agent Identity (default: n8n-agent-identity).

.PARAMETER AgentUserPrefix
    UPN prefix for the Agent User. A short tenant-derived suffix is appended
    to keep it unique (default: n8nagent → e.g. n8nagent06a05be1@contoso.onmicrosoft.com).

.PARAMETER SkipMcpServer
    Skip enabling the Graph MCP Server for Enterprise (steps 5-6).

.EXAMPLE
    # Fully automatic — one command, one browser sign-in
    .\Setup-EntraAgentId.ps1 -TenantId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"

.EXAMPLE
    # Re-run and skip recreation (use existing objects)
    .\Setup-EntraAgentId.ps1 `
        -TenantId        "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
        -BlueprintId     "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
        -AgentIdentityId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
        -AgentUserUpn    "n8nagentXXXXXXXX@contoso.onmicrosoft.com" `
        -BlueprintSecret "your-secret-here"

.NOTES
    Requires PowerShell 7+.
    Run as a user with Global Administrator or Application Administrator role.
    Internet access required (module download + Entra authentication).
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, HelpMessage = "Your Entra tenant ID (GUID)")]
    [ValidatePattern('^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
    [string]$TenantId,

    [Parameter(Mandatory = $false)]
    [string]$BlueprintName = 'n8n-agent-blueprint',

    [Parameter(Mandatory = $false)]
    [string]$AgentIdentityName = 'n8n-agent-identity',

    [Parameter(Mandatory = $false)]
    [string]$AgentUserPrefix = 'n8nagent',

    [Parameter(Mandatory = $false)]
    [switch]$SkipMcpServer,

    # ── Resume-from-Phase-4 shortcuts ────────────────────────────────────────
    # Supply all three to skip the interactive cmdlet (Phase 3) entirely.
    [Parameter(Mandatory = $false)]
    [string]$BlueprintId,

    [Parameter(Mandatory = $false)]
    [string]$AgentIdentityId,

    [Parameter(Mandatory = $false)]
    [string]$AgentUserUpn,

    # Supply the Blueprint client secret directly to skip the interactive prompt.
    [Parameter(Mandatory = $false)]
    [string]$BlueprintSecret,

    # ── SPA app registration setup (Phase 7) ─────────────────────────────────
    # Supply SpaFqdn to create/update the SPA app registration with the
    # correct redirect URI so the deployed Container App can authenticate.
    [Parameter(Mandatory = $false)]
    [string]$SpaFqdn,

    [Parameter(Mandatory = $false)]
    [string]$SpaAppName = 'n8n-test-spa',

    # Supply on re-runs to avoid re-querying the Blueprint Service Principal appId.
    [Parameter(Mandatory = $false)]
    [string]$BlueprintAppId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Microsoft Graph MCP Server for Enterprise – fixed well-known App ID
$MCP_SERVER_APP_ID = 'e8c77dc2-69b3-43f4-bc51-3213c9d915b4'

# Default MCP scopes granted to the Agent Identity. Expand as needed.
$MCP_SCOPES = @(
    'MCP.User.Read.All'
    'MCP.Organization.Read.All'
    'MCP.Group.Read.All'
    'MCP.GroupMember.Read.All'
    'MCP.Application.Read.All'
    'MCP.AuditLog.Read.All'
    'MCP.Reports.Read.All'
    'MCP.Policy.Read.All'
    'MCP.Domain.Read.All'
    'MCP.Device.Read.All'
)

# ─── Helpers ──────────────────────────────────────────────────────────────────
function Write-Step  { param([string]$s, [string]$t); Write-Host "`n$s $t" -ForegroundColor Cyan }
function Write-OK    { param([string]$t); Write-Host "  [OK] $t" -ForegroundColor Green }
function Write-Note  { param([string]$t); Write-Host "  [>>] $t" -ForegroundColor Yellow }
function Write-Err   { param([string]$t); Write-Host "  [!!] $t" -ForegroundColor Red }

# ─── Phase 0: Validate PowerShell version ─────────────────────────────────────
Write-Step "[0/6]" "Checking prerequisites..."
if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw "PowerShell 7 or higher is required. Current version: $($PSVersionTable.PSVersion).`nInstall from: https://aka.ms/pwsh"
}
Write-OK "PowerShell $($PSVersionTable.PSVersion)"

# ─── Phase 1: Install / update modules ────────────────────────────────────────
Write-Step "[1/6]" "Checking Microsoft.Entra PowerShell modules (v1.2.0+)..."

$requiredModules = @(
    @{ Name = 'Microsoft.Entra';      MinVersion = [version]'1.2.0' }
    @{ Name = 'Microsoft.Entra.Beta'; MinVersion = [version]'1.2.0' }
)

foreach ($mod in $requiredModules) {
    $installed = Get-Module -ListAvailable -Name $mod.Name |
                 Where-Object { $_.Version -ge $mod.MinVersion } |
                 Sort-Object Version -Descending |
                 Select-Object -First 1

    if ($installed) {
        Write-OK "$($mod.Name) v$($installed.Version) already installed"
    } else {
        Write-Note "Installing $($mod.Name) >= $($mod.MinVersion) from PSGallery..."
        Install-Module -Name $mod.Name -MinimumVersion $mod.MinVersion.ToString() `
                       -Repository PSGallery -Force -AllowClobber -Scope CurrentUser
        Write-OK "$($mod.Name) installed"
    }
}

# ─── Phase 2: Connect to Entra ────────────────────────────────────────────────
Write-Step "[2/6]" "Connecting to Microsoft Entra (tenant: $TenantId)..."
Write-Note "A browser window will open. Sign in with Global Administrator or Application Administrator."

$connectScopes = @(
    'Organization.Read.All'
    'AgentIdentityBlueprint.ReadWrite.All'
    'AgentIdentityBlueprint.AddRemoveCreds.All'
    'AgentIdentityBlueprintPrincipal.ReadWrite.All'
    'AgentIdentity.ReadWrite.All'
    'AgentIdUser.ReadWrite.All'
    'Application.ReadWrite.All'
    'AppRoleAssignment.ReadWrite.All'
    'DelegatedPermissionGrant.ReadWrite.All'
    'Directory.Read.All'
)

Connect-Entra -Scopes $connectScopes -TenantId $TenantId -NoWelcome

$context = Get-EntraContext
Write-OK "Connected as: $($context.Account)"
Write-OK "Tenant: $($context.TenantId)"

# ─── Phase 3: Create Agent Identity objects (non-interactive) ─────────────────
$_skipInteractive = $BlueprintId -and $AgentIdentityId -and $AgentUserUpn
$blueprintSecretPlain = $null   # initialised here so Phase 4 can check it safely under Set-StrictMode

if ($_skipInteractive) {
    Write-Step "[3/6]" "Skipping object creation — IDs supplied via parameters."
    Write-OK "BlueprintId     : $BlueprintId"
    Write-OK "AgentIdentityId : $AgentIdentityId"
    Write-OK "AgentUserUpn    : $AgentUserUpn"
} else {
    Write-Step "[3/6]" "Creating Blueprint, Agent Identity, and Agent User automatically..."

    # Derive a stable 8-char suffix from the tenant ID so repeated runs reuse same names
    $suffix = $TenantId.Replace('-','').Substring(0,8)

    # Resolve current user's objectId so we can pass -SponsorUserIds and skip interactive prompts
    $currentUserObjId = $null
    try {
        $ctx = Get-EntraContext
        $currentUserObj = Get-EntraUser -Filter "userPrincipalName eq '$($ctx.Account)'" -ErrorAction SilentlyContinue |
                          Select-Object -First 1
        $currentUserObjId = $currentUserObj.Id
    } catch { }
    if ($currentUserObjId) {
        Write-Note "Using current user as sponsor: $currentUserObjId"
    } else {
        Write-Note "Could not resolve current user objectId — sponsor prompts may appear."
    }
    $sponsorSplat = if ($currentUserObjId) { @{ SponsorUserIds = @($currentUserObjId) } } else { @{} }

    # ── 3a: Create Blueprint ──────────────────────────────────────────────────
    # New-EntraBetaAgentIdentityBlueprint returns the Blueprint object ID as a bare string.
    # Passing -SponsorUserIds avoids interactive sponsor/owner prompts.
    Write-Note "Creating Agent Identity Blueprint '$BlueprintName'..."
    $BlueprintId = New-EntraBetaAgentIdentityBlueprint -DisplayName $BlueprintName @sponsorSplat -ErrorAction Stop
    Write-OK "Blueprint created: $BlueprintId"

    # ── 3b: Create Blueprint Service Principal ────────────────────────────────
    # We need the Blueprint SP to exist so client-credentials tokens can be issued.
    # We also capture the appId from the SP response — IMPORTANT: the module's
    # Connect-AgentIdentityBlueprint uses the object ID (id) as the OAuth2 client_id,
    # which is WRONG (Azure AD requires the appId). We bypass those cmdlets entirely
    # and call the Graph API directly using a token we acquire with the correct appId.
    Write-Note "Creating Blueprint Service Principal..."
    $bpSP = New-EntraBetaAgentIdentityBlueprintPrincipal -AgentBlueprintId $BlueprintId -ErrorAction Stop
    $BlueprintAppId = $bpSP.appId   # the appId is what OAuth2 client_credentials actually needs
    $BlueprintSpObjId = $bpSP.id
    Write-OK "Blueprint SP created: $BlueprintSpObjId  (appId: $BlueprintAppId)"

    # ── 3c: Grant required app role to Blueprint SP (admin delegated context) ─
    # The Blueprint SP needs AgentIdUser.ReadWrite.IdentityParentedBy (app role on MS Graph)
    # to be able to POST /beta/servicePrincipals/Microsoft.Graph.AgentIdentity
    # and POST /beta/users (agentUser). This must be granted BEFORE acquiring the Blueprint token.
    Write-Note "Granting AgentIdUser.ReadWrite.IdentityParentedBy to Blueprint SP..."
    $graphSpId = (Invoke-MgGraphRequest -Method GET `
        -Uri "v1.0/servicePrincipals?`$filter=appId eq '00000003-0000-0000-c000-000000000000'&`$select=id" `
        ).value[0].id
    $agentIdUserRoleId = "4aa6e624-eee0-40ab-bdd8-f9639038a614"  # AgentIdUser.ReadWrite.IdentityParentedBy
    # Check if already assigned
    $existingAssignments = (Invoke-MgGraphRequest -Method GET `
        -Uri "v1.0/servicePrincipals/$BlueprintSpObjId/appRoleAssignments").value
    if ($existingAssignments | Where-Object { $_.appRoleId -eq $agentIdUserRoleId }) {
        Write-OK "AgentIdUser.ReadWrite.IdentityParentedBy already assigned"
    } else {
        Invoke-MgGraphRequest -Method POST `
            -Uri "v1.0/servicePrincipals/$BlueprintSpObjId/appRoleAssignments" `
            -Body (@{ principalId = $BlueprintSpObjId; resourceId = $graphSpId; appRoleId = $agentIdUserRoleId } | ConvertTo-Json) | Out-Null
        Write-OK "AgentIdUser.ReadWrite.IdentityParentedBy granted to Blueprint SP"
    }

    # ── 3c: Add client secret ─────────────────────────────────────────────────
    Write-Note "Adding client secret to Blueprint..."
    $secretResp = Add-EntraBetaClientSecretToAgentIdentityBlueprint -AgentBlueprintId $BlueprintId -ErrorAction Stop
    $blueprintSecretPlain = $secretResp.SecretText
    if (-not $blueprintSecretPlain) {
        throw "Add-EntraBetaClientSecretToAgentIdentityBlueprint did not return a SecretText — cannot continue"
    }
    Write-OK "Blueprint secret captured"

    # ── 3d: Acquire Blueprint SP token (retry until SP propagates) ────────────
    # The module cmdlets New-EntraBetaAgentIDForAgentIdentityBlueprint and
    # New-EntraBetaAgentIDUserForAgentId both call Connect-AgentIdentityBlueprint
    # internally, but that function uses the object ID as the OAuth2 client_id instead
    # of the appId — so auth always fails. We bypass those cmdlets and call the Graph
    # API directly using a token we get here with the CORRECT appId.
    $tokenEndpointUrl = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token"
    $blueprintToken   = $null
    Write-Note "Waiting for Blueprint SP to propagate and acquiring client-credentials token..."
    for ($t = 1; $t -le 12; $t++) {
        if ($t -gt 1) { Start-Sleep -Seconds 15 }
        try {
            $tokResp = Invoke-RestMethod -Uri $tokenEndpointUrl -Method POST -Body @{
                grant_type    = 'client_credentials'
                client_id     = $BlueprintAppId
                client_secret = $blueprintSecretPlain
                scope         = 'https://graph.microsoft.com/.default'
            }
            $blueprintToken = $tokResp.access_token
            Write-OK "Blueprint SP token acquired (attempt $t)"
            break
        } catch {
            Write-Note "  Attempt $t/12 failed (SP propagation delay): $($_.Exception.Message)"
        }
    }
    if (-not $blueprintToken) {
        throw "Could not acquire Blueprint client-credentials token after 12 attempts (~3 min). Check Blueprint appId: $BlueprintAppId"
    }
    $bpAuthHeader = @{ Authorization = "Bearer $blueprintToken" }

    # ── 3e: Create Agent Identity via direct Graph call ───────────────────────
    Write-Note "Creating Agent Identity '$AgentIdentityName'..."
    $aiBodyObj = [ordered]@{
        displayName              = $AgentIdentityName
        AgentIdentityBlueprintId = $BlueprintId
    }
    if ($currentUserObjId) {
        $aiBodyObj['sponsors@odata.bind'] = @("https://graph.microsoft.com/v1.0/users/$currentUserObjId")
    }
    $aiBody = $aiBodyObj | ConvertTo-Json -Depth 3
    $aiResp = $null
    for ($r = 1; $r -le 10; $r++) {
        if ($r -gt 1) { Start-Sleep -Seconds 15 }
        try {
            $aiResp = Invoke-RestMethod `
                -Uri         "https://graph.microsoft.com/beta/servicePrincipals/Microsoft.Graph.AgentIdentity" `
                -Method      POST `
                -Headers     $bpAuthHeader `
                -Body        $aiBody `
                -ContentType "application/json"
            break
        } catch {
            $detail = $_.ErrorDetails.Message
            Write-Note "  Agent Identity attempt $r/10: $($_.Exception.Message) | $detail"
        }
    }
    if (-not $aiResp) { throw "Failed to create Agent Identity after 10 attempts." }
    $AgentIdentityId = $aiResp.id
    Write-OK "Agent Identity created: $AgentIdentityId"

    # ── 3f: Create Agent User via direct Graph call ───────────────────────────
    $tenantDomainFqdn = (Get-EntraDomain | Where-Object { $_.IsDefault } | Select-Object -First 1).Id

    $existingAuResp = $null

    # 1. Check if this Agent Identity already owns an Agent User (most reliable check)
    try {
        $linkedUsersResp = Invoke-RestMethod `
            -Uri         "https://graph.microsoft.com/beta/users?`$filter=identityParentId eq '$AgentIdentityId'&`$select=id,userPrincipalName,mailNickname" `
            -Method      GET `
            -Headers     $bpAuthHeader `
            -ContentType "application/json" `
            -ErrorAction Stop
        $existingAuResp = $linkedUsersResp.value | Select-Object -First 1
    } catch { $existingAuResp = $null }

    if ($existingAuResp) {
        $AgentUserUpn = $existingAuResp.userPrincipalName
        $mailNickname = $existingAuResp.mailNickname
        Write-Note "Agent User '$AgentUserUpn' already linked to Agent Identity — reusing."
    } else {
        # 2. No linked user found — check if the deterministic UPN already exists in the directory
        $candidateUpn = "$AgentUserPrefix$suffix@$tenantDomainFqdn"
        try {
            $existingAuResp = Invoke-RestMethod `
                -Uri         "https://graph.microsoft.com/beta/users/$([uri]::EscapeDataString($candidateUpn))" `
                -Method      GET `
                -Headers     $bpAuthHeader `
                -ContentType "application/json" `
                -ErrorAction Stop
        } catch { $existingAuResp = $null }

        if ($existingAuResp) {
            $AgentUserUpn = $existingAuResp.userPrincipalName
            $mailNickname = $existingAuResp.mailNickname
            Write-Note "Agent User '$AgentUserUpn' already exists in directory — reusing."
        } else {
            # UPN is free — use it; random fallback on conflict inside the loop below
            $AgentUserUpn = $candidateUpn
            $mailNickname = "$AgentUserPrefix$suffix"
        }
    }

    $auResp = $existingAuResp
    if (-not $auResp) {
        $auDisplayName = "n8n Agent User ($AgentUserPrefix)"
        $BuildAuBody = {
            @{
                "@odata.type"     = "microsoft.graph.agentUser"
                displayName       = $auDisplayName
                userPrincipalName = $AgentUserUpn
                identityParentId  = $AgentIdentityId
                mailNickname      = $mailNickname
                accountEnabled    = $true
            } | ConvertTo-Json
        }
        $auBody = & $BuildAuBody
        Write-Note "Creating Agent User '$AgentUserUpn'..."
        for ($r = 1; $r -le 10; $r++) {
            if ($r -gt 1) { Start-Sleep -Seconds 15 }
            Write-Note "  Payload (attempt $r/10): $auBody"
            try {
                $auResp = Invoke-RestMethod `
                    -Uri         "https://graph.microsoft.com/beta/users/" `
                    -Method      POST `
                    -Headers     $bpAuthHeader `
                    -Body        $auBody `
                    -ContentType "application/json"
                break
            } catch {
                $errMsg = $_.ErrorDetails.Message
                Write-Note "  Agent User attempt $r/10: $($_.Exception.Message) | $errMsg"
                # Catch any conflict variant: UPN taken, mailNickname taken, displayName taken, etc.
                if ($errMsg -match 'ObjectConflict|conflicting object|already exists|UPN|userPrincipalName|Request_BadRequest') {
                    $rand5         = (Get-Random -Minimum 10000 -Maximum 99999).ToString()
                    $AgentUserUpn  = "$AgentUserPrefix$rand5@$tenantDomainFqdn"
                    $mailNickname  = "$AgentUserPrefix$rand5"
                    $auDisplayName = "n8n Agent User ($AgentUserPrefix-$rand5)"
                    Write-Note "  Conflict detected — retrying with new UPN '$AgentUserUpn' (attempt $r/10)"
                    $auBody = & $BuildAuBody
                }
            }
        }
    }
    if (-not $auResp) { throw "Failed to create Agent User after 10 attempts." }
    Write-OK "Agent User created: $($auResp.userPrincipalName)"
    # Admin delegated connection is still active — no reconnect needed since
    # we never called Connect-AgentIdentityBlueprint.
}
    # Resolve Blueprint App ID if not already known (set in Phase 3b creation path;
    # may be empty on resume runs that skip Phase 3).
    if (-not $BlueprintAppId) {
        try {
            # Query via the agentIdentityBlueprint principals endpoint.
            $bpSpList = (Invoke-MgGraphRequest -Method GET `
                -Uri "beta/agentIdentityBlueprints/$blueprintId/principals?`$select=appId,id" `
                -ErrorAction Stop).value
            if ($bpSpList.Count -gt 0) {
                $BlueprintAppId = $bpSpList[0].appId
                Write-OK "Blueprint AppId resolved: $BlueprintAppId"
            }
        } catch {
            Write-Note "Could not auto-resolve Blueprint AppId: $($_.Exception.Message)"
            Write-Note "Supply -BlueprintAppId on re-runs or set ENTRA_BLUEPRINT_APP_ID in azd env."
        }
    } else {
        Write-OK "Blueprint AppId (supplied via param): $BlueprintAppId"
    }
# ─── Phase 4: Add Blueprint client secret ─────────────────────────────────────
Write-Step "[4/6]" "Adding client secret to Blueprint..."

$blueprintId     = $BlueprintId
$agentIdentityId = $AgentIdentityId
$agentUserUpn    = $AgentUserUpn

if ($BlueprintSecret) {
    $blueprintSecretPlain = $BlueprintSecret
    Write-OK "Blueprint secret supplied via -BlueprintSecret parameter"
} elseif ($blueprintSecretPlain) {
    # Already captured in Phase 3 (normal creation path) — nothing to do.
    Write-OK "Blueprint secret already captured in Phase 3"
} else {
    # Resume path: IDs supplied via -BlueprintId/-AgentIdentityId/-AgentUserUpn params.
    # Need to add a fresh secret to the existing Blueprint.
    $secretResp = Add-EntraBetaClientSecretToAgentIdentityBlueprint -AgentBlueprintId $blueprintId -ErrorAction Stop
    $blueprintSecretPlain = $secretResp.SecretText
    if (-not $blueprintSecretPlain) {
        Write-Note "Could not capture secret automatically. Please paste it now."
        $blueprintSecretPlain = [System.Net.NetworkCredential]::new('', (Read-Host "  Paste the secretText" -AsSecureString)).Password
    }
    Write-OK "Blueprint secret captured"
}
Write-OK "Blueprint secret recorded in memory (never written to disk)"

# ─── Phase 4b: Grant Microsoft Graph application permissions to Agent Identity ─
# Uses Invoke-MgGraphRequest (same MS Graph PowerShell session from Phase 2) so
# the AppRoleAssignment.ReadWrite.All scope is guaranteed — unlike az rest which
# uses a separate Azure CLI token that may not have the right scopes.
Write-Step "[4b/6]" "Granting Microsoft Graph application permissions to Agent Identity SP..."

$graphSPId = $null
try {
    $graphSPId = (Invoke-MgGraphRequest -Method GET `
        -Uri "v1.0/servicePrincipals?`$filter=appId eq '00000003-0000-0000-c000-000000000000'&`$select=id" `
        -ErrorAction Stop).value[0].id
} catch { }

if (-not $graphSPId) {
    Write-Note "Could not resolve MS Graph SP — skipping Graph app role grants. Grant manually in Entra portal."
} else {
    Write-OK "Microsoft Graph SP: $graphSPId"

    # Application permission app role IDs on Microsoft Graph (confirmed working with agentIdentity SP type).
    # NOTE: Device.Read.All, Organization.Read.All and Domain.Read.All are excluded here because their
    #       application-permission role IDs consistently fail with "Permission not found on application"
    #       for the agentIdentity servicePrincipalType — likely a Graph API limitation for this object type.
    $graphAppRoles = [ordered]@{
        "User.Read.All"           = "df021288-bdef-4463-88db-98f22de89214"
        "Group.Read.All"          = "5b567255-7703-4780-807c-7be8301ae99b"
        "GroupMember.Read.All"    = "98830695-27a2-44f7-8c18-0c3ebc9698f6"
        "Directory.Read.All"      = "7ab1d382-f21e-4acd-a863-ba3e13f7da61"
        "Application.Read.All"    = "9a5d68dd-52b0-4cc2-bd40-abcf44ac3a30"
        "AuditLog.Read.All"       = "b0afded3-3588-46d8-8b3d-9842eff778da"
        "Reports.Read.All"        = "230c1aed-a721-4c5d-9cb4-a90514e508ef"
        "Policy.Read.All"         = "246dd0d5-5bd0-4def-940b-0421030a5b68"
        "RoleManagement.Read.All" = "c7fbd983-d9aa-4fa7-84b8-17382c103bc4"
    }

    # Fetch existing assignments to enable idempotent re-runs
    $existingRoleIds = @()
    try {
        $existingRoleIds = @((Invoke-MgGraphRequest -Method GET `
            -Uri "v1.0/servicePrincipals/$agentIdentityId/appRoleAssignments" `
            -ErrorAction Stop).value | ForEach-Object { $_.appRoleId })
    } catch {
        Write-Note "  Could not fetch existing assignments (will attempt all grants): $($_.Exception.Message)"
    }

    $grantErrors = @()
    foreach ($role in $graphAppRoles.GetEnumerator()) {
        if ($existingRoleIds -contains $role.Value) {
            Write-Note "  [skip] $($role.Key) already assigned"
            continue
        }
        try {
            Invoke-MgGraphRequest -Method POST `
                -Uri         "v1.0/servicePrincipals/$agentIdentityId/appRoleAssignments" `
                -Body        (@{ principalId = $agentIdentityId; resourceId = $graphSPId; appRoleId = $role.Value } | ConvertTo-Json) `
                -ContentType "application/json" `
                -ErrorAction Stop | Out-Null
            Write-OK "  $($role.Key)"
        } catch {
            $errDetail = $_.ErrorDetails.Message ?? $_.Exception.Message
            Write-Note "  [warn] $($role.Key) failed: $errDetail"
            $grantErrors += $role.Key
        }
    }

    if ($grantErrors.Count -gt 0) {
        Write-Note "  The following permissions could not be assigned automatically: $($grantErrors -join ', ')"
        Write-Note "  Grant them manually: Entra portal → App registrations → n8n-agent-identity → API permissions → Add a permission → Microsoft Graph → Application permissions"
    }
}

# ─── Phase 5: Enable Graph MCP Server for Enterprise ──────────────────────────
if (-not $SkipMcpServer) {
    Write-Step "[5/6]" "Enabling Microsoft Graph MCP Server for Enterprise in your tenant..."

    # Grant-EntraBetaMCPServerPermission creates the MCP Server SP in the tenant
    # and grants the named application delegated consent to it.
    # VS Code is used as the seed; the Blueprint gets its own grant in Phase 6.
    try {
        Grant-EntraBetaMCPServerPermission -ApplicationName VisualStudioCode | Out-Null
        Write-OK "MCP Server registered and VS Code granted delegated access"
    } catch {
        Write-Note "Grant-EntraBetaMCPServerPermission returned: $($_.Exception.Message)"
        Write-Note "Continuing — the MCP Server SP may already exist in your tenant."
    }

    # ─── Phase 6: Grant Agent Identity SP access to the MCP Server ────────────
    Write-Step "[6/6]" "Granting Agent Identity SP delegated access to the MCP Server..."

    $mcpSP = Get-EntraBetaServicePrincipal -Filter "appId eq '$MCP_SERVER_APP_ID'" -ErrorAction SilentlyContinue

    if (-not $mcpSP) {
        Write-Err "MCP Server SP (appId=$MCP_SERVER_APP_ID) not found in tenant."
        Write-Note "You may need to visit https://aka.ms/mcpserver-enterprise to enable it first."
        Write-Note "Then re-run this script with -SkipMcpServer to only redo the permission grant."
    } else {
        Write-OK "Found MCP Server SP: $($mcpSP.Id)"

        # Resolve the Agent Identity service principal
        $agentSP = Get-EntraBetaServicePrincipal -ObjectId $agentIdentityId -ErrorAction SilentlyContinue

        if (-not $agentSP) {
            Write-Err "Could not resolve Agent Identity SP object '$agentIdentityId'."
            Write-Note "Grant MCP scopes manually via Entra admin portal or re-run with the correct ID."
        } else {
            Write-OK "Found Agent Identity SP: $($agentSP.DisplayName) ($($agentSP.Id))"

            $scopeString = $MCP_SCOPES -join ' '

            # Check for an existing OAuth2PermissionGrant
            $existingGrant = Get-EntraOAuth2PermissionGrant -All |
                             Where-Object { $_.ClientId -eq $agentSP.Id -and $_.ResourceId -eq $mcpSP.Id } |
                             Select-Object -First 1

            if ($existingGrant) {
                # Merge and deduplicate scopes
                $merged = (($existingGrant.Scope -split '\s+') + $MCP_SCOPES |
                           Sort-Object -Unique) -join ' '
                # Use Graph API directly — Set-EntraOAuth2PermissionGrant is not available
                $tmpFile = [System.IO.Path]::GetTempFileName()
                (@{ scope = $merged } | ConvertTo-Json -Compress) | Out-File -FilePath $tmpFile -Encoding utf8 -NoNewline
                az rest --method PATCH `
                    --uri "https://graph.microsoft.com/v1.0/oauth2PermissionGrants/$($existingGrant.Id)" `
                    --headers "Content-Type=application/json" `
                    --body "@$tmpFile" | Out-Null
                Remove-Item $tmpFile
                Write-OK "Updated existing MCP permission grant with merged scopes"
            } else {
                New-EntraOAuth2PermissionGrant `
                    -ClientId    $agentSP.Id `
                    -ResourceId  $mcpSP.Id `
                    -Scope       $scopeString `
                    -ConsentType 'AllPrincipals' | Out-Null
                Write-OK "Created MCP permission grant on Agent Identity SP"
            }

            Write-Note "Scopes granted: $scopeString"
        }
    }
} else {
    Write-Step "[5-6/6]" "Skipping MCP Server setup (--SkipMcpServer flag set)."
    Write-Note "Re-run without -SkipMcpServer to enable it later."
}

# ─── Final Output: n8n credential table ───────────────────────────────────────
$tokenEndpoint       = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token"
$scopeAutonomous     = "https://graph.microsoft.com/.default"
$scopeDelegatedAgent = "https://mcp.svc.cloud.microsoft/.default"

$separator = "=" * 70

Write-Host ""
Write-Host $separator -ForegroundColor Magenta
Write-Host "  n8n  EntraAgentID CREDENTIAL CONFIGURATION" -ForegroundColor Magenta
Write-Host $separator -ForegroundColor Magenta
Write-Host ""
Write-Host "  In n8n:  Settings → Credentials → New Credential" -ForegroundColor White
Write-Host "  Type:    Microsoft Entra Agent ID (Blueprint) Credentials API" -ForegroundColor White
Write-Host ""
Write-Host "  ── Credential: AUTONOMOUS AGENT (calls Graph directly) ─────────"
Write-Host "  Entra ID Token Endpoint : $tokenEndpoint"
Write-Host "  Blueprint ID            : $blueprintId"
Write-Host "  Blueprint Secret        : $blueprintSecretPlain"
Write-Host "  Agent ID                : $agentIdentityId"
Write-Host "  On Behalf Of            : (leave empty)"
Write-Host "  Scope                   : $scopeAutonomous"
Write-Host ""
Write-Host "  ── Credential: AGENT USER / OBO (calls Graph MCP Server) ───────"
Write-Host "  Entra ID Token Endpoint : $tokenEndpoint"
Write-Host "  Blueprint ID            : $blueprintId"
Write-Host "  Blueprint Secret        : $blueprintSecretPlain"
Write-Host "  Agent ID                : $agentIdentityId"
Write-Host "  On Behalf Of            : $agentUserUpn"
Write-Host "  Scope                   : $scopeDelegatedAgent"
Write-Host ""
Write-Host $separator -ForegroundColor Magenta
Write-Host ""
Write-Host "  NEXT STEPS (if running manually):" -ForegroundColor Cyan
  Write-Host "  1. Copy the values above and run Configure-N8n.ps1 with -Entra* params"
  Write-Host "  2. Or use Run-All.ps1 to do everything in one shot"
  Write-Host ""
  Write-Host $separator -ForegroundColor Magenta
  Write-Host ""

# ─── Phase 7: Create / update SPA App Registration ───────────────────────────
$spaClientId = $null

if (-not $BlueprintAppId) {
    Write-Step "[7/Phase-7]" "Skipping SPA app registration — BlueprintAppId not available."
    Write-Note "Re-run with -BlueprintAppId to create the SPA app registration."
} else {
    Write-Step "[Phase 7]" "Creating/updating SPA app registration '$SpaAppName'..."

    # ─ 7a: Ensure Blueprint app exposes 'access_as_user' scope ────────────────
    Write-Note "Ensuring Blueprint app exposes 'access_as_user' scope..."
    $scopeId = [System.Guid]::NewGuid().ToString()
    $accessAsUserScope = @{
        id                      = $scopeId
        value                   = 'access_as_user'
        adminConsentDisplayName = 'Access as user'
        adminConsentDescription = 'Allows the SPA to call the n8n webhook on behalf of the signed-in user.'
        userConsentDisplayName  = 'Access n8n as you'
        userConsentDescription  = 'Allows the app to access n8n on your behalf.'
        isEnabled               = $true
        type                    = 'User'
    }
    try {
        $bpAppResp = (Invoke-MgGraphRequest -Method GET `
            -Uri "v1.0/applications?`$filter=appId eq '$BlueprintAppId'&`$select=id,identifierUris,api" `
            -ErrorAction Stop).value
        if ($bpAppResp.Count -gt 0) {
            $bpObjId        = $bpAppResp[0].id
            $existingScopes = @($bpAppResp[0].api.oauth2PermissionScopes)
            $alreadyHasScope = $existingScopes | Where-Object { $_.value -eq 'access_as_user' }

            $identifierUris = @($bpAppResp[0].identifierUris)
            $expectedUri = "api://$BlueprintAppId"
            $needsUri = $identifierUris -notcontains $expectedUri

            if (-not $alreadyHasScope -or $needsUri) {
                $patchBody = @{ api = @{ oauth2PermissionScopes = @($existingScopes + @($accessAsUserScope)) } }
                if ($needsUri) { $patchBody['identifierUris'] = @($identifierUris + $expectedUri) }
                Invoke-MgGraphRequest -Method PATCH `
                    -Uri         "v1.0/applications/$bpObjId" `
                    -Body        ($patchBody | ConvertTo-Json -Depth 10) `
                    -ContentType 'application/json' -ErrorAction Stop | Out-Null
                Write-OK "Blueprint app updated with 'access_as_user' scope and identifier URI"
            } else {
                Write-Note "Blueprint app already has 'access_as_user' scope—no changes needed."
                # Reuse the existing scope ID for pre-authorization below
                $scopeId = ($existingScopes | Where-Object { $_.value -eq 'access_as_user' }).id
            }
        } else {
            Write-Note "Blueprint app not found in regular app registrations (Blueprint-type object). Skipping scope write."
            Write-Note "You may need to configure the 'access_as_user' scope manually in the Entra portal."
        }
    } catch {
        Write-Note "  Could not update Blueprint app scope: $($_.Exception.Message)"
    }

    # ─ 7b: Find or create the SPA app registration ──────────────────────────
    Write-Note "Looking up SPA app registration '$SpaAppName'..."
    $spaObjId = $null
    try {
        $existing = (Invoke-MgGraphRequest -Method GET `
            -Uri "v1.0/applications?`$filter=displayName eq '$SpaAppName'&`$select=id,appId,spa,requiredResourceAccess" `
            -ErrorAction Stop).value | Select-Object -First 1
        if ($existing) {
            $spaObjId    = $existing.id
            $spaClientId = $existing.appId
            Write-Note "Found existing SPA app: $spaClientId (objectId: $spaObjId)"
        }
    } catch { }

    if (-not $spaObjId) {
        Write-Note "Creating new SPA app registration..."
        $createBody = @{
            displayName            = $SpaAppName
            signInAudience         = 'AzureADMyOrg'
            spa                    = @{ redirectUris = @() }
            requiredResourceAccess = @()
        }
        $newApp      = Invoke-MgGraphRequest -Method POST `
            -Uri         'v1.0/applications' `
            -Body        ($createBody | ConvertTo-Json -Depth 5) `
            -ContentType 'application/json' -ErrorAction Stop
        $spaObjId    = $newApp.id
        $spaClientId = $newApp.appId
        Write-OK "Created SPA app: $spaClientId (objectId: $spaObjId)"
    }

    # ─ 7c: Configure redirect URIs ──────────────────────────────────────
    $redirectUris = @(
        'http://localhost:5500/redirect.html'
        'http://127.0.0.1:5500/redirect.html'
        'http://localhost:3000/redirect.html'
        'http://localhost:8080/redirect.html'
    )
    if ($SpaFqdn) {
        $redirectUris += "https://$SpaFqdn/redirect.html"
    }
    # Merge with existing URIs from the app registration
    try {
        $spaApp = (Invoke-MgGraphRequest -Method GET `
            -Uri "v1.0/applications/${spaObjId}?`$select=spa" -ErrorAction Stop)
        $existingUris = @($spaApp.spa.redirectUris)
        $redirectUris = ($existingUris + $redirectUris | Sort-Object -Unique)
    } catch { }

    Invoke-MgGraphRequest -Method PATCH `
        -Uri         "v1.0/applications/$spaObjId" `
        -Body        (@{ spa = @{ redirectUris = $redirectUris } } | ConvertTo-Json -Depth 5) `
        -ContentType 'application/json' -ErrorAction Stop | Out-Null
    Write-OK "SPA redirect URIs configured: $($redirectUris -join ', ')"

    # ─ 7d: Add API permission for access_as_user on the Blueprint ────────────
    if ($scopeId) {
        Write-Note "Adding API permission for api://$BlueprintAppId/access_as_user..."
        try {
            $spaAppFull   = (Invoke-MgGraphRequest -Method GET `
                -Uri "v1.0/applications/${spaObjId}?`$select=requiredResourceAccess" -ErrorAction Stop)
            $existing     = @($spaAppFull.requiredResourceAccess)
            $alreadyGranted = $existing | Where-Object { $_.resourceAppId -eq $BlueprintAppId }

            if (-not $alreadyGranted) {
                $newPermission = @{
                    resourceAppId  = $BlueprintAppId
                    resourceAccess = @(@{ id = $scopeId; type = 'Scope' })
                }
                Invoke-MgGraphRequest -Method PATCH `
                    -Uri         "v1.0/applications/$spaObjId" `
                    -Body        (@{ requiredResourceAccess = @($existing + $newPermission) } | ConvertTo-Json -Depth 10) `
                    -ContentType 'application/json' -ErrorAction Stop | Out-Null
                Write-OK "API permission added"
            } else {
                Write-Note "API permission for Blueprint already present"
            }

            # Admin consent via OAuth2PermissionGrant (AllPrincipals = tenant-wide consent)
            $spaSP = (Invoke-MgGraphRequest -Method GET `
                -Uri "v1.0/servicePrincipals?`$filter=appId eq '$spaClientId'&`$select=id" `
                -ErrorAction SilentlyContinue).value
            if (-not $spaSP -or $spaSP.Count -eq 0) {
                # SPA SP does not exist yet — create it
                $spaSP = @(Invoke-MgGraphRequest -Method POST -Uri 'v1.0/servicePrincipals' `
                    -Body (@{ appId = $spaClientId } | ConvertTo-Json) `
                    -ContentType 'application/json' -ErrorAction SilentlyContinue)
            }
            $spaSPId = if ($spaSP -is [array]) { $spaSP[0].id } else { $spaSP.id }
            $bpSPId  = (Invoke-MgGraphRequest -Method GET `
                -Uri "v1.0/servicePrincipals?`$filter=appId eq '$BlueprintAppId'&`$select=id" `
                -ErrorAction Stop).value[0].id

            $existingGrant = (Invoke-MgGraphRequest -Method GET `
                -Uri "v1.0/oauth2PermissionGrants?`$filter=clientId eq '$spaSPId' and resourceId eq '$bpSPId'" `
                -ErrorAction SilentlyContinue).value | Select-Object -First 1
            if ($existingGrant) {
                Write-Note "Consent grant already exists"
            } else {
                Invoke-MgGraphRequest -Method POST -Uri 'v1.0/oauth2PermissionGrants' `
                    -Body (@{ clientId = $spaSPId; consentType = 'AllPrincipals'; resourceId = $bpSPId; scope = 'access_as_user' } | ConvertTo-Json) `
                    -ContentType 'application/json' -ErrorAction SilentlyContinue | Out-Null
                Write-OK "Admin consent granted for access_as_user"
            }
        } catch {
            Write-Note "  Could not configure API permission: $($_.Exception.Message)"
            Write-Note "  Grant manually: Entra portal → App registrations → $SpaAppName → API permissions"
        }
    }

    Write-Host ""
    Write-Host ($separator) -ForegroundColor Magenta
    Write-Host "  SPA APP REGISTRATION" -ForegroundColor Magenta
    Write-Host ($separator) -ForegroundColor Magenta
    Write-Host "  Display Name   : $SpaAppName"
    Write-Host "  Client ID      : $spaClientId"
    Write-Host "  API Scope      : api://$BlueprintAppId/access_as_user"
    if ($SpaFqdn) {
        Write-Host "  Deployed at    : https://$SpaFqdn"
    }
    Write-Host ($separator) -ForegroundColor Magenta
    Write-Host ""
}

# Return structured output so callers (e.g. Run-All.ps1) can capture all values
return @{
    TenantId        = $TenantId
    BlueprintId     = $blueprintId
    BlueprintAppId  = $BlueprintAppId
    AgentIdentityId = $agentIdentityId
    AgentUserUpn    = $agentUserUpn
    BlueprintSecret = $blueprintSecretPlain
    TokenEndpoint   = $tokenEndpoint
    SpaClientId     = $spaClientId
}
