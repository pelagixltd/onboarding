# Deploy soc-agent to Azure Container Instances.
#
# Workflow:
#   1. Partner runs Prepare-Tenant.ps1 in the customer tenant -> it writes
#      easysoc-deploy.config.ps1 (all customer values + secrets).
#   2. The ACR pull-token password (below) never lives in this script -- it's the
#      same file synced verbatim to the public partner onboarding repo. Supply it
#      either as a $AcrPullPassword line in the tenant-specific easysoc-deploy.config.ps1
#      (gitignored, per-deployment, never public), or leave it out entirely and this
#      script prompts for it interactively at deploy time (unless -NonInteractive).
#   3. Partner places this script next to the config file and runs:  .\deploy-aci.ps1
#
# This script dot-sources the config file for every customer-specific value, so the
# only manual edits normally needed live in the config file, never in this script.

param(
    # Config file produced by Prepare-Tenant.ps1 (dot-sourced for all customer values).
    [string]$ConfigFile = (Join-Path $PSScriptRoot "easysoc-deploy.config.ps1"),

    # Never prompt (including for a missing AcrPullPassword) -- fail instead. For CI/pipelines.
    [switch]$NonInteractive
)

# ============================================================
# PROVIDER SECTION - filled once by EasySOC (constant across customers)
# ============================================================

# Go port publishes to easysoccr (see server/scripts/deploy-server-aci.ps1's
# PROVIDER section comment for why: a separate registry from the retired
# Python-era easysoc.azurecr.io, which no longer exists in this
# subscription -- confirmed via `az acr show -n easysoc` returning
# ResourceNotFound 2026-09-05). Pull token+scope-map (confirmed live via
# `az acr token list -r easysoccr` / an oauth2/token 200 check, same as
# soc-server's) are named "soc-agent" / "soc-agent-scope" -- if the token is
# ever recreated:
#   az acr scope-map create -n soc-agent-scope -r easysoccr --repository soc-agent content/read
#   az acr token create -n soc-agent -r easysoccr --scope-map soc-agent-scope   # capture password1 once
$AcrLoginServer  = "easysoccr-gyfwc2acakhmg5h0.azurecr.io"
$AcrPullUser     = "soc-agent"
$AcrPullPassword = ""          # ACR pull token password -- do NOT paste a real value here.
                               # This file (deploy-aci.ps1) is synced verbatim to the public
                               # partner onboarding repo -- never hardcode a secret into it.
                               # Supply it instead via the tenant-specific easysoc-deploy.config.ps1
                               # (dot-sourced below; a $AcrPullPassword line there overrides this
                               # blank default and never leaves the local machine), or leave both
                               # blank and this script will prompt for it interactively at deploy
                               # time (unless -NonInteractive).

# EasySOC control endpoint (licensing / prompt delivery / telemetry).
# $BootstrapUrl + $BootstrapTlsVerify are constant across customers.
# $BootstrapToken is the PER-TENANT license token EasySOC issues for THIS customer
# (paste it per deployment, like $AcrPullPassword). Leave blank ONLY for local/dev
# deploys with no control server -> license enforcement is then DISABLED (fail-open).
#
# api.easysoc.pro is the soc-server custom domain in front of Azure Front
# Door (see server/scripts/setup-server-custom-domain.ps1 /
# setup-server-frontdoor.ps1) -- replaced the old
# easysoc-bootstrap-poc.southeastasia.azurecontainer.io raw-ACI POC
# endpoint, which this script had never been updated off of. Front Door
# terminates TLS with its own Microsoft-managed certificate, so
# $BootstrapTlsVerify can use the secure "true" default rather than the
# dev-only "false" the stale POC endpoint required. Confirmed live
# 2026-09-05 (resolves through Front Door, responds over HTTPS).
$BootstrapUrl       = "https://api.easysoc.pro"
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
$SiemTenantSku       = "business_premium"   # business_premium | mde_sentinel | sentinel_only
$MsSubscriptionId    = ""
$MsSentinelWorkspace = ""
# Resource group the storage account itself lives in -- normally the same as
# $ResourceGroup below, but Prepare-Tenant.ps1 sets this distinctly when it found
# and reused an existing storage account in a different resource group (storage
# account names are globally unique across Azure, so this can legitimately diverge).
# Blank here (an older config file, or a config written before this field existed)
# falls back to $ResourceGroup after the config file is loaded, below.
$StorageResourceGroup = ""
# Sentinel case backend (only used when $SocCaseBackend = "sentinel")
$MsSentinelResourceGroup     = ""   # Sentinel workspace's own resource group (NOT $ResourceGroup -- see note below)
$MsSentinelWorkspaceName     = ""   # Sentinel workspace's ARM name (not the GUID -- that's $MsSentinelWorkspace above)
$MsSentinelSpObjectId        = ""   # agent app registration's service-principal OBJECT id (az ad sp show --id ... --query id)
# ACI container-log integration (Azure Portal doesn't support this for this container's
# config - secure env vars + a volume mount - so it must be set here, at deploy time).
# Populated by Prepare-Tenant.ps1 from the same workspace as $MsSentinelWorkspace above.
$LogAnalyticsWorkspaceId  = ""
$LogAnalyticsWorkspaceKey = ""
# Anthropic backend (llm_backend: anthropic)
$AnthropicBaseUrl    = ""
$AnthropicApiKey     = ""
# Azure OpenAI backend (llm_backend: azure_openai)
$LlmBackend          = ""           # "anthropic" (default) | "azure_openai"
$AzureOpenAiApiKey   = ""
$AzureOpenAiEndpoint = ""
$AzureOpenAiDeployment = ""
$AzureOpenAiApi      = ""           # "" = chat_completions | "responses" (required for gpt-6-sol)
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

# ACR pull-token password: PROVIDER section default (blank as shipped) or the config
# file's $AcrPullPassword (set above by `. $ConfigFile`) may already have supplied it.
# If not, and this isn't a non-interactive/CI run, prompt for it now rather than
# require editing this script -- see the header comment for why that's the wrong place
# for a real secret to live.
if (-not $AcrPullPassword -and -not $NonInteractive) {
    $secure = Read-Host -Prompt "ACR pull-token password" -AsSecureString
    $AcrPullPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure))
}

# ----- validate required -----
if (-not $AcrPullPassword)  { throw "AcrPullPassword is required -- set it in easysoc-deploy.config.ps1, or omit -NonInteractive to be prompted." }
if (-not $SocCustomerId)    { throw "SocCustomerId is required (config file)." }
if (-not $MsTenantId)       { throw "MsTenantId is required (config file)." }
if (-not $MsClientId)       { throw "MsClientId is required (config file)." }
if (-not $MsClientSecret)   { throw "MsClientSecret is required (config file)." }
$_effectiveBackend = if ($LlmBackend -and -not $LlmBackend.StartsWith('$')) { $LlmBackend } else { "anthropic" }
if ($_effectiveBackend -eq "anthropic" -and -not $AnthropicApiKey) {
    throw "AnthropicApiKey is required when llm_backend=anthropic - set it in the config file (Foundry) or the PROVIDER section."
}
if ($_effectiveBackend -eq "azure_openai" -and (-not $AzureOpenAiApiKey -or -not $AzureOpenAiEndpoint)) {
    throw "AzureOpenAiApiKey and AzureOpenAiEndpoint are required when llm_backend=azure_openai."
}
if (-not $StorageAccount)   { throw "StorageAccount is required (config file)." }
if (-not $ResourceGroup)    { throw "ResourceGroup is required (config file)." }
if (-not $StorageResourceGroup) { $StorageResourceGroup = $ResourceGroup }

# License enforcement: warn (don't block) if the per-tenant token is missing - the
# container fail-opens when url/token are blank, so this would silently disable licensing.
if (-not $BootstrapToken -or -not $BootstrapUrl) {
    Write-Warning "BootstrapToken/BootstrapUrl not set (PROVIDER section) - LICENSE ENFORCEMENT WILL BE DISABLED for this deployment."
}

Write-Host "    Customer : $SocCustomerId"
Write-Host "    Backend  : $SocCaseBackend"
Write-Host "    RG       : $ResourceGroup ($Location)"
Write-Host "    License  : $(if ($BootstrapToken -and $BootstrapUrl) { "enforced ($BootstrapUrl)" } else { 'DISABLED' })"

# Ensure ACI provider is registered (no-op if already registered)
Write-Host "==> Registering Microsoft.ContainerInstance provider ..."
az provider register --namespace Microsoft.ContainerInstance --wait

# Resolve storage key
Write-Host "==> Fetching storage key for $StorageAccount (rg=$StorageResourceGroup) ..."
$StorageKey = az storage account keys list `
    --resource-group $StorageResourceGroup `
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

# Built as a YAML manifest + `az container create --file`, NOT inline
# --environment-variables/--secure-environment-variables CLI arguments.
# `az` on Windows is az.cmd, a batch-file wrapper; an inline argument value
# containing an unescaped `&` (e.g. a Power Automate/Logic App webhook URL's
# `?api-version=1&sp=...&sv=...&sig=...` SAS query string) gets re-split by
# cmd.exe as a command separator, silently truncating the real `az container
# create` invocation at that point -- everything after it in the argument
# list (further env vars, the volume mount, --command-line, --output none)
# never reaches az at all. deploy-server-aci.ps1 already avoids this the
# same way; confirmed live 2026-09-05 (a deploy with the old inline-args
# form silently produced a container with no volume mount and no Log
# Analytics wiring, both listed after the webhook URL in the argument
# order, while everything before it in the list came through fine).
#
# ACI container-log integration is only settable at container-group creation
# (Portal and CLI can't add it after the fact), and only when both a
# workspace ID and its shared key are present -- passing one without the
# other errors out.
$diagnostics = ""
if ($LogAnalyticsWorkspaceId -and $LogAnalyticsWorkspaceKey) {
    $diagnostics = @"
  diagnostics:
    logAnalytics:
      workspaceId: "$LogAnalyticsWorkspaceId"
      workspaceKey: "$LogAnalyticsWorkspaceKey"
"@
    Write-Host "    Log Analytics logging: enabled ($LogAnalyticsWorkspaceId)"
} else {
    Write-Host "    Log Analytics logging: disabled (no workspace configured)"
}

# Mount path matches where the Go agent actually resolves audit_log_dir:
# cfgPath(configDir, config, "audit_log_dir", "audit") in
# agent/cmd/agent/run.go resolves relative to config.yaml's own directory
# (/app/config, since the container's config.yaml lives at
# /app/config/config.yaml -- see agent/Dockerfile), giving /app/config/audit
# -- NOT /app/audit, which this script mounted at until 2026-09-05 (a
# pre-existing mismatch: audit data, including customer_facts.json, was
# silently landing on ephemeral container storage instead of the persistent
# Azure Files share).
$work = Join-Path ([IO.Path]::GetTempPath()) ("soc-agent-deploy-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $work -Force | Out-Null
try {
    $yaml = @"
apiVersion: 2019-12-01
location: $Location
name: $ContainerName
type: Microsoft.ContainerInstance/containerGroups
properties:
  osType: Linux
  restartPolicy: Always
  imageRegistryCredentials:
  - server: $AcrLoginServer
    username: $AcrPullUser
    password: "$AcrPullPassword"
$diagnostics
  containers:
  - name: $ContainerName
    properties:
      image: $Image
      resources: { requests: { cpu: $Cpu, memoryInGB: $Memory } }
      command: ["/app/agent", "--config", "config/config.yaml", "--log-level", "$LogLevel"]
      environmentVariables:
      - { name: SOC_CUSTOMER_ID, value: "$SocCustomerId" }
      - { name: SOC_CASE_BACKEND, value: "$SocCaseBackend" }
      - { name: SIEM_TENANT_SKU, value: "$SiemTenantSku" }
      # Points config.yaml's auto_close_patterns/pre_enrichment_bundles at the
      # already-mounted Azure Files share (below) instead of the image's own
      # baked-in copy -- these are customer-tunable business rules, not product
      # logic, and a partner/customer editing them shouldn't need a redeploy.
      # Fixed container-internal paths, not a per-customer value -- same class
      # as the volume mountPath itself, not something Prepare-Tenant.ps1 sets.
      # Starts empty (no seeding) until a file is uploaded to the share; a
      # container restart picks up an edit (no hot-reload). See
      # Implementation/Go Agent Config Directory — Common vs Customer-Specific
      # Audit v3 in the project vault.
      - { name: AUTO_CLOSE_PATTERNS_PATH, value: "/app/config/audit/auto_close_patterns.yaml" }
      - { name: PRE_ENRICHMENT_BUNDLES_PATH, value: "/app/config/audit/pre_enrichment_bundles.yaml" }
      - { name: MS_TENANT_ID, value: "$MsTenantId" }
      - { name: MS_CLIENT_ID, value: "$MsClientId" }
      - { name: MS_SUBSCRIPTION_ID, value: "$MsSubscriptionId" }
      - { name: MS_SENTINEL_RESOURCE_GROUP, value: "$MsSentinelResourceGroup" }
      - { name: MS_SENTINEL_WORKSPACE_NAME, value: "$MsSentinelWorkspaceName" }
      - { name: SP_SITE_URL, value: "$SpSiteUrl" }
      - { name: SP_LIST_ID, value: "$SpListId" }
      - { name: SP_LIST_NAME, value: "$SpListName" }
      - { name: TEAMS_TEAM_ID, value: "$TeamsTeamId" }
      - { name: TEAMS_CHANNEL_ID, value: "$TeamsChannelId" }
      - { name: XDR_DCR_ENDPOINT, value: "$XdrDcrEndpoint" }
      - { name: XDR_DCR_RULE_ID, value: "$XdrDcrRuleId" }
      - { name: MS_SENTINEL_SP_OBJECT_ID, value: "$MsSentinelSpObjectId" }
      - { name: ANTHROPIC_BASE_URL, value: "$AnthropicBaseUrl" }
      - { name: LLM_BACKEND, value: "$LlmBackend" }
      - { name: AZURE_OPENAI_ENDPOINT, value: "$AzureOpenAiEndpoint" }
      - { name: AZURE_OPENAI_DEPLOYMENT, value: "$AzureOpenAiDeployment" }
      - { name: AZURE_OPENAI_API, value: "$AzureOpenAiApi" }
      - { name: BOOTSTRAP_URL, value: "$BootstrapUrl" }
      - { name: BOOTSTRAP_TLS_VERIFY, value: "$BootstrapTlsVerify" }
      - { name: ANTHROPIC_API_KEY, secureValue: "$AnthropicApiKey" }
      - { name: AZURE_OPENAI_API_KEY, secureValue: "$AzureOpenAiApiKey" }
      - { name: BOOTSTRAP_TOKEN, secureValue: "$BootstrapToken" }
      - { name: MS_CLIENT_SECRET, secureValue: "$MsClientSecret" }
      - { name: MS_SENTINEL_WORKSPACE, secureValue: "$MsSentinelWorkspace" }
      - { name: TEAMS_WEBHOOK_URL, secureValue: "$TeamsWebhookUrl" }
      - { name: VIRUSTOTAL_API_KEY, secureValue: "$VirusTotalApiKey" }
      - { name: ABUSEIPDB_API_KEY, secureValue: "$AbuseIpDbApiKey" }
      - { name: IPINFO_TOKEN, secureValue: "$IpInfoToken" }
      volumeMounts:
      - { name: audit, mountPath: /app/config/audit }
  volumes:
  - name: audit
    azureFile:
      shareName: $FileShare
      storageAccountName: $StorageAccount
      storageAccountKey: "$StorageKey"
"@
    $yamlPath = Join-Path $work "soc-agent-aci.yaml"
    Set-Content -Path $yamlPath -Value $yaml -Encoding ascii

    az container create --resource-group $ResourceGroup --file $yamlPath --output none
    if ($LASTEXITCODE -ne 0) { throw "az container create failed (exit code $LASTEXITCODE). See error above." }
}
finally {
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}

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
