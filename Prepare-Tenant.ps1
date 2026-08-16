<#
.SYNOPSIS
    Prepares a Microsoft 365 / Azure tenant for EasySOC (AgenticSOC) and writes a
    ready-to-deploy config file for deploy-aci.ps1.

.DESCRIPTION
    Single, unified tenant-preparation script (replaces the former Prepare-Tenant.ps1
    + Prepare-Tenant-POC.ps1 pair). It:

      1. Verifies Azure CLI auth and selects the subscription (auto-detected; prompts
         only when more than one exists).
      2. Creates an Entra ID app registration + service principal with the 12 Microsoft
         Graph application permissions the agent needs, grants admin consent, and creates
         a client secret.
      3. Provisions an Azure Storage account + Azure Files share for the audit volume.
      4. Discovers the Sentinel / Log Analytics workspace and assigns the Microsoft
         Sentinel Reader role (prompts only when more than one workspace exists).
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

    [string]$ConfigOutPath = ".\easysoc-deploy.config.ps1",

    [switch]$NonInteractive,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$AppName    = "AgenticSOC-$CustomerId"
$GraphAppId = "00000003-0000-0000-c000-000000000000"

# Microsoft Graph application permissions (all type Application; no user delegation).
# This is the assessed minimal set for the XDR-native deployment (Tenant Prerequisites v3).
# NOTE: the previously requested *separate* SharePoint Online Sites.ReadWrite.All
# (resource 00000003-0000-0ff1-ce00-...) is intentionally NOT requested - it was a
# leftover from the retired SP-Lists native-comments REST path. Report uploads use the
# Graph Sites.ReadWrite.All below against the Teams channel's Shared Documents drive.
$RequiredGraphPermissions = @(
    "SecurityAlert.Read.All",        # Defender XDR + M365 security alerts (read)
    "SecurityAlert.ReadWrite.All",   # write alert status/comments
    "SecurityIncident.Read.All",     # read XDR incidents
    "SecurityIncident.ReadWrite.All",# write comments/tags/classification to XDR incidents
    "ThreatHunting.Read.All",        # Advanced Hunting API (Device* tables)
    "IdentityRiskEvent.Read.All",    # Entra risky sign-in events
    "AuditLog.Read.All",             # sign-in logs for identity analysis
    "User.Read.All",                 # user profile details for context resolver
    "Directory.Read.All",            # group membership, role assignments, CA policies
    "GroupMember.Read.All",          # group membership resolution
    "ChannelMessage.Read.All",       # read Teams channel messages for feedback loop
    "Sites.ReadWrite.All"            # upload investigation report HTML to Teams Shared Documents
)

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

# Application
`$SocCustomerId        = "$CustomerId"
`$SocCaseBackend       = "xdr"
`$MsTenantId           = "$TenantId"
`$MsClientId           = "$AppId"
`$MsClientSecret       = "$ClientSecret"
`$MsSubscriptionId     = "$SubscriptionId"

# Sentinel
`$MsSentinelWorkspace  = "$SentinelWorkspaceId"

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

    $existingSa = $null
    try {
        $existingSa = az storage account show --name $StorageAccountName --resource-group $ResourceGroup 2>$null | ConvertFrom-Json
    } catch {}
    if ($existingSa) {
        Write-Skip "storage account '$StorageAccountName'"
    } else {
        az storage account create --name $StorageAccountName --resource-group $ResourceGroup `
            --location $Location --sku "Standard_LRS" --kind "StorageV2" `
            --allow-blob-public-access false --min-tls-version "TLS1_2" | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Storage account creation failed (check Contributor on '$ResourceGroup')." }
        Write-Ok "Storage account created"
    }

    $storageKey = az storage account keys list --account-name $StorageAccountName `
        --resource-group $ResourceGroup --query "[0].value" --output tsv
    if ($LASTEXITCODE -ne 0 -or -not $storageKey) { throw "Failed to retrieve storage account key for '$StorageAccountName'." }

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
        Write-Warning "Could not resolve workspace ARM ID for customerId '$SentinelWorkspaceId'. Assign the Sentinel Reader role manually."
    } elseif ($DryRun) {
        Write-Info "DRY RUN: would assign 'Microsoft Sentinel Reader' to the service principal on $workspaceArmId."
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
    }
}

# Step 8: Foundry inference endpoint + non-retrievable prompts
Write-Step "8/8" "Inference endpoint, Teams, and enrichment configuration"

# Resolve effective backend (blank => anthropic)
if (-not $LlmBackend) { $LlmBackend = "anthropic" }

# Azure AI Foundry / Cognitive Services discovery (best effort).
# Runs when the relevant key for the chosen backend is not yet supplied.
$_needsDiscovery = ($LlmBackend -eq "anthropic" -and -not $AnthropicApiKey) -or
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
        }
    } else {
        Write-Info "No Azure AI Foundry / OpenAI resource found in this subscription."
    }
}

# Confirm / prompt inference values for the chosen backend
$LlmBackend = Read-Value "  LLM backend (anthropic / azure_openai)" $LlmBackend
if ($LlmBackend -eq "azure_openai") {
    $AzureOpenAiEndpoint   = Read-Value "  Azure OpenAI endpoint" $AzureOpenAiEndpoint
    $AzureOpenAiApiKey     = Read-Value "  Azure OpenAI API key" $AzureOpenAiApiKey
    $AzureOpenAiDeployment = Read-Value "  Azure OpenAI deployment name (e.g. gpt-5.4)" $AzureOpenAiDeployment
} else {
    $LlmBackend       = "anthropic"
    $AnthropicBaseUrl = Read-Value "  Anthropic base URL (blank = public api.anthropic.com)" $AnthropicBaseUrl
    $AnthropicApiKey  = Read-Value "  Anthropic / Foundry API key (blank = fill provider POC key in deploy-aci)" $AnthropicApiKey
}

# Teams (not auto-retrievable)
Write-Host ""
Write-Host "  Teams output (from the channel's Workflows webhook + channel URL; blank to disable):" -ForegroundColor Cyan
$TeamsWebhookUrl = Read-Value "  Teams Workflows webhook URL" $TeamsWebhookUrl
$TeamsTeamId     = Read-Value "  Teams team/group ID (GUID)"   $TeamsTeamId
$TeamsChannelId  = Read-Value "  Teams channel ID (19:...@thread.tacv2)" $TeamsChannelId

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
if (-not $SentinelWorkspaceId) { Write-Host "  Sentinel      : (skipped - assign Reader role manually if added later)" -ForegroundColor Yellow }
if ($LlmBackend -eq "azure_openai") {
    if (-not $AzureOpenAiApiKey -or -not $AzureOpenAiEndpoint) {
        Write-Host "  Inference     : azure_openai (endpoint or key blank - provide before/at deploy time)" -ForegroundColor Yellow
    }
} elseif (-not $AnthropicApiKey) {
    Write-Host "  Inference key : (blank - provide before/at deploy time)" -ForegroundColor Yellow
}
if (-not $TeamsWebhookUrl)     { Write-Host "  Teams         : (disabled - no webhook provided)" -ForegroundColor Yellow }
if ($BootstrapUrl) { Write-Host "  Bootstrap     : override -> $BootstrapUrl (deploy-aci.ps1 PROVIDER default overridden)" -ForegroundColor Yellow }
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
