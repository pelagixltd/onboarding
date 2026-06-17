# Deploy soc-agent to Azure Container Instances.
#
# Workflow:
#   1. Partner runs Prepare-Tenant.ps1 in the customer tenant -> it writes
#      easysoc-deploy.config.ps1 (all customer values + secrets).
#   2. EasySOC fills in the PROVIDER section below ONCE (ACR creds, image tag).
#   3. Partner places this script next to the config file and runs:  .\deploy-aci.ps1
#
# This script dot-sources the config file for every customer-specific value, so the
# only manual edits live in the PROVIDER section below.

param(
    # Config file produced by Prepare-Tenant.ps1 (dot-sourced for all customer values).
    [string]$ConfigFile = (Join-Path $PSScriptRoot "easysoc-deploy.config.ps1")
)

# ============================================================
# PROVIDER SECTION - filled once by EasySOC (constant across customers)
# ============================================================

$AcrLoginServer  = "easysoc.azurecr.io"
$AcrPullUser     = "partner-poc"
$AcrPullPassword = ""          # ACR pull token password

# EasySOC control endpoint (licensing / prompt delivery / telemetry).
# $BootstrapUrl + $BootstrapTlsVerify are constant across customers.
# $BootstrapToken is the PER-TENANT license token EasySOC issues for THIS customer
# (paste it per deployment, like $AcrPullPassword). Leave blank ONLY for local/dev
# deploys with no control server -> license enforcement is then DISABLED (fail-open).
$BootstrapUrl       = "https://api.easysoc.io"
$BootstrapToken     = ""        # per-tenant license token (provided by EasySOC)
$BootstrapTlsVerify = "true"    # "true" | "false" (dev only) | path to CA bundle

$ImageTag        = "latest"
$LogLevel        = "INFO"      # DEBUG for verbose diagnostics

$Cpu             = 1
$Memory          = 1.5

# POC fallback inference key - used ONLY if the config file leaves $AnthropicApiKey blank
# (i.e. no customer Azure AI Foundry endpoint). Leave blank to require a config-supplied key.
$ProviderAnthropicApiKey = ""

# ============================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ----- defaults for optional values (config file may override) -----
$ContainerName       = "soc-agent"
$SocCaseBackend      = "xdr"
$MsSubscriptionId    = ""
$MsSentinelWorkspace = ""
$AnthropicBaseUrl    = ""
$AnthropicApiKey     = ""
$TeamsWebhookUrl     = ""
$TeamsTeamId         = ""
$TeamsChannelId      = ""
$VirusTotalApiKey    = ""
$AbuseIpDbApiKey     = ""
$IpInfoToken         = ""
# SharePoint backend (only when $SocCaseBackend = "sharepoint")
$SpSiteUrl           = ""
$SpListId            = ""
$SpListName          = ""
# XDR audit Log Analytics DCR (optional)
$XdrDcrEndpoint      = ""
$XdrDcrRuleId        = ""

# ----- load customer config -----
if (-not (Test-Path $ConfigFile)) {
    throw "Config file not found: $ConfigFile`nRun Prepare-Tenant.ps1 first, or pass -ConfigFile <path>."
}
Write-Host "==> Loading config: $ConfigFile"
. $ConfigFile

# POC fallback: if no Foundry key in config, use the provider key.
if (-not $AnthropicApiKey) { $AnthropicApiKey = $ProviderAnthropicApiKey }

# ----- validate required -----
if (-not $AcrPullPassword)  { throw "AcrPullPassword is required (PROVIDER section)." }
if (-not $SocCustomerId)    { throw "SocCustomerId is required (config file)." }
if (-not $MsTenantId)       { throw "MsTenantId is required (config file)." }
if (-not $MsClientId)       { throw "MsClientId is required (config file)." }
if (-not $MsClientSecret)   { throw "MsClientSecret is required (config file)." }
if (-not $AnthropicApiKey)  { throw "AnthropicApiKey is required - set it in the config file (Foundry) or the PROVIDER section." }
if (-not $StorageAccount)   { throw "StorageAccount is required (config file)." }
if (-not $ResourceGroup)    { throw "ResourceGroup is required (config file)." }

# License enforcement: warn (don't block) if the per-tenant token is missing — the
# container fail-opens when url/token are blank, so this would silently disable licensing.
if (-not $BootstrapToken -or -not $BootstrapUrl) {
    Write-Warning "BootstrapToken/BootstrapUrl not set (PROVIDER section) — LICENSE ENFORCEMENT WILL BE DISABLED for this deployment."
}

Write-Host "    Customer : $SocCustomerId"
Write-Host "    Backend  : $SocCaseBackend"
Write-Host "    RG       : $ResourceGroup ($Location)"
Write-Host "    License  : $(if ($BootstrapToken -and $BootstrapUrl) { "enforced ($BootstrapUrl)" } else { 'DISABLED' })"

# Ensure ACI provider is registered (no-op if already registered)
Write-Host "==> Registering Microsoft.ContainerInstance provider ..."
az provider register --namespace Microsoft.ContainerInstance --wait

# Resolve storage key
Write-Host "==> Fetching storage key for $StorageAccount ..."
$StorageKey = az storage account keys list `
    --resource-group $ResourceGroup `
    --account-name $StorageAccount `
    --query "[0].value" -o tsv

# Delete existing instance (ACI does not support in-place image updates)
$existing = $null
try { $existing = az container show --resource-group $ResourceGroup --name $ContainerName --query "name" -o tsv 2>$null } catch {}
if ($LASTEXITCODE -eq 0 -and $existing) {
    Write-Host "==> Deleting existing container instance: $ContainerName"
    az container delete --resource-group $ResourceGroup --name $ContainerName --yes
}

# Deploy
$Image = "$AcrLoginServer/soc-agent:$ImageTag"
Write-Host "==> Deploying $Image to ACI ($ResourceGroup / $ContainerName) ..."

az container create `
    --resource-group $ResourceGroup `
    --name $ContainerName `
    --image $Image `
    --registry-login-server $AcrLoginServer `
    --registry-username $AcrPullUser `
    --registry-password $AcrPullPassword `
    --restart-policy Always `
    --cpu $Cpu `
    --memory $Memory `
    --os-type Linux `
    --location $Location `
    --environment-variables `
        SOC_CUSTOMER_ID="$SocCustomerId" `
        SOC_CASE_BACKEND="$SocCaseBackend" `
        MS_TENANT_ID="$MsTenantId" `
        MS_CLIENT_ID="$MsClientId" `
        MS_SUBSCRIPTION_ID="$MsSubscriptionId" `
        SP_SITE_URL="$SpSiteUrl" `
        SP_LIST_ID="$SpListId" `
        SP_LIST_NAME="$SpListName" `
        TEAMS_TEAM_ID="$TeamsTeamId" `
        TEAMS_CHANNEL_ID="$TeamsChannelId" `
        XDR_DCR_ENDPOINT="$XdrDcrEndpoint" `
        XDR_DCR_RULE_ID="$XdrDcrRuleId" `
        ANTHROPIC_BASE_URL="$AnthropicBaseUrl" `
        BOOTSTRAP_URL="$BootstrapUrl" `
        BOOTSTRAP_TLS_VERIFY="$BootstrapTlsVerify" `
    --secure-environment-variables `
        ANTHROPIC_API_KEY="$AnthropicApiKey" `
        BOOTSTRAP_TOKEN="$BootstrapToken" `
        MS_CLIENT_SECRET="$MsClientSecret" `
        MS_SENTINEL_WORKSPACE="$MsSentinelWorkspace" `
        TEAMS_WEBHOOK_URL="$TeamsWebhookUrl" `
        VIRUSTOTAL_API_KEY="$VirusTotalApiKey" `
        ABUSEIPDB_API_KEY="$AbuseIpDbApiKey" `
        IPINFO_TOKEN="$IpInfoToken" `
    --azure-file-volume-account-name $StorageAccount `
    --azure-file-volume-account-key $StorageKey `
    --azure-file-volume-share-name $FileShare `
    --azure-file-volume-mount-path /app/audit `
    --command-line "soc-agent --config /app/config/config.yaml --log-level $LogLevel" `
    --output none

Write-Host ""
Write-Host "==> Container created. Waiting 10 seconds for startup ..."
Start-Sleep -Seconds 10

# Show container state
$state = az container show `
    --resource-group $ResourceGroup `
    --name $ContainerName `
    --query "containers[0].instanceView.currentState" -o json | ConvertFrom-Json

Write-Host "==> Status: $($state.state) - $($state.detailStatus)"
if ($state.exitCode) { Write-Host "    Exit code: $($state.exitCode)" }

# Show startup logs
Write-Host ""
Write-Host "==> Startup logs:"
az container logs --resource-group $ResourceGroup --name $ContainerName

Write-Host ""
Write-Host "==> To follow live logs:"
Write-Host "    az container logs -g $ResourceGroup -n $ContainerName --follow"
