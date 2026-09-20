<#
.SYNOPSIS
    Prepares a Microsoft 365 / Azure tenant for EasySOC (AgenticSOC) and writes a
    ready-to-deploy config file for deploy-aci.ps1.

.DESCRIPTION
    Single, unified tenant-preparation script (replaces the former Prepare-Tenant.ps1
    + Prepare-Tenant-POC.ps1 pair). It:

      1. Verifies Azure CLI auth and selects the subscription (auto-detected; prompts
         only when more than one exists).
      2. Creates an Entra ID app registration + service principal with the Microsoft
         Graph application permissions the agent needs, grants admin consent, and creates
         a client secret. The exact permission set depends on -CaseBackend/-TeamsMode
         (see those parameters) -- least-privilege: a tenant with no Defender XDR/M365
         has nothing behind SecurityAlert.*/SecurityIncident.*/ThreatHunting.Read.All, and
         a cross-tenant Teams deployment (webhook-only; see -TeamsMode) has nothing behind
         ChannelMessage.Read.All either -- it's requested only when it's actually usable,
         not unconditionally. (Report delivery needs no Graph permission at all, in either
         Teams mode -- see -TeamsMode's doc comment.)
      3. Provisions an Azure Storage account + Azure Files share for the audit volume.
      4. Discovers the Sentinel / Log Analytics workspace, assigns the Microsoft
         Sentinel Reader role, provisions the audit Data Collection Endpoint/Rule
         and EasySOC_Audit_CL table (so internal-audit read/write actually works
         instead of silently no-opping -- see agent/internal/casebackend/
         auditcommon.go), and retrieves the workspace's shared key so
         deploy-aci.ps1 can enable ACI container-log integration on that same
         workspace (prompts only when more than one workspace exists).
      5. Discovers an Azure AI Foundry inference endpoint (prompts to pick / confirm).
      6. Prompts for the values that cannot be auto-retrieved (Teams Workflows webhook +
         IDs, optional enrichment API keys).
      7. Writes everything to a config file (default: easysoc-deploy.config.ps1) that
         deploy-aci.ps1 dot-sources, so the partner's deploy step needs no manual edits.

    The script auto-retrieves every value it can after `az login`. Anything ambiguous
    (multiple subscriptions/workspaces/Foundry resources) is listed for you to choose;
    anything not retrievable (Teams webhook, enrichment keys) is prompted interactively.

    Required caller permissions (in the target tenant):
        - Application Administrator   (create app registration, grant admin consent)
        - Contributor on the subscription / resource group (storage, role assignment)
    Global Administrator + Contributor covers both.

.PARAMETER CustomerId
    Snake_case identifier used in agent config. Example: "contoso".
    App registration is named "AgenticSOC-CUSTOMERID".

.PARAMETER SubscriptionId
    Azure subscription ID. Optional - auto-detected; you are prompted only if the
    signed-in account has more than one enabled subscription.

.PARAMETER ResourceGroup
    Resource group for the storage account (and the workspace lookup scope). Optional -
    prompted (with a list of existing groups) if not supplied.

.PARAMETER Location
    Azure region for the storage account. Optional - defaults to the resource group's
    region, or prompted if the group is new.

.PARAMETER StorageAccountName
    Optional. 3-24 lowercase letters/digits. Defaults to "easysoc<customerid>".

.PARAMETER FileShareName
    Azure Files share name for the audit volume. Default: "audit".

.PARAMETER SecretExpiryYears
    Client secret validity in years (default 1, max 2).

.PARAMETER SentinelWorkspaceId
    Log Analytics workspace customerId (GUID). Optional - auto-discovered; you are
    prompted only if more than one workspace exists. Pass "none" to skip Sentinel.
    This same workspace's shared key is also retrieved automatically and written to
    the config so deploy-aci.ps1 can enable ACI container-log integration (Azure
    Portal's Log Analytics blade doesn't support the agent's container config -
    secure env vars + a volume mount - so this must be set at deploy time via CLI).

.PARAMETER CaseBackend
    Which CaseBackend the agent will use: "xdr" (default -- Defender XDR incident via
    Graph Security API), "sentinel" (Microsoft Sentinel incident via KQL read + ARM REST
    write -- for a tenant with Sentinel but no Defender XDR/M365 license, where
    /security/incidents is permanently empty), or "sharepoint" (SharePoint List case
    tracking, still backed by the underlying Defender XDR incident).
    Controls which Graph Security API permissions get requested: "sentinel" excludes
    SecurityAlert.*/SecurityIncident.*/ThreatHunting.Read.All entirely (nothing in the
    tenant to grant them against); "xdr"/"sharepoint" both need them. Also determines the
    $SocCaseBackend value written to the generated config -- Sentinel-specific fields
    (resource_group/workspace_name/service_principal_object_id) are always populated
    when a Sentinel workspace is discovered, regardless of this parameter, so switching
    an already-prepared tenant to case_backend: sentinel later needs no re-run.

.PARAMETER TenantSku
    Which Microsoft licensing/telemetry mix this tenant actually has, for SIEM query
    routing (agent/internal/siem/router.go): "business_premium" (default -- endpoint +
    identity telemetry via Defender XDR Advanced Hunting, no Sentinel-only query types
    available), "mde_sentinel" (Defender XDR for endpoint, Sentinel for identity
    sign-in types), or "sentinel_only" (everything routed to Sentinel -- for a tenant
    with Sentinel but no Defender XDR/M365 unified telemetry, i.e. normally paired with
    -CaseBackend sentinel). If omitted, defaults to "sentinel_only" when
    -CaseBackend is "sentinel" (nothing else it could sensibly be) and
    "business_premium" otherwise -- override explicitly for a "mde_sentinel" tenant,
    since that can't be inferred from -CaseBackend alone.

.PARAMETER TeamsMode
    How Teams output is configured: "full" (default -- posting + reply-polling, plus
    report delivery), "webhook_only" (posting + report delivery, no reply-polling --
    works cross-tenant with zero extra Graph permissions, since poster.go's webhook
    POST is unauthenticated; use this when the only Teams access available is in a
    different Entra tenant than this app registration, where reply-polling would
    silently never work -- see Implementation/Cross-Tenant Teams Posting Failure --
    Diagnosis v2 in the project vault), or "none" (no Teams at all). Only "full"
    requests ChannelMessage.Read.All (reply polling), which requires the Team to live
    in this same tenant to ever work, so "webhook_only"/"none" skip requesting it and
    skip prompting for TeamsTeamId/TeamsChannelId (left blank -- they're only used for
    reply-polling, never for report delivery).

    Report delivery (the investigation report HTML) needs no Graph permission at all,
    in either "full" or "webhook_only" mode: it rides as an extra field in the same
    webhook POST as the notification card, and the customer's own Power Automate flow
    (already authorized in its own tenant, since a member of that tenant built it)
    writes it to SharePoint and posts the link back as a follow-up message. This is
    why it works regardless of which tenant the Team lives in -- see the Diagnosis v2
    doc referenced above for the full history of why this replaced a Graph-based
    upload that could never work cross-tenant.

.PARAMETER LlmBackend
    LLM backend to configure: "anthropic" (default) or "azure_openai".
    Determines how the discovered Foundry resource endpoint is written to the config.

.PARAMETER AnthropicBaseUrl
    Azure AI Foundry Anthropic endpoint (e.g. https://<res>.services.ai.azure.com/anthropic).
    Optional - auto-discovered from Foundry resources or prompted. Blank => public Anthropic API.
    Only used when LlmBackend=anthropic.

.PARAMETER AnthropicApiKey
    Foundry resource key (or EasySOC-provided Anthropic key for the POC fallback).
    Optional - fetched from the chosen Foundry resource or prompted.
    Only used when LlmBackend=anthropic.

.PARAMETER AzureOpenAiEndpoint
    Azure AI Foundry / Azure OpenAI resource endpoint (e.g. https://<res>.cognitiveservices.azure.com).
    Optional - auto-discovered or prompted. Only used when LlmBackend=azure_openai.

.PARAMETER AzureOpenAiApiKey
    Azure AI Foundry / OpenAI resource key. Optional - fetched automatically or prompted.
    Only used when LlmBackend=azure_openai.

.PARAMETER AzureOpenAiDeployment
    Model deployment name in Azure AI Foundry (e.g. "gpt-5.4"). Prompted if omitted.
    Only used when LlmBackend=azure_openai.

.PARAMETER TeamsWebhookUrl
    Teams Workflows webhook URL. Not auto-retrievable - prompted if omitted.

.PARAMETER TeamsTeamId
    Teams group/team ID (GUID from the channel URL). Prompted if omitted.

.PARAMETER TeamsChannelId
    Teams channel ID (decoded 19:...@thread.tacv2). Prompted if omitted.

.PARAMETER VirusTotalApiKey
.PARAMETER AbuseIpDbApiKey
.PARAMETER IpInfoToken
    Optional threat-intel enrichment keys. Prompted (blank to disable) if omitted.

.PARAMETER BootstrapUrl
.PARAMETER BootstrapToken
.PARAMETER BootstrapTlsVerify
    Optional - overrides the control server deploy-aci.ps1 would otherwise use (its
    PROVIDER section default, normally the production endpoint). Point BootstrapUrl
    at a soc-server instance from deploy-server-aci.ps1 to test agent-server
    communication against something other than production. Prompted like the other
    optional values (blank = use deploy-aci.ps1's PROVIDER section default); left
    blank, these are omitted from the config file entirely so that default applies
    unchanged.

.PARAMETER AcrPullPassword
    Optional - the ACR pull-token password deploy-aci.ps1 needs to pull the soc-agent
    image. Constant across customers (EasySOC-issued), not a per-tenant secret, but
    written into THIS tenant's easysoc-deploy.config.ps1 when supplied so deploy-aci.ps1
    never needs its own PROVIDER section edited -- that script is synced verbatim to the
    public partner onboarding repo, so it must never hold a real secret. Prompted like
    the other optional values (blank = deploy-aci.ps1 prompts for it interactively at
    deploy time instead, unless run with -NonInteractive there too).

.PARAMETER ConfigOutPath
    Where to write the deploy config. Default: .\easysoc-deploy.config.ps1.

.PARAMETER NonInteractive
    Never prompt. Use only the values passed as parameters / auto-detected when
    unambiguous; fail if a required value is missing or ambiguous. For pipelines.

.PARAMETER DryRun
    Resolve permission IDs and run discovery (read-only), print the plan, and write a
    PREVIEW config file. No tenant/Azure changes are made; values that only exist after
    real creation (appId, objectId, client secret) are written as DRY-RUN placeholders.

.EXAMPLE
    # Fully interactive - discovers everything, prompts for the rest:
    .\Prepare-Tenant.ps1 -CustomerId "contoso"

.EXAMPLE
    # Scripted - every ambiguous value pinned, no prompts:
    .\Prepare-Tenant.ps1 -CustomerId "contoso" `
        -SubscriptionId "xxxx..." -ResourceGroup "rg-easysoc" -Location "eastus" `
        -SentinelWorkspaceId "xxxx..." -TeamsWebhookUrl "https://..." `
        -TeamsTeamId "xxxx..." -TeamsChannelId "19:...@thread.tacv2" -NonInteractive

.EXAMPLE
    # Sentinel-only tenant (no Defender XDR/M365), Teams only reachable in a
    # different Entra tenant -- excludes the Security API + Teams-polling/upload
    # Graph permissions entirely, and leaves team_id/channel_id blank:
    .\Prepare-Tenant.ps1 -CustomerId "contoso" -CaseBackend "sentinel" -TeamsMode "webhook_only"
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern("^[a-z0-9_-]+$")]
    [string]$CustomerId,

    [ValidatePattern("^[0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12}$")]
    [string]$SubscriptionId = "",

    [string]$ResourceGroup = "",
    [string]$Location = "",

    [ValidatePattern("^[a-z0-9]{3,24}$")]
    [string]$StorageAccountName = "",

    [string]$FileShareName = "audit",

    [ValidateRange(1, 2)]
    [int]$SecretExpiryYears = 1,

    [string]$SentinelWorkspaceId  = "",

    [ValidateSet("xdr", "sentinel", "sharepoint")]
    [string]$CaseBackend = "xdr",

    [ValidateSet("", "business_premium", "mde_sentinel", "sentinel_only")]
    [string]$TenantSku = "",

    [ValidateSet("full", "webhook_only", "none")]
    [string]$TeamsMode = "full",

    [string]$LlmBackend           = "",      # "anthropic" (default) | "azure_openai"
    [string]$AnthropicBaseUrl     = "",
    [string]$AnthropicApiKey      = "",
    [string]$AzureOpenAiEndpoint  = "",
    [string]$AzureOpenAiApiKey    = "",
    [string]$AzureOpenAiDeployment = "",
    [string]$TeamsWebhookUrl      = "",
    [string]$TeamsTeamId         = "",
    [string]$TeamsChannelId      = "",
    [string]$VirusTotalApiKey    = "",
    [string]$AbuseIpDbApiKey     = "",
    [string]$IpInfoToken         = "",

    # Optional - overrides deploy-aci.ps1's PROVIDER-section control server default.
    # Prompted like other optional values; see .PARAMETER BootstrapUrl above.
    [string]$BootstrapUrl        = "",
    [string]$BootstrapToken      = "",
    [string]$BootstrapTlsVerify  = "",

    # Optional - see .PARAMETER AcrPullPassword above. Never written anywhere but this
    # tenant's own gitignored config file.
    [string]$AcrPullPassword     = "",

    [string]$ConfigOutPath = ".\easysoc-deploy.config.ps1",

    [switch]$NonInteractive,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$AppName    = "AgenticSOC-$CustomerId"
$GraphAppId = "00000003-0000-0000-c000-000000000000"

# Default TenantSku from CaseBackend when not explicitly set -- "sentinel_only" is the
# only sensible SIEM routing for a -CaseBackend sentinel tenant (no Defender XDR/M365
# telemetry exists there at all); everything else defaults to "business_premium".
# "mde_sentinel" must always be passed explicitly -- it can't be inferred from
# -CaseBackend alone. See .PARAMETER TenantSku.
if (-not $TenantSku) {
    $TenantSku = if ($CaseBackend -eq "sentinel") { "sentinel_only" } else { "business_premium" }
}

# Microsoft Graph application permissions (all type Application; no user delegation).
# Built conditionally on -CaseBackend/-TeamsMode rather than one fixed list -- a tenant
# with no Defender XDR/M365 has nothing behind the Security API scopes, and a
# cross-tenant Teams deployment (-TeamsMode webhook_only, see that parameter's doc
# comment) has nothing behind the Teams-polling scope; requesting permissions an
# admin-consent screen shows but the deployment can never use is a real trust cost for
# exactly the privacy-conscious customer profile the sentinel/webhook_only path
# targets, not just clutter.
# NOTE: SharePoint/Graph Sites.ReadWrite.All is intentionally NOT requested at all
# (neither the legacy SharePoint Online resource 00000003-0000-0ff1-ce00-..., a leftover
# from the retired SP-Lists native-comments REST path, nor the Graph one previously
# requested here for report uploads against the Team's Shared Documents drive). Report
# delivery no longer calls Graph -- it rides in the same webhook POST as the
# notification card, and the customer's own Power Automate flow (already authorized in
# its own tenant) does the SharePoint write. See -TeamsMode's doc comment and
# Implementation/Cross-Tenant Teams Posting Failure -- Diagnosis v2 in the project vault.
$RequiredGraphPermissions = [System.Collections.Generic.List[string]]::new()
$RequiredGraphPermissions.AddRange([string[]]@(
    "IdentityRiskEvent.Read.All",    # Entra risky sign-in events
    "AuditLog.Read.All",             # sign-in logs for identity analysis
    "User.Read.All",                 # user profile details for context resolver
    "Directory.Read.All",            # group membership, role assignments, CA policies
    "GroupMember.Read.All"           # group membership resolution
))
if ($CaseBackend -ne "sentinel") {
    # xdr and sharepoint both read/write the underlying Defender XDR incident via
    # Graph's Security API (sharepointbackend.go resolves/writes /security/incidents/{id}
    # too, not just xdrbackend.go) and both can use Advanced Hunting for SIEM telemetry --
    # sentinel needs none of this, it never calls graph.microsoft.com/.../security/*.
    $RequiredGraphPermissions.AddRange([string[]]@(
        "SecurityAlert.Read.All",        # Defender XDR + M365 security alerts (read)
        "SecurityAlert.ReadWrite.All",   # write alert status/comments
        "SecurityIncident.Read.All",     # read XDR incidents
        "SecurityIncident.ReadWrite.All",# write comments/tags/classification to XDR incidents
        "ThreatHunting.Read.All"         # Advanced Hunting API (Device* tables)
    ))
}
if ($TeamsMode -eq "full") {
    # Requires the Team to live in THIS app registration's own tenant to ever work
    # (poller.go's delta query) -- pointless to request for webhook_only/none, where
    # team_id is left blank anyway. (No permission is requested for report delivery --
    # it needs none in any TeamsMode; see the doc comment above.)
    $RequiredGraphPermissions.AddRange([string[]]@(
        "ChannelMessage.Read.All"        # read Teams channel messages for feedback loop
    ))
}

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

function Write-Step([string]$Step, [string]$Message) {
    Write-Host ""
    Write-Host "[$Step] $Message" -ForegroundColor Cyan
}
function Write-Ok([string]$Message)   { Write-Host "  OK  $Message" -ForegroundColor Green }
function Write-Info([string]$Message) { Write-Host "      $Message" }
function Write-Skip([string]$Message) { Write-Host "  --  $Message (already exists, skipping)" -ForegroundColor Yellow }

function Confirm-AzCli {
    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        throw "Azure CLI not found. Install: https://aka.ms/installazurecliwindows"
    }
}

# `az monitor data-collection *` (DCE/DCR, used for the audit Data Collection
# Rule below) lives in the monitor-control-service extension, not core az --
# install it non-interactively rather than let az's own install-prompt hang
# under -NonInteractive (it reads from stdin, which throws EOFError there).
function Confirm-MonitorExtension {
    $installed = az extension list --query "[?name=='monitor-control-service']" --output tsv 2>$null
    if (-not $installed) {
        az extension add --name monitor-control-service --only-show-errors --yes 2>$null | Out-Null
    }
}

# Prompt for a free-text value (blank allowed) unless -NonInteractive.
function Read-Value([string]$Prompt, [string]$Current) {
    if ($Current) { return $Current }
    if ($NonInteractive) { return "" }
    return (Read-Host $Prompt).Trim()
}

# Present a numbered list and return the chosen object. Honors -NonInteractive
# (auto-selects when exactly one item; throws when ambiguous).
function Select-FromList {
    param(
        [object[]]$Items,
        [string]$Label,                 # e.g. "subscription"
        [scriptblock]$Display,          # renders one item to a line
        [switch]$AllowNone              # offer a "0) none / skip" choice
    )
    if (-not $Items -or $Items.Count -eq 0) { return $null }
    if ($Items.Count -eq 1 -and -not $AllowNone) {
        $only = $Items[0]
        Write-Info "Auto-selected the only $($Label): $(& $Display $only)"
        return $only
    }
    if ($NonInteractive) {
        throw "More than one $Label found and -NonInteractive was set. Pass the value explicitly."
    }

    Write-Host ""
    Write-Host "  Select a $($Label):" -ForegroundColor Cyan
    for ($i = 0; $i -lt $Items.Count; $i++) {
        Write-Host ("    {0}) {1}" -f ($i + 1), (& $Display $Items[$i]))
    }
    if ($AllowNone) { Write-Host "    0) none / skip" }

    while ($true) {
        $sel = (Read-Host "  Enter number").Trim()
        if ($AllowNone -and $sel -eq "0") { return $null }
        $n = 0
        if ([int]::TryParse($sel, [ref]$n) -and $n -ge 1 -and $n -le $Items.Count) {
            return $Items[$n - 1]
        }
        Write-Host "    Invalid choice." -ForegroundColor Yellow
    }
}

# Build the deploy config file content. Pulls customer/Azure values from script scope;
# app/secret values are passed in (real after creation, placeholders during -DryRun).
function Write-DeployConfig {
    param(
        [string]$AppId,
        [string]$ObjectId,
        [string]$ClientSecret,
        [string]$SecretExpiry,
        [switch]$IsDryRun
    )
    $generated = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $dryNote = if ($IsDryRun) {
        "# *** DRY-RUN PREVIEW *** No resources were created. appId/objectId/secret below`n" +
        "# are placeholders. Re-run WITHOUT -DryRun to provision and write real values.`n#"
    } else { "#" }

    # Bootstrap/control-server override (internal/testing only). Lines are omitted
    # entirely when blank so deploy-aci.ps1's PROVIDER-section default is untouched
    # for the normal partner flow - writing them as "" here would otherwise stomp
    # that default when the config file is dot-sourced.
    $bootstrapLines = [System.Collections.Generic.List[string]]::new()
    if ($BootstrapUrl)       { $bootstrapLines.Add("`$BootstrapUrl       = `"$BootstrapUrl`"") }
    if ($BootstrapToken)     { $bootstrapLines.Add("`$BootstrapToken     = `"$BootstrapToken`"") }
    if ($BootstrapTlsVerify) { $bootstrapLines.Add("`$BootstrapTlsVerify = `"$BootstrapTlsVerify`"") }
    $bootstrapSection = if ($bootstrapLines.Count -gt 0) {
        "`n# Bootstrap / control server override (testing only; blank/omitted => deploy-aci.ps1's`n" +
        "# PROVIDER section default is used instead)`n" + ($bootstrapLines -join "`n")
    } else { "" }

    # ACR pull-token password (optional). Omitted entirely when blank, same reasoning as
    # bootstrapLines above -- deploy-aci.ps1's own PROVIDER section stays blank either way,
    # since that script is synced verbatim to the public partner onboarding repo and must
    # never hold a real secret; this is the file it's meant to come from instead.
    $acrLines = [System.Collections.Generic.List[string]]::new()
    if ($AcrPullPassword) { $acrLines.Add("`$AcrPullPassword = `"$AcrPullPassword`"") }
    $acrSection = if ($acrLines.Count -gt 0) {
        "`n# ACR pull-token password (keeps this out of deploy-aci.ps1's own PROVIDER section --`n" +
        "# that file is synced to the public partner onboarding repo)`n" + ($acrLines -join "`n")
    } else { "" }

    $configContent = @"
# =====================================================================
# EasySOC deploy config -- generated by Prepare-Tenant.ps1 on $generated
# Consumed by deploy-aci.ps1 (it dot-sources this file).
# Contains SECRETS (client secret, API keys). Do NOT commit to source control.
$dryNote
# Customer    : $CustomerId
# App         : $AppName  (appId $AppId, objectId $ObjectId)
# Secret exp. : $SecretExpiry
# =====================================================================

# Customer Azure
`$ResourceGroup        = "$ResourceGroup"
`$Location             = "$Location"
`$ContainerName        = "soc-agent"

# Azure Files (storage key fetched automatically by deploy-aci.ps1)
`$StorageAccount       = "$StorageAccountName"
`$FileShare            = "$FileShareName"
# Resource group the storage account itself lives in -- only differs from
# `$ResourceGroup above when an existing account with this name was found (and
# reused) in a different resource group; see Prepare-Tenant.ps1 step 6.
`$StorageResourceGroup = "$StorageResourceGroup"

# Application
`$SocCustomerId        = "$CustomerId"
`$SocCaseBackend       = "$CaseBackend"
`$SiemTenantSku        = "$TenantSku"
`$MsTenantId           = "$TenantId"
`$MsClientId           = "$AppId"
`$MsClientSecret       = "$ClientSecret"
`$MsSubscriptionId     = "$SubscriptionId"

# Sentinel
`$MsSentinelWorkspace  = "$SentinelWorkspaceId"

# Sentinel case backend (only used when `$SocCaseBackend is switched to
# "sentinel" -- SocCaseBackend above stays "xdr" by default; edit this file
# by hand to opt in). Resource group/workspace name are auto-populated from
# the same workspace-ARM-ID parse used for the shared key above; the
# service-principal object ID is this same app registration's SP objectId
# (same identity as `$MsClientId, just its object ID rather than its
# application ID -- used to tell the agent's own incident comments apart
# from a human reply).
`$MsSentinelResourceGroup = "$_laResourceGroup"
`$MsSentinelWorkspaceName = "$_laWorkspaceName"
`$MsSentinelSpObjectId    = "$ObjectId"

# Audit DCR (Log Analytics ingestion for EasySOC_Audit_CL -- see
# agent/internal/casebackend/auditcommon.go). Blank if Sentinel was skipped or
# DCR provisioning failed -- internal audit falls back to JSONL-only in that case.
`$XdrDcrEndpoint = "$XdrDcrEndpoint"
`$XdrDcrRuleId   = "$XdrDcrRuleId"

# ACI container-log integration (same workspace as Sentinel above; set at deploy
# time only - Azure Portal doesn't support this for the agent's container config)
`$LogAnalyticsWorkspaceId  = "$SentinelWorkspaceId"
`$LogAnalyticsWorkspaceKey = "$LogAnalyticsWorkspaceKey"

# Inference backend ("anthropic" or "azure_openai"; blank => anthropic)
`$LlmBackend           = "$LlmBackend"
# Anthropic backend (used when LlmBackend=anthropic; blank base URL => public api.anthropic.com)
`$AnthropicBaseUrl     = "$AnthropicBaseUrl"
`$AnthropicApiKey      = "$AnthropicApiKey"
# Azure OpenAI backend (used when LlmBackend=azure_openai)
`$AzureOpenAiEndpoint  = "$AzureOpenAiEndpoint"
`$AzureOpenAiApiKey    = "$AzureOpenAiApiKey"
`$AzureOpenAiDeployment = "$AzureOpenAiDeployment"

# Teams
`$TeamsWebhookUrl      = "$TeamsWebhookUrl"
`$TeamsTeamId          = "$TeamsTeamId"
`$TeamsChannelId       = "$TeamsChannelId"
$bootstrapSection
$acrSection
# Threat-intel enrichment (optional)
`$VirusTotalApiKey     = "$VirusTotalApiKey"
`$AbuseIpDbApiKey      = "$AbuseIpDbApiKey"
`$IpInfoToken          = "$IpInfoToken"
"@
    Set-Content -Path $ConfigOutPath -Value $configContent -Encoding UTF8
    return (Resolve-Path $ConfigOutPath).Path
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

Confirm-AzCli

if ($DryRun) {
    Write-Host ""
    Write-Host "DRY RUN -- discovery only; no changes and no config file will be written." -ForegroundColor Magenta
}

# Step 1: authentication
Write-Step "1/8" "Verifying Azure CLI authentication"
$accountJson = az account show 2>$null
if ($LASTEXITCODE -ne 0) {
    throw "Not logged in. Run: az login --tenant TENANT-ID"
}
$account  = $accountJson | ConvertFrom-Json
$TenantId = $account.tenantId
Write-Ok "Authenticated"
Write-Info "Tenant: $TenantId"

# Step 2: subscription selection (auto / prompt)
Write-Step "2/8" "Selecting Azure subscription"
if (-not $SubscriptionId) {
    $subs = az account list --query "[?state=='Enabled']" --output json | ConvertFrom-Json
    if (-not $subs -or $subs.Count -eq 0) { throw "No enabled subscriptions found for this account." }
    $chosen = Select-FromList -Items $subs -Label "subscription" `
        -Display { param($s) "$($s.name)  ($($s.id))" }
    $SubscriptionId = $chosen.id
}
Write-Info "Subscription: $SubscriptionId"
if (-not $DryRun) {
    az account set --subscription $SubscriptionId | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Failed to set subscription '$SubscriptionId'." }
}

# Resolve resource group (prompt with existing list if not supplied)
if (-not $ResourceGroup) {
    if ($NonInteractive) { throw "-ResourceGroup is required with -NonInteractive." }
    $rgs = az group list --query "[].{name:name,location:location}" --output json | ConvertFrom-Json
    if ($rgs -and $rgs.Count -gt 0) {
        Write-Host ""
        Write-Host "  Existing resource groups:" -ForegroundColor Cyan
        foreach ($g in $rgs) { Write-Host "    - $($g.name)  ($($g.location))" }
    }
    $ResourceGroup = (Read-Host "  Resource group name (existing or new)").Trim()
    if (-not $ResourceGroup) { throw "Resource group is required." }
}

# Resolve location (from existing RG, else prompt)
if (-not $Location) {
    $rgLoc = az group show --name $ResourceGroup --query "location" --output tsv 2>$null
    if ($LASTEXITCODE -eq 0 -and $rgLoc) {
        $Location = $rgLoc
        Write-Info "Using resource group region: $Location"
    } else {
        if ($NonInteractive) { throw "-Location is required for a new resource group with -NonInteractive." }
        $Location = (Read-Host "  Azure region for new resource group (e.g. eastus, westeurope)").Trim()
        if (-not $Location) { throw "Location is required to create a new resource group." }
    }
}

# Derive storage account name if not supplied
if (-not $StorageAccountName) {
    $raw = "easysoc" + ($CustomerId.ToLower() -replace "[^a-z0-9]", "")
    $StorageAccountName = $raw.Substring(0, [Math]::Min(24, $raw.Length))
}

Write-Info "Resource group: $ResourceGroup   Location: $Location"
Write-Info "Storage account: $StorageAccountName   File share: $FileShareName"

# Step 3: resolve Graph permission GUIDs
Write-Step "3/8" "Resolving Microsoft Graph permission IDs"
$graphSp   = az ad sp show --id $GraphAppId | ConvertFrom-Json
$permSpecs = [System.Collections.Generic.List[string]]::new()
foreach ($permName in $RequiredGraphPermissions) {
    $perm = $graphSp.appRoles | Where-Object { $_.value -eq $permName }
    if (-not $perm) { throw "Permission '$permName' not found in Microsoft Graph appRoles." }
    $permSpecs.Add("$($perm.id)=Role")
    Write-Info "Graph: $permName -> $($perm.id)"
}
Write-Ok "All $($RequiredGraphPermissions.Count) Graph permissions resolved"

if ($DryRun) {
    Write-Host ""
    Write-Host "DRY RUN -- skipping all creation; running read-only discovery to build a preview config." -ForegroundColor Magenta
    # Placeholders for values that only exist after real provisioning. Discovery
    # (Sentinel/Foundry) below still runs read-only and populates real values.
    $app          = [pscustomobject]@{ appId = "<DRY-RUN-appId-not-created>" }
    $sp           = [pscustomobject]@{ id    = "<DRY-RUN-objectId-not-created>" }
    $ClientSecret = "<DRY-RUN-secret-not-created>"
    $SecretExpiry = "(not created)"
}

# Step 4: app registration + service principal (idempotent)
Write-Step "4/8" "Creating app registration '$AppName'"
if ($DryRun) {
    Write-Info "DRY RUN: would create app registration '$AppName' + service principal, add $($RequiredGraphPermissions.Count) Graph permissions, and grant admin consent."
} else {
    $existingApps = az ad app list --display-name $AppName | ConvertFrom-Json
    if ($existingApps.Count -gt 0) {
        $app = $existingApps[0]
        Write-Skip "appId = $($app.appId)"
    } else {
        $app = az ad app create --display-name $AppName --sign-in-audience "AzureADMyOrg" | ConvertFrom-Json
        Write-Ok "Created  appId = $($app.appId)"
    }

    $existingSps = az ad sp list --filter "appId eq '$($app.appId)'" | ConvertFrom-Json
    if ($existingSps.Count -gt 0) {
        $sp = $existingSps[0]
        Write-Skip "service principal objectId = $($sp.id)"
    } else {
        $sp = az ad sp create --id $app.appId | ConvertFrom-Json
        Write-Ok "Created service principal objectId = $($sp.id)"
    }

    Write-Info "Adding Microsoft Graph permissions..."
    az ad app permission add --id $app.appId --api $GraphAppId --api-permissions $permSpecs.ToArray() | Out-Null
    Write-Ok "Graph permissions added"

    Write-Info "Granting admin consent (requires Application Administrator)..."
    $consentGranted = $false
    $deadline = (Get-Date).AddSeconds(120)
    while (-not $consentGranted -and (Get-Date) -lt $deadline) {
        try { az ad app permission admin-consent --id $app.appId 2>$null | Out-Null } catch {}
        if ($LASTEXITCODE -eq 0) {
            $consentGranted = $true
        } else {
            Write-Info "  Waiting for Entra ID replication (retrying in 10s)..."
            Start-Sleep -Seconds 10
        }
    }
    if (-not $consentGranted) {
        Write-Warning "Admin consent failed. Grant manually: Entra ID -> App registrations -> $AppName -> API permissions -> Grant admin consent."
    } else {
        Write-Ok "Admin consent granted"
    }
}

# Step 5: client secret
Write-Step "5/8" "Creating client secret (expires in $SecretExpiryYears year(s))"
if ($DryRun) {
    Write-Info "DRY RUN: would create a client secret valid for $SecretExpiryYears year(s)."
} else {
    $secretResult = az ad app credential reset --id $app.appId --years $SecretExpiryYears --append `
        --display-name "$AppName-secret" | ConvertFrom-Json
    $ClientSecret = $secretResult.password
    $SecretExpiry = (Get-Date).AddYears($SecretExpiryYears).ToString("yyyy-MM-dd")
    Write-Ok "Client secret created (expires $SecretExpiry)"
}

# Step 6: storage account + Files share
Write-Step "6/8" "Creating Azure Storage account '$StorageAccountName' and Files share '$FileShareName'"
# Defaults to $ResourceGroup; only diverges if an existing account with this exact
# name is found in a DIFFERENT resource group and reused in place (see below) --
# storage account names are globally unique across ALL of Azure (not just this
# subscription or resource group), so "not found in $ResourceGroup" does not mean
# "name is free": you can already own it elsewhere (e.g. a partial prior run
# against a different -ResourceGroup), and a bare `create` would then fail with
# StorageAccountAlreadyTaken instead of offering to reuse it. Persisted into the
# generated config distinctly from $ResourceGroup so deploy-aci.ps1's own storage-key
# fetch looks in the right place too.
$StorageResourceGroup = $ResourceGroup

if ($DryRun) {
    Write-Info "DRY RUN: would ensure resource group '$ResourceGroup' ($Location), storage account '$StorageAccountName', and file share '$FileShareName' (5 GiB)."
} else {
    Write-Info "Ensuring Microsoft.Storage resource provider is registered..."
    az provider register --namespace Microsoft.Storage --wait | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Failed to register Microsoft.Storage provider on '$SubscriptionId' (need Contributor)." }
    Write-Ok "Microsoft.Storage provider registered"

    $rgExists = az group exists --name $ResourceGroup --output tsv
    if ($rgExists -eq "false") {
        Write-Info "Resource group '$ResourceGroup' not found - creating in $Location..."
        az group create --name $ResourceGroup --location $Location | Out-Null
        Write-Ok "Resource group created"
    } else {
        Write-Info "Resource group '$ResourceGroup' already exists"
    }

    # Loops (rather than a single attempt) so a name collision that can't be resolved
    # by reuse -- see the StorageAccountAlreadyTaken branch below -- lets you type a
    # different name right here instead of restarting the whole script from step 1.
    $storageReady = $false
    while (-not $storageReady) {
        $existingSa = $null
        try {
            $existingSa = az storage account show --name $StorageAccountName --resource-group $ResourceGroup 2>$null | ConvertFrom-Json
        } catch {}

        if ($existingSa) {
            Write-Skip "storage account '$StorageAccountName' (in '$ResourceGroup')"
            $StorageResourceGroup = $ResourceGroup
            $storageReady = $true
            continue
        }

        # Not in the target RG -- check the rest of the subscription before assuming
        # the name is free (storage account names are globally unique across ALL of
        # Azure, not just this RG, so "not found here" doesn't mean "free").
        $subMatches = $null
        try {
            $subMatches = az storage account list --query "[?name=='$StorageAccountName']" --output json 2>$null | ConvertFrom-Json
        } catch {}

        if ($subMatches -and $subMatches.Count -gt 0) {
            $foundRg = $subMatches[0].resourceGroup
            Write-Info "Storage account '$StorageAccountName' already exists in resource group '$foundRg' (not '$ResourceGroup')."
            $reuse = $true
            if (-not $NonInteractive) {
                $answer = (Read-Host "  Reuse it there instead of creating a new one? (Y/n)").Trim()
                $reuse = (-not $answer) -or ($answer -match "^(?i)y")
            }
            if ($reuse) {
                $StorageResourceGroup = $foundRg
                Write-Ok "Reusing storage account '$StorageAccountName' from '$foundRg'"
                $storageReady = $true
                continue
            }
            if ($NonInteractive) {
                throw "Storage account name '$StorageAccountName' is in use in resource group '$foundRg'. Re-run with a different -StorageAccountName."
            }
            $StorageAccountName = (Read-Host "  Enter a different storage account name (3-24 lowercase letters/digits)").Trim()
            if ($StorageAccountName -notmatch "^[a-z0-9]{3,24}$") { throw "Storage account name must be 3-24 lowercase letters/digits." }
            continue
        }

        # Not found via show or list -- attempt creation directly. A prior version of
        # this script tried to pre-check with `az storage account check-name-availability`
        # to give a cleaner error before attempting creation, but that API was observed
        # to disagree with the actual create call for a name that's still taken --
        # reacting to the real creation failure (below) is the reliable signal.
        #
        # Redirect stderr to a FILE, not `2>&1`: az routinely writes informational text
        # (e.g. "...will continue to update the existing account") to stderr even on a
        # call that isn't actually failing, and `2>&1` routes that through PowerShell's
        # native-command error-record pipeline, where -- depending on PS version/session
        # settings ($PSNativeCommandUseErrorActionPreference) -- $ErrorActionPreference =
        # "Stop" (set globally at the top of this script) can promote it straight to a
        # terminating exception before $LASTEXITCODE is even checked, aborting the
        # script here instead of letting the retry logic below react to a genuine
        # failure. File redirection (like the `2>$null` calls already used safely
        # throughout this script) never enters that pipeline, sidestepping the
        # version-dependent behavior entirely rather than trying to out-guess it.
        $errFile = [System.IO.Path]::GetTempFileName()
        try {
            az storage account create --name $StorageAccountName --resource-group $StorageResourceGroup `
                --location $Location --sku "Standard_LRS" --kind "StorageV2" `
                --allow-blob-public-access false --min-tls-version "TLS1_2" 1>$null 2>$errFile
            $createExitCode = $LASTEXITCODE
            $errText = if (Test-Path $errFile) { Get-Content $errFile -Raw } else { "" }
        } finally {
            Remove-Item $errFile -ErrorAction SilentlyContinue
        }
        if ($createExitCode -eq 0) {
            Write-Ok "Storage account created"
            $storageReady = $true
            continue
        }

        if ($errText -match "StorageAccountAlreadyTaken") {
            Write-Warning "'$StorageAccountName' isn't visible via 'show'/'list' in this subscription, but Azure still reports the name as taken. Storage account names live in a global DNS namespace (<name>.blob.core.windows.net) -- the most common cause is a stale name reservation left behind by a PREVIOUSLY DELETED account with this exact name, which can outlive the account itself for a period. There is nothing to reuse here (it isn't a resource this subscription can see or manage); the practical fix is a different name."
            if ($NonInteractive) {
                throw "Storage account name '$StorageAccountName' is unavailable (StorageAccountAlreadyTaken) and not owned by this subscription. Re-run with a different -StorageAccountName."
            }
            $StorageAccountName = (Read-Host "  Enter a different storage account name (3-24 lowercase letters/digits)").Trim()
            if ($StorageAccountName -notmatch "^[a-z0-9]{3,24}$") { throw "Storage account name must be 3-24 lowercase letters/digits." }
            continue
        }

        throw "Storage account creation failed (check Contributor on '$StorageResourceGroup'):`n$errText"
    }

    $storageKey = az storage account keys list --account-name $StorageAccountName `
        --resource-group $StorageResourceGroup --query "[0].value" --output tsv
    if ($LASTEXITCODE -ne 0 -or -not $storageKey) { throw "Failed to retrieve storage account key for '$StorageAccountName' (resource group '$StorageResourceGroup')." }

    $existingShare = az storage share exists --name $FileShareName --account-name $StorageAccountName `
        --account-key $storageKey --query "exists" --output tsv
    if ($existingShare -eq "true") {
        Write-Skip "file share '$FileShareName'"
    } else {
        az storage share create --name $FileShareName --account-name $StorageAccountName `
            --account-key $storageKey --quota 5 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "File share creation failed." }
        Write-Ok "File share '$FileShareName' created (5 GiB quota)"
    }
}

# Step 7: Sentinel workspace discovery + Reader role
Write-Step "7/8" "Discovering Sentinel / Log Analytics workspace and assigning Sentinel Reader"
$LogAnalyticsWorkspaceKey = ""
# Populated below (elseif branch, workspace ARM ID parse) when discovery
# succeeds -- declared here with Set-StrictMode-safe defaults since
# Write-DeployConfig reads them even when that branch never runs (e.g.
# Sentinel skipped, or ARM ID parse fails).
$_laResourceGroup = ""
$_laWorkspaceName = ""
# Audit DCR (populated below, in the same $SentinelWorkspaceId block, once the
# workspace ARM ID / resource group / name are resolved) -- Set-StrictMode-safe
# defaults since Write-DeployConfig reads them even when DCR provisioning is
# skipped or fails.
$XdrDcrEndpoint = ""
$XdrDcrRuleId   = ""
if ($SentinelWorkspaceId -eq "none") {
    Write-Info "Sentinel explicitly skipped (-SentinelWorkspaceId none)."
    $SentinelWorkspaceId = ""
} elseif (-not $SentinelWorkspaceId) {
    $workspaces = az monitor log-analytics workspace list `
        --query "[].{name:name,rg:resourceGroup,customerId:customerId,id:id}" --output json | ConvertFrom-Json
    if (-not $workspaces -or $workspaces.Count -eq 0) {
        Write-Warning "No Log Analytics workspaces found. Sentinel queries will be unavailable; assign the Reader role manually later."
    } else {
        $ws = Select-FromList -Items $workspaces -Label "Sentinel workspace" -AllowNone `
            -Display { param($w) "$($w.name)  (rg=$($w.rg), id=$($w.customerId))" }
        if ($ws) {
            $SentinelWorkspaceId = $ws.customerId
            $workspaceArmId      = $ws.id
        }
    }
}

if ($SentinelWorkspaceId) {
    if (-not (Get-Variable -Name workspaceArmId -Scope 0 -ErrorAction SilentlyContinue) -or -not $workspaceArmId) {
        $wsQuery        = "[?customerId=='$SentinelWorkspaceId'].id | [0]"
        $workspaceArmId = az monitor log-analytics workspace list --query $wsQuery --output tsv
    }
    if (-not $workspaceArmId) {
        Write-Warning "Could not resolve workspace ARM ID for customerId '$SentinelWorkspaceId'. Assign the Sentinel Reader/Responder roles manually."
    } elseif ($DryRun) {
        Write-Info "DRY RUN: would assign 'Microsoft Sentinel Reader' and 'Microsoft Sentinel Responder' to the service principal on $workspaceArmId."
    } else {
        $existingRa = az role assignment list --assignee $sp.id --role "Microsoft Sentinel Reader" `
            --scope $workspaceArmId --query "[0].id" --output tsv
        if ($existingRa) {
            Write-Skip "Sentinel Reader role"
        } else {
            az role assignment create --assignee $sp.id --role "Microsoft Sentinel Reader" --scope $workspaceArmId --output none
            if ($LASTEXITCODE -ne 0) {
                Write-Warning "Role assignment failed. Run: az role assignment create --assignee $($sp.id) --role 'Microsoft Sentinel Reader' --scope $workspaceArmId"
            } else {
                Write-Ok "Sentinel Reader role assigned"
            }
        }

        # Sentinel Responder: only Reader was needed while this app registration
        # only ever read Sentinel (SIEM query tool, case-history search). The
        # case_backend: sentinel option (writes labels/comments/classification
        # directly to incidents) needs write access too -- assign it
        # unconditionally alongside Reader so a partner can flip
        # $SocCaseBackend to "sentinel" later without a second manual role grant.
        $existingRaResponder = az role assignment list --assignee $sp.id --role "Microsoft Sentinel Responder" `
            --scope $workspaceArmId --query "[0].id" --output tsv
        if ($existingRaResponder) {
            Write-Skip "Sentinel Responder role"
        } else {
            az role assignment create --assignee $sp.id --role "Microsoft Sentinel Responder" --scope $workspaceArmId --output none
            if ($LASTEXITCODE -ne 0) {
                Write-Warning "Role assignment failed. Run: az role assignment create --assignee $($sp.id) --role 'Microsoft Sentinel Responder' --scope $workspaceArmId"
            } else {
                Write-Ok "Sentinel Responder role assigned"
            }
        }
    }

    # Audit DCR: Data Collection Endpoint + Data Collection Rule + the
    # EasySOC_Audit_CL custom table, so internal-audit read/write actually
    # reaches Log Analytics instead of silently no-opping with "audit DCR not
    # configured" (see agent/internal/casebackend/auditcommon.go). DCE/DCR
    # names are namespaced per customer; the table name and column schema are
    # fixed and shared across all customers -- must match auditcommon.go's
    # `row` map exactly. Requires $workspaceArmId, $_laResourceGroup and
    # $_laWorkspaceName, all resolved above.
    $DceName        = "dce-easysoc-$CustomerId"
    $DcrName        = "dcr-easysoc-$CustomerId"
    $AuditTableName = "EasySOC_Audit_CL"

    # ONE definition of the audit schema, used by the table and by the DCR's
    # stream declaration below. They must agree: the Logs Ingestion API accepts
    # a row with 204 and silently discards any field the stream does not
    # declare, so a mismatch loses data with nothing in any log to say so.
    #
    # This must also match auditcommon.go's `row` map plus everything
    # derivationAuditColumns adds. BUG-033: the first ten were declared and the
    # fourteen derivation fields were not, so every Band_s, Branch_s,
    # Separation_d ... value the agent ever wrote was dropped on the floor.
    $AuditColumnSpec = [ordered]@{
        # auditcommon.go writeInternalAudit `row`
        'TimeGenerated'        = 'datetime'
        'IncidentId_s'         = 'string'
        'InvestigationId_g'    = 'string'
        'AuditBody_s'          = 'string'
        'CostUSD_d'            = 'real'
        'InputTokens_d'        = 'real'
        'OutputTokens_d'       = 'real'
        'DurationMs_d'         = 'real'
        'LLMCalls_d'           = 'real'
        'ToolCalls_d'          = 'real'
        # auditcommon.go derivationAuditColumns -- absent when no hypothesis
        # set was produced, which reads as "the harness did not derive", and is
        # why none of these is required on a row
        'DerivationVersion_s'  = 'string'
        'Band_s'               = 'string'
        'Branch_s'             = 'string'
        'Separation_d'         = 'real'
        'Entropy_d'            = 'real'
        'DisagreementMargin_d' = 'real'
        'VerdictAgreement_b'   = 'boolean'
        'CrossContradiction_b' = 'boolean'
        'Resynthesized_b'      = 'boolean'
        'Caps_s'               = 'string'
        'ContextItems_d'       = 'real'
        'ContextCorrob_d'      = 'real'
        'ContextContra_d'      = 'real'
        'ContextOnlyClosure_b' = 'boolean'
    }
    $AuditColumnArgs = @($AuditColumnSpec.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" })
    $AuditColumnJson = (@($AuditColumnSpec.GetEnumerator() | ForEach-Object {
        '          { "name": "' + $_.Key + '", "type": "' + $_.Value + '" }'
    }) -join ",`n")

    if ($DryRun) {
        Write-Info "DRY RUN: would ensure DCE '$DceName', table '$AuditTableName' with $($AuditColumnSpec.Count) columns, DCR '$DcrName' declaring the same $($AuditColumnSpec.Count), and 'Monitoring Metrics Publisher' on the DCR for the service principal. An existing table or DCR with fewer columns is UPGRADED, not skipped (BUG-033)."
    } elseif (-not $workspaceArmId) {
        Write-Warning "Skipping audit DCR provisioning -- workspace ARM ID could not be resolved."
    } else {
        Confirm-MonitorExtension

        $dce = az monitor data-collection endpoint show --name $DceName --resource-group $ResourceGroup 2>$null | ConvertFrom-Json
        if ($dce) {
            Write-Skip "Data Collection Endpoint '$DceName'"
        } else {
            $dce = az monitor data-collection endpoint create --name $DceName --resource-group $ResourceGroup `
                --location $Location --public-network-access "Enabled" `
                --description "EasySOC internal-audit ingestion endpoint (Logs Ingestion API -> $AuditTableName)" `
                2>$null | ConvertFrom-Json
            if (-not $dce) {
                Write-Warning "Data Collection Endpoint creation failed. Internal audit to Log Analytics will stay disabled (JSONL-only) until this is provisioned manually."
            } else {
                Write-Ok "Data Collection Endpoint '$DceName' created"
            }
        }

        # The destination table must exist before the DCR can reference it -- a
        # DCR create against a not-yet-existing table fails with
        # InvalidOutputTable. It is NOT auto-created on first ingest, despite
        # auditcommon.go's comment assuming lazy creation (confirmed live
        # 2026-09-09 against law-sentinel; see Experiments/Local Run Triage --
        # 2026-09-08 Evening Batch in the project vault).
        if ($dce) {
            $existingTable = az monitor log-analytics workspace table show --resource-group $ResourceGroup `
                --workspace-name $_laWorkspaceName --name $AuditTableName 2>$null | ConvertFrom-Json
            if ($existingTable) {
                # A tenant prepared before BUG-033 has the table but only the
                # first ten columns, and the old code took "it exists" as "it is
                # correct" and skipped. Re-running this script must UPGRADE such
                # a tenant, or the fix never reaches anyone already onboarded.
                $haveCols    = @($existingTable.schema.columns | ForEach-Object { $_.name })
                $missingCols = @($AuditColumnSpec.Keys | Where-Object { $haveCols -notcontains $_ })
                if ($missingCols.Count -eq 0) {
                    Write-Skip "Log Analytics table '$AuditTableName'"
                } else {
                    Write-Info "Table '$AuditTableName' is missing $($missingCols.Count) column(s): $($missingCols -join ', ') -- updating"
                    az monitor log-analytics workspace table update --resource-group $ResourceGroup `
                        --workspace-name $_laWorkspaceName --name $AuditTableName `
                        --columns $AuditColumnArgs --output none
                    if ($LASTEXITCODE -ne 0) {
                        Write-Warning "Log Analytics table '$AuditTableName' update failed. Existing rows keep working; the derivation columns stay dropped."
                    } else {
                        Write-Ok "Log Analytics table '$AuditTableName' updated to $($AuditColumnSpec.Count) columns"
                    }
                }
            } else {
                az monitor log-analytics workspace table create --resource-group $ResourceGroup `
                    --workspace-name $_laWorkspaceName --name $AuditTableName `
                    --columns $AuditColumnArgs `
                    --description "EasySOC internal investigation audit trail (agent-written, cost/token/duration metrics per case)" `
                    --output none
                if ($LASTEXITCODE -ne 0) {
                    Write-Warning "Log Analytics table '$AuditTableName' creation failed. Skipping DCR; internal audit stays JSONL-only."
                    $dce = $null
                } else {
                    Write-Ok "Log Analytics table '$AuditTableName' created"
                }
            }
        }

        $dcr = $null
        if ($dce) {
            $dcr = az monitor data-collection rule show --name $DcrName --resource-group $ResourceGroup 2>$null | ConvertFrom-Json

            # Same upgrade question as the table above: an existing DCR from
            # before BUG-033 declares ten columns, and skipping it leaves the
            # other fourteen silently dropped. Compare, and rewrite if short.
            #
            # NOTE: `az monitor data-collection rule update` (and a raw ARM
            # PATCH) only accepts tags -- a PATCH carrying streamDeclarations
            # returns 200 and changes nothing, which is how this was first
            # missed on 2026-09-20. `rule create` is a PUT and replaces the
            # rule, so the body below has to stay complete.
            $dcrNeedsWrite = $true
            if ($dcr) {
                $dcrCols = @()
                $decl = $dcr.streamDeclarations."Custom-$AuditTableName"
                if ($decl) { $dcrCols = @($decl.columns | ForEach-Object { $_.name }) }
                $dcrMissing = @($AuditColumnSpec.Keys | Where-Object { $dcrCols -notcontains $_ })
                if ($dcrMissing.Count -eq 0) {
                    Write-Skip "Data Collection Rule '$DcrName'"
                    $dcrNeedsWrite = $false
                } else {
                    Write-Info "DCR '$DcrName' declares $($dcrCols.Count) of $($AuditColumnSpec.Count) columns, missing: $($dcrMissing -join ', ') -- rewriting"
                }
            }

            if ($dcrNeedsWrite) {
                $verb = if ($dcr) { "updated" } else { "created" }
                $ruleFile = [System.IO.Path]::GetTempFileName()
                $ruleBody = @"
{
  "properties": {
    "dataCollectionEndpointId": "$($dce.id)",
    "streamDeclarations": {
      "Custom-$AuditTableName": {
        "columns": [
$AuditColumnJson
        ]
      }
    },
    "destinations": { "logAnalytics": [ { "workspaceResourceId": "$workspaceArmId", "name": "easysocAuditWorkspace" } ] },
    "dataFlows": [ { "streams": ["Custom-$AuditTableName"], "destinations": ["easysocAuditWorkspace"], "outputStream": "Custom-$AuditTableName", "transformKql": "source" } ]
  }
}
"@
                Set-Content -Path $ruleFile -Value $ruleBody -Encoding UTF8
                $dcr = az monitor data-collection rule create --name $DcrName --resource-group $ResourceGroup `
                    --location $Location --data-collection-endpoint-id $dce.id --rule-file $ruleFile 2>$null | ConvertFrom-Json
                Remove-Item $ruleFile -ErrorAction SilentlyContinue
                if (-not $dcr) {
                    Write-Warning "Data Collection Rule $verb failed. Internal audit to Log Analytics will stay disabled (JSONL-only) until this is provisioned manually."
                } else {
                    Write-Ok "Data Collection Rule '$DcrName' $verb ($($AuditColumnSpec.Count) columns)"
                }
            }
        }

        if ($dcr) {
            # Monitoring Metrics Publisher on the DCR -- idempotent, with a short
            # retry for ARM replication lag on a just-created DCR (same reasoning
            # as the admin-consent retry loop in step 4). NOTE: if this script is
            # ever run from Git Bash rather than PowerShell, a raw "/subscriptions/..."
            # --scope argument can get silently mangled into a Windows path by
            # MSYS path conversion, surfacing as a confusing "MissingSubscription"
            # error from Azure -- not applicable here (this is a .ps1, run under
            # PowerShell), but worth knowing if this logic is ever ported to a
            # bash equivalent.
            $existingRaMetrics = az role assignment list --assignee $sp.id --role "Monitoring Metrics Publisher" `
                --scope $dcr.id --query "[0].id" --output tsv
            if ($existingRaMetrics) {
                Write-Skip "Monitoring Metrics Publisher role (on DCR)"
            } else {
                $metricsRaOk = $false
                $metricsDeadline = (Get-Date).AddSeconds(60)
                while (-not $metricsRaOk -and (Get-Date) -lt $metricsDeadline) {
                    az role assignment create --assignee $sp.id --role "Monitoring Metrics Publisher" --scope $dcr.id --output none 2>$null
                    if ($LASTEXITCODE -eq 0) { $metricsRaOk = $true } else { Start-Sleep -Seconds 10 }
                }
                if ($metricsRaOk) {
                    Write-Ok "Monitoring Metrics Publisher role assigned (on DCR)"
                } else {
                    Write-Warning "Role assignment failed. Run: az role assignment create --assignee $($sp.id) --role 'Monitoring Metrics Publisher' --scope $($dcr.id)"
                }
            }

            $XdrDcrEndpoint = $dce.logsIngestion.endpoint
            $XdrDcrRuleId   = $dcr.immutableId
            Write-Ok "Audit DCR ready: endpoint=$XdrDcrEndpoint rule=$XdrDcrRuleId"
        }
    }

    # Retrieve the workspace shared key so deploy-aci.ps1 can enable ACI
    # container-log integration on this same workspace (Portal doesn't support
    # this for the agent's container config - see .PARAMETER SentinelWorkspaceId).
    # `get-shared-keys` (unlike most `show` commands) does not accept --ids, so
    # resource group + workspace name are parsed out of the ARM resource ID.
    if ($DryRun) {
        Write-Info "DRY RUN: would retrieve the workspace shared key for ACI container-log integration."
    } elseif ($workspaceArmId -and $workspaceArmId -match '/resourceGroups/([^/]+)/providers/Microsoft\.OperationalInsights/workspaces/([^/]+)$') {
        $_laResourceGroup = $matches[1]
        $_laWorkspaceName = $matches[2]
        $LogAnalyticsWorkspaceKey = az monitor log-analytics workspace get-shared-keys `
            --resource-group $_laResourceGroup --workspace-name $_laWorkspaceName `
            --query "primarySharedKey" --output tsv
        if ($LASTEXITCODE -ne 0 -or -not $LogAnalyticsWorkspaceKey) {
            Write-Warning "Could not retrieve the workspace shared key. ACI container-log integration will be left disabled; add it to the config manually if needed."
            $LogAnalyticsWorkspaceKey = ""
        } else {
            Write-Ok "Workspace shared key retrieved (enables ACI container-log integration)"
        }
    } elseif ($workspaceArmId) {
        Write-Warning "Could not parse resource group/workspace name from '$workspaceArmId'. ACI container-log integration will be left disabled; add it to the config manually if needed."
    }
}

# Step 8: Foundry inference endpoint + non-retrievable prompts
Write-Step "8/8" "Inference endpoint, Teams, and enrichment configuration"

# Whether the caller explicitly chose a backend. Captured BEFORE any default is
# applied, and deliberately not defaulted here at all: a default applied at this
# point would make the "Confirm / prompt inference values" Read-Value call below a
# no-op (Read-Value returns $Current immediately once it's non-empty, without ever
# calling Read-Host) -- exactly the bug this replaces, where the script silently
# assumed "anthropic" and never actually asked.
$_llmBackendExplicit = [bool]$LlmBackend

# Azure AI Foundry / Cognitive Services discovery (best effort). Runs whenever no
# backend has been decided yet, or the relevant key for an explicitly-chosen backend
# is still missing.
$_needsDiscovery = (-not $_llmBackendExplicit) -or
                   ($LlmBackend -eq "anthropic" -and -not $AnthropicApiKey) -or
                   ($LlmBackend -eq "azure_openai" -and -not $AzureOpenAiApiKey)
if ($_needsDiscovery -and -not $NonInteractive) {
    $cog = $null
    try {
        $cog = az cognitiveservices account list `
            --query "[?kind=='AIServices' || kind=='OpenAI'].{name:name,rg:resourceGroup,endpoint:properties.endpoint,kind:kind}" `
            --output json 2>$null | ConvertFrom-Json
    } catch {}
    if ($cog -and $cog.Count -gt 0) {
        $fr = Select-FromList -Items $cog -Label "Azure AI Foundry resource" -AllowNone `
            -Display { param($f) "$($f.name)  ($($f.kind), rg=$($f.rg))" }
        if ($fr) {
            $key = az cognitiveservices account keys list --name $fr.name --resource-group $fr.rg `
                --query "key1" --output tsv 2>$null
            $keyOk = ($LASTEXITCODE -eq 0 -and $key)
            if (-not $keyOk) { Write-Warning "Could not read Foundry key automatically; enter it below." }

            if ($fr.kind -eq "OpenAI") {
                # An "OpenAI"-kind Cognitive Services resource has NO Anthropic-
                # compatible endpoint -- it can only ever serve the azure_openai
                # backend. Filing it under Anthropic (the old bug) produces an
                # AnthropicBaseUrl that silently doesn't work.
                if ($_llmBackendExplicit -and $LlmBackend -ne "azure_openai") {
                    Write-Warning "Found an Azure OpenAI-kind resource ('$($fr.name)'), but -LlmBackend was '$LlmBackend' -- it has no Anthropic-compatible endpoint, so it can't be auto-filled for that backend. Enter Anthropic values below, or re-run with -LlmBackend azure_openai to use it."
                } else {
                    $LlmBackend = "azure_openai"
                    $AzureOpenAiEndpoint = ($fr.endpoint).TrimEnd('/')
                    if ($keyOk) { $AzureOpenAiApiKey = $key }
                    Write-Ok "Foundry endpoint (Azure OpenAI): $AzureOpenAiEndpoint$(if ($keyOk) { ' (key retrieved)' })"
                }
            } elseif ($_llmBackendExplicit) {
                # "AIServices" (or another qualifying kind) can serve either backend --
                # respect the caller's explicit choice, as before.
                if ($LlmBackend -eq "azure_openai") {
                    $AzureOpenAiEndpoint = ($fr.endpoint).TrimEnd('/')
                    if ($keyOk) { $AzureOpenAiApiKey = $key }
                    Write-Ok "Foundry endpoint (Azure OpenAI): $AzureOpenAiEndpoint$(if ($keyOk) { ' (key retrieved)' })"
                } else {
                    $base = ($fr.endpoint).TrimEnd('/')
                    if ($base -notmatch '/anthropic$') { $base = "$base/anthropic" }
                    $AnthropicBaseUrl = $base
                    if ($keyOk) { $AnthropicApiKey = $key }
                    Write-Ok "Foundry endpoint (Anthropic): $AnthropicBaseUrl$(if ($keyOk) { ' (key retrieved)' })"
                }
            } else {
                # Ambiguous: no backend was requested and this resource kind can serve
                # either. Don't guess -- pre-fill BOTH slots from the discovered
                # endpoint/key so whichever backend gets picked at the prompt below
                # already has working values, and leave $LlmBackend blank so that
                # prompt actually fires instead of silently deciding for the user.
                $AzureOpenAiEndpoint = ($fr.endpoint).TrimEnd('/')
                if ($keyOk) { $AzureOpenAiApiKey = $key }
                $base = ($fr.endpoint).TrimEnd('/')
                if ($base -notmatch '/anthropic$') { $base = "$base/anthropic" }
                $AnthropicBaseUrl = $base
                if ($keyOk) { $AnthropicApiKey = $key }
                Write-Ok "Foundry resource '$($fr.name)' ($($fr.kind)) supports either backend -- both are pre-filled$(if ($keyOk) { ' (key retrieved)' }); choose which to use below."
            }
        }
    } else {
        Write-Info "No Azure AI Foundry / OpenAI resource found in this subscription."
    }
}

# Confirm / prompt inference values for the chosen backend. If nothing above decided
# $LlmBackend (no Foundry resource found, ambiguous kind left it for the user, or
# -AllowNone was declined), this Read-Value call is what actually asks -- and now can,
# since nothing set a default ahead of it.
$LlmBackend = Read-Value "  LLM backend (anthropic / azure_openai)" $LlmBackend
if (-not $LlmBackend) { $LlmBackend = "anthropic" }
if ($LlmBackend -eq "azure_openai") {
    $AzureOpenAiEndpoint   = Read-Value "  Azure OpenAI endpoint" $AzureOpenAiEndpoint
    $AzureOpenAiApiKey     = Read-Value "  Azure OpenAI API key" $AzureOpenAiApiKey
    $AzureOpenAiDeployment = Read-Value "  Azure OpenAI deployment name (e.g. gpt-5.4)" $AzureOpenAiDeployment
} else {
    $LlmBackend       = "anthropic"
    $AnthropicBaseUrl = Read-Value "  Anthropic base URL (blank = public api.anthropic.com)" $AnthropicBaseUrl
    $AnthropicApiKey  = Read-Value "  Anthropic / Foundry API key (blank = fill provider POC key in deploy-aci)" $AnthropicApiKey
}

# Teams (not auto-retrievable). Gated by -TeamsMode:
#   full         - prompt for all three (posting + report delivery + reply-polling).
#   webhook_only - prompt for the webhook only; team_id/channel_id stay blank on
#                  purpose -- they're only used for reply-polling, which cannot work
#                  cross-tenant (see -TeamsMode's doc comment). Report delivery still
#                  works fully in this mode; it needs no team_id/channel_id at all.
#   none         - no Teams at all; all three stay blank, no prompt.
if ($TeamsMode -eq "none") {
    Write-Info "Teams disabled (-TeamsMode none) -- skipping Teams prompts."
    $TeamsWebhookUrl = ""
    $TeamsTeamId     = ""
    $TeamsChannelId  = ""
} else {
    Write-Host ""
    if ($TeamsMode -eq "webhook_only") {
        Write-Host "  Teams output (posting + report delivery -- webhook_url; -TeamsMode webhook_only leaves team_id/channel_id blank):" -ForegroundColor Cyan
        $TeamsWebhookUrl = Read-Value "  Teams Workflows webhook URL" $TeamsWebhookUrl
        $TeamsTeamId     = ""
        $TeamsChannelId  = ""
    } else {
        Write-Host "  Teams output (from the channel's Workflows webhook + channel URL; blank to disable):" -ForegroundColor Cyan
        $TeamsWebhookUrl = Read-Value "  Teams Workflows webhook URL" $TeamsWebhookUrl
        $TeamsTeamId     = Read-Value "  Teams team/group ID (GUID)"   $TeamsTeamId
        $TeamsChannelId  = Read-Value "  Teams channel ID (19:...@thread.tacv2)" $TeamsChannelId
    }
}

# Enrichment (optional)
Write-Host ""
Write-Host "  Threat-intel enrichment keys (optional; blank to disable):" -ForegroundColor Cyan
$VirusTotalApiKey = Read-Value "  VirusTotal API key"  $VirusTotalApiKey
$AbuseIpDbApiKey  = Read-Value "  AbuseIPDB API key"   $AbuseIpDbApiKey
$IpInfoToken      = Read-Value "  IPinfo token"        $IpInfoToken

# Bootstrap / control server override (optional - only for pointing this deploy at a
# non-default soc-server, e.g. one from deploy-server-aci.ps1; blank = use
# deploy-aci.ps1's PROVIDER section default)
Write-Host ""
Write-Host "  Control server override (optional; blank = use deploy-aci.ps1's default):" -ForegroundColor Cyan
$BootstrapUrl       = Read-Value "  Bootstrap URL (e.g. https://<soc-server-fqdn>)" $BootstrapUrl
$BootstrapToken     = Read-Value "  Bootstrap token"                               $BootstrapToken
$BootstrapTlsVerify = Read-Value "  Bootstrap TLS verify (true/false/CA path)"     $BootstrapTlsVerify

# ACR pull-token password (optional - see .PARAMETER AcrPullPassword). Blank = leave it
# for deploy-aci.ps1 to prompt for interactively instead; never written to deploy-aci.ps1
# itself, only to this tenant's own gitignored config file below.
Write-Host ""
Write-Host "  ACR pull-token password (optional; blank = deploy-aci.ps1 prompts for it instead):" -ForegroundColor Cyan
$AcrPullPassword = Read-Value "  ACR pull-token password" $AcrPullPassword

# ---------------------------------------------------------------------------
# write config file consumed by deploy-aci.ps1
# ---------------------------------------------------------------------------
$resolvedConfigPath = Write-DeployConfig -IsDryRun:$DryRun `
    -AppId        $app.appId `
    -ObjectId     $sp.id `
    -ClientSecret $ClientSecret `
    -SecretExpiry $SecretExpiry

# ---------------------------------------------------------------------------
# summary
# ---------------------------------------------------------------------------
$sep = "=" * 64
$banner = if ($DryRun) { "DRY RUN -- PREVIEW CONFIG WRITTEN (no changes made)" } else { "TENANT PREPARED" }
$bannerColor = if ($DryRun) { "Magenta" } else { "Green" }
Write-Host ""
Write-Host $sep -ForegroundColor $bannerColor
Write-Host $banner -ForegroundColor $bannerColor
Write-Host $sep -ForegroundColor $bannerColor
Write-Host ""
Write-Host "  Config written: $resolvedConfigPath"
Write-Host "  App name      : $AppName"
Write-Host "  appId         : $($app.appId)"
Write-Host "  objectId      : $($sp.id)"
Write-Host "  Secret expiry : $SecretExpiry"
Write-Host "  Case backend  : $CaseBackend"
Write-Host "  Tenant SKU    : $TenantSku (SIEM query routing)"
Write-Host "  Graph perms   : $($RequiredGraphPermissions.Count) requested ($($RequiredGraphPermissions -join ', '))"
if (-not $SentinelWorkspaceId) { Write-Host "  Sentinel      : (skipped - assign Reader/Responder roles manually if added later)" -ForegroundColor Yellow }
if ($SentinelWorkspaceId -and -not $LogAnalyticsWorkspaceKey -and -not $DryRun) { Write-Host "  ACI logging   : (shared key retrieval failed - add LogAnalyticsWorkspaceKey to config manually)" -ForegroundColor Yellow }
if ($SentinelWorkspaceId -and -not $DryRun) {
    if ($XdrDcrRuleId) { Write-Host "  Audit DCR     : configured ($XdrDcrRuleId)" } else { Write-Host "  Audit DCR     : (not configured - internal audit will be JSONL-only; see warnings above)" -ForegroundColor Yellow }
}
if ($LlmBackend -eq "azure_openai") {
    if (-not $AzureOpenAiApiKey -or -not $AzureOpenAiEndpoint) {
        Write-Host "  Inference     : azure_openai (endpoint or key blank - provide before/at deploy time)" -ForegroundColor Yellow
    }
} elseif (-not $AnthropicApiKey) {
    Write-Host "  Inference key : (blank - provide before/at deploy time)" -ForegroundColor Yellow
}
Write-Host "  Teams mode    : $TeamsMode"
if ($TeamsMode -ne "none" -and -not $TeamsWebhookUrl) { Write-Host "  Teams         : (disabled - no webhook provided)" -ForegroundColor Yellow }
if ($BootstrapUrl) { Write-Host "  Bootstrap     : override -> $BootstrapUrl (deploy-aci.ps1 PROVIDER default overridden)" -ForegroundColor Yellow }
if ($AcrPullPassword) { Write-Host "  ACR password  : supplied -- deploy-aci.ps1 will not prompt for it" } else { Write-Host "  ACR password  : not supplied -- deploy-aci.ps1 will prompt for it (unless -NonInteractive there too)" -ForegroundColor Yellow }
Write-Host ""
if ($DryRun) {
    Write-Host "  Next: re-run WITHOUT -DryRun to provision and write real appId/objectId/secret." -ForegroundColor Magenta
} else {
    Write-Host "  Next: send the agent the EasySOC deploy-aci.ps1, place it next to the config"
    Write-Host "        file above, and run:  .\deploy-aci.ps1"
}
Write-Host ""
Write-Host $sep -ForegroundColor $bannerColor
if ($DryRun) {
    Write-Warning "Preview only: appId/objectId/secret are DRY-RUN placeholders; discovered Sentinel/Foundry values ARE real. This config is NOT deployable as-is."
} else {
    Write-Warning "The client secret and any keys are stored in plaintext in the config file. Protect/delete it after deployment."
    Write-Warning "Secret rotation: rerun this script; then delete the previous credential from the app registration in the portal."
}
