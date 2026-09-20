# EasySOC — Partner Tenant Preparation Guide v17

> **Audience:** Partner technical engineer
> **Purpose:** The engineering run procedure — prepare a customer tenant and deploy the agent container using the two provided scripts (`Prepare-Tenant.ps1` + `deploy-aci.ps1`)
> **Scope:** Procedure only. This guide assumes the tenant is already ready.
> - Tenant readiness (resources/licenses/services + pre-flight checklist) → **[Tenant Prerequisites](./Tenant%20Prerequisites.md)**
> - What the agent can access, what leaves the tenant, app permissions, egress → **[Tenant Data Sovereignty and Access](./Tenant%20Data%20Sovereignty%20and%20Access.md)**
> **Last updated:** 2026-09-20
> **Supersedes:** Partner Tenant Preparation Guide v16 — Step 3 now names the three audit resources the script creates in the customer tenant — the Data Collection Endpoint `dce-easysoc-<customer-id>`, the Data Collection Rule `dcr-easysoc-<customer-id>`, and the `EasySOC_Audit_CL` custom table in the customer’s own Log Analytics workspace — together with the **Monitoring Metrics Publisher** assignment scoped to that one rule. Adds the instruction to re-run Step 3 after an EasySOC update that changes the audit schema: the script now upgrades an existing table or rule that is short of columns instead of reporting it as already present. None of this was documented before; the script has been creating these resources for some time.
> **Prior:** v15 added `-TenantSku`. v14 changed report delivery to ride the webhook POST instead of Graph. v12 added `-CaseBackend` and `-TeamsMode`. v11 added the Azure OpenAI backend and documented the Bootstrap-override parameters.

---

## 0. Before You Start

Confirm the tenant passes the **pre-flight readiness checklist** in [Tenant Prerequisites](./Tenant%20Prerequisites.md) §9. **First decide your `-CaseBackend`, `-TenantSku`, and `-TeamsMode`** (Tenant Prerequisites §0a) — it determines which rows below actually apply:

| Item | Status |
|---|---|
| M365 Business Premium or Defender for Business P2 licensed — **only for `-CaseBackend xdr`/`sharepoint` (default); not needed for `-CaseBackend sentinel`** | Partner confirms |
| Defender XDR portal active, device onboarding complete — **same conditional as above** | Partner confirms |
| Microsoft Sentinel workspace deployed, analytics rules enabled — **always required**, and is the case backend itself when `-CaseBackend sentinel` | Partner confirms |
| **Standard** Teams channel created (Shared Documents auto-provisioned; private/shared channels break report delivery) — **for `-TeamsMode full` or `webhook_only`** (report delivery works in both — see Step 2b); `none` needs nothing | Partner confirms |
| Azure subscription available with Contributor access | Partner confirms |
| (Recommended) Azure AI Foundry Claude deployment in the customer subscription, **or** an Azure OpenAI deployment if using `-LlmBackend azure_openai` | Partner confirms — record endpoint URL + key (+ deployment name for Azure OpenAI), or use the EasySOC POC key (Anthropic backend only) |
| Caller holds **Application Administrator** (or Global Administrator) — required for app registration + admin consent; Contributor alone is not sufficient | Partner confirms |
| Caller can register resource providers (Contributor includes this) | Partner confirms |
| Azure CLI installed | `az --version` |
| **ACR pull-token password** received from EasySOC (pasted into `deploy-aci.ps1` at Step 4) | Partner confirms |

---

## 1. Tenant Preparation — Step by Step

### Step 1 — Log in to the customer tenant

```powershell
az login --tenant <CUSTOMER-TENANT-ID>
```

Verify the displayed tenant is correct before proceeding. You do **not** need to pre-select a subscription — the preparation script discovers subscriptions and prompts you if there is more than one.

> **Note — duplicate subscription names:** a tenant can have multiple subscriptions sharing the same display name (e.g. two "Azure subscription 1"). The script always shows and uses the subscription **ID**, so pick by ID when prompted.

---

### Step 2 — Create the Teams webhook and collect its IDs

**Skip this step entirely if you're using `-TeamsMode none`.** If you're using `-TeamsMode webhook_only` (Team lives in a different Entra tenant than this app registration), do the "Create the webhook" part and **Step 2b** below, but skip "Retrieve Team ID and Channel ID" — those are only needed for reply-polling, which isn't available in that mode. Report delivery works fully under `webhook_only` and needs neither ID.

Most values are auto-discovered by the script. The Teams Workflows webhook and its IDs are the one set that cannot be retrieved automatically — create them now so you can paste them when prompted (or pass them as parameters).

**Create the webhook**

1. Open the target Teams channel → `···` → **Workflows** → search **Post to a channel when a webhook request is received** → **Add** → **Next**
2. Name it `EasySOC`, then click **Add workflow**
3. Copy the generated webhook URL

> **Webhook creator must be a channel member:** The account used to create the workflow must be a **member or owner of the target Team** — not just a tenant admin. If a Global Admin creates the workflow without being a team member, a webhook URL is issued but posts are silently dropped. Confirm the creating account appears in the Team's Members list (Team → `···` → **Manage team** → **Members**); if not, add them as a member first.

> **Webhook URL format:** The URL may look like a traditional Incoming Webhook (`https://<tenant>.webhook.office.com/webhookb2/...`) or a Power Automate HTTP trigger (`https://prod-*.logic.azure.com/...` or a Power Platform URL with `&sp=...&sv=...&sig=...` parameters). Both formats work — use the URL as-is. Legacy Office 365 "Incoming Webhook" **Connectors** are not supported (retired by Microsoft, different payload API); use the **Workflows** webhook only.

**Retrieve Team ID and Channel ID (`-TeamsMode full` only — skip for `webhook_only`)**

Open Teams in a **web browser** (not the desktop app) and navigate to the target channel. The URL contains both IDs:

```
https://teams.microsoft.com/l/channel/19%3***********************%40thread.tacv2/ChannelName?groupId=*12345*&tenantId=...
```

- **Team ID** (`groupId` query parameter): a plain GUID, e.g. `*12345*`
- **Channel ID** (path segment after `/l/channel/`): URL-encoded in the address bar — must be **decoded** before use

**Channel ID — required format and common mistakes**

The Channel ID must be supplied in its **raw, decoded form** (the agent embeds it directly into Graph API URLs):

Correct format:
```
19:aaaabbbbccccddddeeeeffff00001111@thread.tacv2
```

To get this from the browser URL:
1. Copy the segment between `/l/channel/` and the next `/`: `19%3Aaaaa**********************1111%40thread.tacv2`
2. Decode it: replace `%3A` → `:` and `%40` → `@`
3. The result must start with `19:` and end with `@thread.tacv2`

**Common mistakes that cause `400 Bad Request` on the first Teams poll:**

| Mistake | Example (wrong) | Correct |
|---|---|---|
| Pasting the URL-encoded form | `19%3Aaaaabbbb...%40thread.tacv2` | `19:aaaabbbb...@thread.tacv2` |
| Spurious `F` prefix (copied from a Teams desktop app URL) | `F19:aaaabbbb...@thread.tacv2` | `19:aaaabbbb...@thread.tacv2` |
| Missing `2` suffix | `19:aaaabbbb...@thread.tacv` | `19:aaaabbbb...@thread.tacv2` |

> **Quick sanity check:** the raw Channel ID must start with `19:` and end with `@thread.tacv2`. Any other prefix or suffix indicates a copy error.

---

### Step 2b — Extend the flow for report delivery (required for `-TeamsMode full` or `webhook_only`)

**Skip this step if you're using `-TeamsMode none`.** The agent sends the investigation report alongside the card in the same webhook POST, as a sibling JSON field: `{"filename": "...", "contentBase64": "..."}` under the key `report`. Nothing in this codebase can write that report into the customer's SharePoint from the *agent's* side — see Instead, **the flow itself** (created in Step 2, already authorized in this tenant) must be extended to do the write, using its own SharePoint connection:

1. Open the flow (Teams channel → `···` → **Workflows** → the `EasySOC` flow you created in Step 2 → **Edit**).
2. Add a **Condition**: `@not(equals(triggerBody()?['report'], null))`.
3. Inside the **Yes** branch:
   - **SharePoint — Create file**: Site Address = this Team's SharePoint site, Folder = `Shared Documents` (or a subfolder, e.g. `Shared Documents/EasySOC`), File Name = `@triggerBody()?['report']?['filename']`, File Content = `@base64ToBinary(triggerBody()?['report']?['contentBase64'])`.
   - **SharePoint — Get file properties**, using the `Identifier`/`ItemId` output from Create file, to retrieve a `Link` field (the browser-openable URL).
   - **Microsoft Teams — Post message in a chat or channel** (same Team/Channel as the card), message containing a link built from that `Link` output, e.g. `Investigation report: <a href="@{outputs('Get_file_properties')?['body/{Link}']}">Open report</a>`.
4. The card-posting action from Step 2 should run **unconditionally** (outside this new Condition) — it already ignores the extra `report` field when present, so no change is needed there.
5. Save the flow.

> **This was validated against a live cross-tenant deployment** (agent and Teams in separate Entra tenants) before being written up here: three test POSTs with a `report` field each produced the card, a `Create file` in the Team's `Shared Documents`, and a follow-up message with a working link — with **zero** Graph permissions granted to the agent's app registration for any of it.

---

### Step 3 — Run the preparation script

`Prepare-Tenant.ps1` does everything: it auto-discovers the subscription, resource group, Sentinel workspace, and any Azure AI Foundry / Azure OpenAI inference endpoint (prompting you to choose only when more than one exists), creates the app registration with the Graph permissions your `-CaseBackend`/`-TeamsMode` choice actually needs (5–11 of them — see below), grants admin consent, mints a client secret, provisions the storage account + Azure Files share, assigns the Sentinel Reader **and Responder** roles, retrieves that workspace's shared key (for ACI container-log integration — see the note below), prompts for the Teams and (optional) enrichment values, and writes **`easysoc-deploy.config.ps1`**.

**Choosing the case backend and Teams mode:** pass `-CaseBackend sentinel` for a tenant with **no Defender XDR/M365 license at all** — `/security/incidents` is permanently empty on such a tenant under the default `xdr` backend, so there'd be nothing for the agent to investigate. Pass `-TeamsMode webhook_only` when the only Teams access available is in a **different Entra tenant** than this app registration — reply-polling requires same-tenant Graph access and would silently never work there, so this mode configures posting + report delivery only, skipping the reply-polling permission that could never be used. (Report delivery itself needs no Graph permission at all and works identically in `full` and `webhook_only` — see Step 2b.) Pass `-TeamsMode none` if Teams isn't in use at all. Both parameters default to the traditional behavior (`xdr`, `full`) if omitted — existing invocations need no changes. **The Graph permission set requested shrinks accordingly** — see [Tenant Data Sovereignty and Access](./Tenant%20Data%20Sovereignty%20and%20Access.md) §1.1 for exactly which permissions each combination requests; this is a genuine least-privilege improvement worth mentioning to a security-conscious customer, not just an internal detail.

**Choosing the tenant SKU:** `-TenantSku` tells the agent which telemetry mix this tenant actually has, so it can route each SIEM query type correctly (`agent/internal/siem/router.go`) instead of guessing. If omitted, it defaults to `sentinel_only` when `-CaseBackend sentinel` (nothing else makes sense there) and `business_premium` otherwise. Pass `-TenantSku mde_sentinel` explicitly for a tenant that has Defender XDR for endpoint telemetry **and** a Sentinel workspace for identity sign-in types — that combination can't be inferred from `-CaseBackend` alone, since `-CaseBackend xdr`/`sharepoint` don't distinguish it from plain `business_premium`.

By default it configures the **Anthropic/Foundry** inference path (§5 of Tenant Prerequisites). Pass `-LlmBackend azure_openai` to configure **Azure OpenAI** instead — see the parameter table below.

**Simplest invocation — fully interactive:**

```powershell
.\Prepare-Tenant.ps1 -CustomerId "contoso"
```

The script will prompt you for anything it cannot auto-discover (a subscription/workspace/Foundry choice if ambiguous, the Teams webhook + IDs from Step 2, and optional enrichment keys).

**Scripted invocation — pin every value, no prompts:**

```powershell
.\Prepare-Tenant.ps1 `
    -CustomerId "contoso" `
    -SubscriptionId "<AZURE-SUBSCRIPTION-ID>" `
    -ResourceGroup "rg-easysoc-poc" `
    -Location "southeastasia" `
    -SentinelWorkspaceId "<WORKSPACE-GUID>" `
    -TeamsWebhookUrl "<WEBHOOK-URL>" `
    -TeamsTeamId "<TEAM-ID>" `
    -TeamsChannelId "<CHANNEL-ID>" `
    -NonInteractive
```

**Sentinel-only tenant, Teams reachable only in a different Entra tenant:**

```powershell
.\Prepare-Tenant.ps1 -CustomerId "contoso" -CaseBackend "sentinel" -TeamsMode "webhook_only"
```

This excludes the Defender Security API and Teams-polling Graph permissions from the admin-consent screen entirely, and leaves Team ID/Channel ID blank in the generated config (no prompt for them). Report delivery still works fully — see Step 2b. (`-TenantSku` defaults to `sentinel_only` here automatically, since `-CaseBackend sentinel` was passed — no need to also pass `-TenantSku`.)

**Mixed tenant — Defender XDR for endpoint, Sentinel for identity:**

```powershell
.\Prepare-Tenant.ps1 -CustomerId "contoso" -TenantSku "mde_sentinel"
```

**Parameters (all optional except `-CustomerId`):**

| Parameter | Notes |
|---|---|
| `-CustomerId` | **Required.** Lowercase letters, digits, hyphens — used as app registration name suffix and config key |
| `-SubscriptionId` | Auto-detected; you are prompted only if the account has more than one enabled subscription |
| `-ResourceGroup` | Prompted (with a list of existing groups) if omitted; created automatically if it does not exist |
| `-Location` | Defaults to the resource group's region; prompted only for a new group |
| `-SentinelWorkspaceId` | Auto-discovered; prompted only if more than one workspace exists. Pass `none` to skip Sentinel (all Sentinel KQL then returns HTTP 403 at runtime — and if `-CaseBackend sentinel`, the case backend itself becomes completely non-functional, not just telemetry-degraded) |
| `-CaseBackend` | `xdr` (default — Defender XDR incident via Graph Security API), `sentinel` (Microsoft Sentinel incident via KQL read + ARM REST write — for a tenant with Sentinel but no Defender XDR/M365 license), or `sharepoint` (SharePoint List case tracking, still backed by the underlying Defender XDR incident). Controls which Graph Security API permissions get requested — see Step 3 above and [Tenant Data Sovereignty and Access](./Tenant%20Data%20Sovereignty%20and%20Access.md) §1.1 |
| `-TenantSku` | `business_premium` (default), `mde_sentinel`, or `sentinel_only` — which telemetry mix this tenant has, for SIEM query routing (`agent/internal/siem/router.go`). If omitted, defaults to `sentinel_only` when `-CaseBackend sentinel`, else `business_premium`. Pass explicitly for a `mde_sentinel` tenant — see Step 3 above. Written to the config as `SIEM_TENANT_SKU` |
| `-TeamsMode` | `full` (default — posting + reply-polling, plus report delivery), `webhook_only` (posting + report delivery, no reply-polling — works cross-tenant), or `none` (no Teams at all). Only `full` requests the Teams-polling Graph permission and prompts for Team ID/Channel ID — see Step 2 and Step 3 above. Report delivery needs no Graph permission in either mode, but does need the flow extended per **Step 2b** |
| `-LlmBackend` | `anthropic` (default) or `azure_openai`. Selects which of the two parameter groups below is used |
| `-AnthropicBaseUrl` / `-AnthropicApiKey` | Used when `-LlmBackend anthropic` (default). Auto-discovered from a Foundry resource, or prompted. Blank base URL = public `api.anthropic.com` |
| `-AzureOpenAiEndpoint` / `-AzureOpenAiApiKey` / `-AzureOpenAiDeployment` | Used when `-LlmBackend azure_openai`. Endpoint/key auto-discovered from a Foundry/Azure OpenAI resource if unambiguous, or prompted; deployment name (e.g. `gpt-5.4`) is always prompted if omitted — there is no auto-discovery for it |
| `-TeamsWebhookUrl` / `-TeamsTeamId` / `-TeamsChannelId` | From Step 2; prompted (blank to disable Teams) if omitted. Team ID/Channel ID are only ever prompted for under `-TeamsMode full` |
| `-VirusTotalApiKey` / `-AbuseIpDbApiKey` / `-IpInfoToken` | Optional enrichment keys; prompted (blank to disable) if omitted |
| `-BootstrapUrl` / `-BootstrapToken` / `-BootstrapTlsVerify` | Advanced/rarely needed: overrides the EasySOC control-server endpoint that `deploy-aci.ps1`'s PROVIDER section otherwise supplies. Leave blank (the default) unless EasySOC has told you to set these explicitly for this deployment |
| `-ConfigOutPath` | Where to write the config file (default `.\easysoc-deploy.config.ps1`) |
| `-NonInteractive` | Never prompt — use only supplied/unambiguous values; fail otherwise. For pipelines |
| `-DryRun` | Read-only: runs Sentinel/Foundry discovery, prints the plan, and makes **no** tenant changes. Writes a **preview** `easysoc-deploy.config.ps1` with the discovered values but placeholder `appId`/`objectId`/`secret` — not deployable as-is; re-run without `-DryRun` to provision real values |

> **Clean subscriptions:** the script runs `az provider register --namespace Microsoft.Storage --wait` automatically. On a brand-new subscription this may take ~1 minute; no manual action needed.

> **Output:** the script writes `easysoc-deploy.config.ps1` next to itself (containing the client secret and any keys) and prints a summary. **Protect that file** — it holds secrets — and delete it after deployment. Re-running the script mints a fresh client secret (`--append`); delete the previous credential from the app registration afterwards if tidiness matters.

The Sentinel Reader **and Responder** roles are assigned automatically as part of this step whenever a workspace is selected (Responder is new — needed for `-CaseBackend sentinel`'s write path, and assigned unconditionally so switching an already-prepared tenant to `sentinel` later needs no second manual grant). If you passed `-SentinelWorkspaceId none` or the assignment failed, use the manual fallback:

```powershell
$WorkspaceResourceId = $(az monitor log-analytics workspace list `
    --query "[?customerId=='<WORKSPACE-GUID>'].id | [0]" --output tsv)
az role assignment create `
    --assignee "<OBJECT-ID-FROM-SCRIPT-SUMMARY>" `
    --role "Microsoft Sentinel Reader" `
    --scope $WorkspaceResourceId
az role assignment create `
    --assignee "<OBJECT-ID-FROM-SCRIPT-SUMMARY>" `
    --role "Microsoft Sentinel Responder" `
    --scope $WorkspaceResourceId
```

> **Two different workspace GUIDs:** the `customerId` is used for Log Analytics queries; the role assignment requires the **ARM resource ID** (a path starting with `/subscriptions/...`). The command above resolves the ARM ID from the `customerId` for you.

> **ACI container-log integration:** the script also retrieves the same workspace's shared key and writes it to `easysoc-deploy.config.ps1` as `LogAnalyticsWorkspaceId`/`LogAnalyticsWorkspaceKey`. `deploy-aci.ps1` (Step 6) passes these to `az container create --log-analytics-workspace`/`--log-analytics-workspace-key` — **the only way** to get `soc-agent`'s logs into Log Analytics. The Azure Portal's own Log Analytics blade refuses to configure this for the container group (it uses secure environment variables plus an Azure Files volume mount, which the Portal wizard treats as "advanced configuration" and won't touch), and the integration can only be set at container-group *creation*, never added to a running group afterward. If the shared key can't be retrieved, the script warns and leaves both blank — the deployment still succeeds, just without this logging path; fall back to `az container logs` (Step 8) or re-run Step 3 once the workspace issue is resolved and redeploy.

> **Audit ingestion resources (new):** whenever a Sentinel workspace is selected, the script also creates a Data Collection Endpoint `dce-easysoc-<customer-id>`, a Data Collection Rule `dcr-easysoc-<customer-id>`, and the `EasySOC_Audit_CL` custom table in the customer's own workspace, then assigns the agent **Monitoring Metrics Publisher** on that one rule. That is how the agent's investigation record reaches Log Analytics instead of only the JSONL file on the Azure Files share. Nothing in it leaves the tenant — see [Tenant Data Sovereignty and Access](./Tenant%20Data%20Sovereignty%20and%20Access.md) §2. The table has to exist before the rule can reference it; a rule created against a missing table fails with `InvalidOutputTable`, so do not pre-create either by hand.

> **Re-run Step 3 after an EasySOC update that changes the audit schema.** `Prepare-Tenant.ps1` is idempotent, and since 2026-09-20 it **upgrades** an existing table or rule that is short of columns rather than reporting it as already present and moving on. A tenant prepared before that date declares 10 of the 24 columns, and the other 14 — the harness's decision scalars — are discarded on ingest with HTTP 204 and no error in any log. One re-run fixes it; existing rows are untouched and keep their null values for the new columns.

---

## 2. Container Deployment — Step by Step

`deploy-aci.ps1` has a **PROVIDER section** at the top holding the ACR pull token (`$AcrPullPassword`) and image tag. The pull token **ships blank** — you must paste the ACR pull-token password EasySOC gave you into it before deploying (see Step 4). Everything customer-specific comes from the config file written in Step 3.

### Step 4 — Place the config file next to the deploy script and set the ACR pull token

Put `deploy-aci.ps1` and the generated `easysoc-deploy.config.ps1` in the same folder. The deploy script dot-sources the config file automatically (override with `-ConfigFile <path>` if they live elsewhere).

**One manual edit of `deploy-aci.ps1` is required.** Open it and paste the ACR pull-token password EasySOC provided into `$AcrPullPassword` in the **PROVIDER section** at the top:

```powershell
$AcrPullPassword = "<ACR-PULL-TOKEN-PASSWORD-FROM-EASYSOC>"   # ships blank
```

It is **blank as shipped**; if you leave it empty the script stops immediately with `AcrPullPassword is required (PROVIDER section).` and the container is never created. No other values in `deploy-aci.ps1` need editing — the image tag default is correct and everything customer-specific comes from the config file.

> **Anthropic backend (default):** if no Azure AI Foundry endpoint was configured, `easysoc-deploy.config.ps1` leaves `$AnthropicApiKey` blank; `deploy-aci.ps1` then uses the EasySOC-provided POC key from its PROVIDER section. Confirm one of the two is present, or the deploy step will stop with "AnthropicApiKey is required".
>
> **Azure OpenAI backend:** if you ran `Prepare-Tenant.ps1 -LlmBackend azure_openai`, there is **no POC fallback** — `$AzureOpenAiEndpoint` and `$AzureOpenAiApiKey` must both be present in `easysoc-deploy.config.ps1`, or the deploy step stops with "AzureOpenAiApiKey and AzureOpenAiEndpoint are required".

### Step 5 — Verify the storage account (optional)

```powershell
az group show --name rg-easysoc-poc
az storage account show --name <STORAGE-ACCOUNT-NAME> --resource-group rg-easysoc-poc
```

> If `Prepare-Tenant.ps1` found and reused an existing storage account in a **different** resource group than `-ResourceGroup` (see the new troubleshooting row below), pass that account's actual resource group to the second command instead — the generated config's `$StorageResourceGroup` value (distinct from `$ResourceGroup`) shows which one.

### Step 6 — Run the deployment script

```powershell
.\deploy-aci.ps1
```

The script will:
1. Load `easysoc-deploy.config.ps1` and validate required values (including `$AcrPullPassword`)
2. Register `Microsoft.ContainerInstance` (no-op if already registered)
3. Fetch the storage account key
4. Delete the existing container instance if present (ACI does not support in-place updates)
5. Create a new container instance with all environment variables and the Azure Files volume mounted at `/app/audit`, plus Log Analytics logging enabled if a workspace key was retrieved in Step 3 (the console output shows `Log Analytics logging: enabled` or `disabled`)
6. Wait 10 seconds and print startup logs

### Step 7 — Confirm the container is running

```powershell
az container show `
    --resource-group rg-easysoc-poc `
    --name soc-agent `
    --query "containers[0].instanceView.currentState"
```

Expected state: `Running`. If the state is `Terminated`, check the exit code and logs:

```powershell
az container logs --resource-group rg-easysoc-poc --name soc-agent
```

### Step 8 — Follow live logs

```powershell
az container logs --resource-group rg-easysoc-poc --name soc-agent --follow
```

The agent polls for new incidents periodically. You should see log lines such as:

```
[INFO] poll: 0 active incidents
[INFO] investigation started: incident_id=42
[INFO] supervisor: verdict=TP confidence=0.91
```

### Step 8b — Editing auto-close rules or pre-enrichment bundles after deployment (new)

`auto_close_patterns.yaml` (deterministic ticket auto-close rules) and `pre_enrichment_bundles.yaml` (deterministic per-alert-signature SIEM query bundles) are **customer-tunable business rules, not baked into the container image**. They resolve to the same Azure Files share already mounted for audit persistence (`/app/config/audit` inside the container) — editing them needs no image rebuild and no `deploy-aci.ps1` re-run.

**They start empty** — nothing is pre-seeded on a fresh deployment, so auto-close is inactive and no pre-enrichment bundles run until you add one.

To add or edit a rule set:

```powershell
# Upload a local auto_close_patterns.yaml (or pre_enrichment_bundles.yaml) to the share.
# <STORAGE-ACCOUNT> / <FILE-SHARE> are the same values Prepare-Tenant.ps1 printed in its
# summary ($StorageAccount / $FileShare, default share name "audit").
az storage file upload `
    --account-name <STORAGE-ACCOUNT> `
    --share-name <FILE-SHARE> `
    --source .\auto_close_patterns.yaml `
    --path auto_close_patterns.yaml

# Restart the container to pick up the change -- both files are loaded once at
# startup, not hot-reloaded.
az container restart --resource-group rg-easysoc-poc --name soc-agent
```

Use the same two commands (with `pre_enrichment_bundles.yaml`/`--path pre_enrichment_bundles.yaml`) for pre-enrichment bundles. Confirm the file was picked up via startup logs (`az container logs -g rg-easysoc-poc -n soc-agent`) — a bad or missing file degrades gracefully (empty rule set, not a crash), so a silent no-op after upload usually means the `--path` or share name didn't match what `deploy-aci.ps1` actually mounted; re-check against the deploy output.


---

## 3. Verification Checklist

| Check | Command / Action | Expected Result |
|---|---|---|
| App registration visible | Azure portal → Entra ID → App registrations → `AgenticSOC-<customerid>` | Visible, with the permissions your `-CaseBackend`/`-TeamsMode` combination requests (5–11 — see [Tenant Data Sovereignty and Access](./Tenant%20Data%20Sovereignty%20and%20Access.md) §1.1) all granted |
| Admin consent granted | Same page → API permissions | All rows show "Granted for \<tenant\>" |
| Storage provider registered | `az provider show --namespace Microsoft.Storage --query registrationState -o tsv` | `Registered` |
| Sentinel Reader **and Responder** roles assigned | `az role assignment list --assignee <OBJECT-ID> --role "Microsoft Sentinel Reader"` and again with `--role "Microsoft Sentinel Responder"` | One assignment returned for each |
| Storage account and share exist | `az storage share exists --name audit --account-name <STORAGE>` | `"exists": true` |
| Container running | `az container show -g rg-easysoc-poc -n soc-agent --query "containers[0].instanceView.currentState.state"` | `"Running"` |
| Agent polls successfully | `az container logs -g rg-easysoc-poc -n soc-agent` | `poll:` log lines present, no auth errors |
| Teams card posted | Trigger a test incident (Defender for `xdr`/`sharepoint`, or a Sentinel analytics-rule incident for `sentinel`) | Verdict card appears in the configured Teams channel within ~2 minutes of incident creation (skip if `-TeamsMode none`) |
| Report delivered (skip if `-TeamsMode none`) | Same test incident as above | A follow-up message with a report link appears in the channel shortly after the card, and the linked file opens the report. If it doesn't, confirm Step 2b was actually applied to the flow before assuming the agent is at fault |
| ACI logs reaching Log Analytics (skip if `LogAnalyticsWorkspaceKey` was blank) | `az monitor log-analytics query -w <WORKSPACE-GUID> --analytics-query "ContainerInstanceLog_CL | take 5"` | Rows returned a few minutes after the container starts |

---

## 4. Troubleshooting Quick Reference

| Symptom | Likely Cause | Fix |
|---|---|---|
| `AcrPullPassword is required (PROVIDER section).` when running `deploy-aci.ps1` | The ACR pull token was not pasted into `$AcrPullPassword` in the PROVIDER section — it ships blank | Open `deploy-aci.ps1`, set `$AcrPullPassword` to the ACR pull-token password EasySOC provided, then re-run |
| `SubscriptionNotFound` during storage account creation (but `az group` commands work) | `Microsoft.Storage` resource provider not registered — storage-RP calls return this misleading error on clean subscriptions | The current script auto-registers it; if you hit this on a manual step, run `az provider register --namespace Microsoft.Storage --wait`, then re-run `Prepare-Tenant.ps1` |
| `Prepare-Tenant.ps1` reports a storage account name is "already exists in resource group X" and asks to reuse it | Storage account names are globally unique across Azure, not just the target resource group — the script found an account with this exact name elsewhere in the subscription (e.g. a partial prior run) | Answer **Y** to reuse it in place (the generated config's `$StorageResourceGroup` will reflect the actual resource group), or **n** and supply a different `-StorageAccountName` |
| `Prepare-Tenant.ps1` warns a storage account name is unavailable but isn't visible via `show`/`list` in this subscription | Azure's global name reservation for storage accounts can outlive a previously **deleted** account with the same name for a period — this is not a resource this subscription can see or manage | Enter a different name when prompted (the script asks immediately, no need to restart from Step 1) |
| `AnthropicApiKey is required` when running `deploy-aci.ps1` | The config file left `$AnthropicApiKey` blank and no POC fallback key is set | Set the Foundry key (re-run `Prepare-Tenant.ps1`) or have EasySOC fill the PROVIDER fallback key in `deploy-aci.ps1` |
| `AzureOpenAiApiKey and AzureOpenAiEndpoint are required` when running `deploy-aci.ps1` | `easysoc-deploy.config.ps1` was generated with `-LlmBackend azure_openai` but the endpoint or key is blank — there is no POC fallback for this backend | Re-run `Prepare-Tenant.ps1 -LlmBackend azure_openai` and supply/confirm `-AzureOpenAiEndpoint`, `-AzureOpenAiApiKey`, `-AzureOpenAiDeployment` |
| `Config file not found` when running `deploy-aci.ps1` | `easysoc-deploy.config.ps1` is not next to the deploy script | Place both files in the same folder, or pass `-ConfigFile <path>` |
| Teams reply poll failed — 400 Bad Request` in container logs | Channel ID format is incorrect — URL-encoded form or spurious `F` prefix. **Only relevant under `-TeamsMode full`** — `webhook_only`/`none` never poll at all | Fix the `$TeamsChannelId` value in `easysoc-deploy.config.ps1` — raw decoded format starting with `19:` and ending with `@thread.tacv2` (see Step 2). Re-run `deploy-aci.ps1` |
| Webhook POST returns 200 but card never appears | Workflow created by an account that is not a member/owner of the Team — webhook issued but posts dropped | Add the workflow-creating account to the Team as Member or Owner, or have an existing member recreate the workflow and update `$TeamsWebhookUrl` |
| Card posts fine but no report/link ever follows it | Step 2b's flow steps were never added, or use the wrong field names (must read `report.filename`/`report.contentBase64` from the trigger body, exactly as the agent sends them) | Re-check the flow's run history — if the trigger's captured inputs show a populated `report` object but nothing happened after it, the Condition/Create-file/Post-message steps from Step 2b are missing or misconfigured; re-add them |
| `MSAL token acquisition failed` in logs | Client ID or secret incorrect | Verify values in `easysoc-deploy.config.ps1`; re-run `Prepare-Tenant.ps1` to rotate the secret if needed |
| `HTTP 403` on Advanced Hunting queries | `ThreatHunting.Read.All` not granted or admin consent not applied. **Only relevant for `-CaseBackend xdr`/`sharepoint`** — `sentinel` never requests this permission | Check the API permissions page; re-grant admin consent |
| `HTTP 403` on Sentinel queries, or on Sentinel incident reads/writes for `-CaseBackend sentinel` | Sentinel Reader (and, for `sentinel`, Responder) role not assigned to the app's service principal on the workspace | Run the Step 3 manual fallback (both roles) |
| `HTTP 400` from Sentinel — `could not be resolved` | Table does not exist in the workspace (e.g. connector not enabled) | Enable the relevant data connector in Sentinel |
| Container exits immediately | Missing required environment variable | Check logs for `KeyError`/`ValueError`; verify the config file has all required values |
| No incidents polled | No active incidents (Defender XDR for `xdr`/`sharepoint`, or Sentinel for `sentinel`) | Create a test incident, or wait for a real alert/analytics rule to trigger |
| Endpoint alerts routed to the wrong backend, or Sentinel-only query types silently return `table_absent` | `-TenantSku` doesn't match the tenant's actual telemetry mix | Re-run `Prepare-Tenant.ps1` with the correct `-TenantSku` (`business_premium`/`mde_sentinel`/`sentinel_only`), then redeploy |
| No tickets ever auto-close, or pre-enrichment never runs, even though you uploaded a rules file | File uploaded to the wrong share/path, or container not restarted since upload (new, see Step 8b) | Confirm the upload's `--share-name`/`--path` match what `deploy-aci.ps1` mounted (`$FileShare`, default `audit`, at `/app/config/audit`), then `az container restart` — both files load once at startup only |
| Azure Portal says "This container instance uses advanced configuration options that are not currently supported for Log Analytics workspace integration via the Portal" | Expected — `soc-agent` uses secure environment variables + an Azure Files volume mount, which the Portal's Log Analytics wizard doesn't support for any container group | Not an error. Log Analytics logging is already wired via CLI in `deploy-aci.ps1` (Step 6) — check the deploy output for `Log Analytics logging: enabled`, or query `ContainerInstanceLog_CL` in the workspace to confirm. No Portal action needed or possible |
| `LogAnalyticsWorkspaceKey` blank / "Log Analytics logging: disabled" at deploy time | `Prepare-Tenant.ps1` could not retrieve the workspace shared key (permissions, or `-SentinelWorkspaceId none`) | Re-run `Prepare-Tenant.ps1` with a valid Sentinel/Log Analytics workspace selected, then redeploy — ACI logging can only be enabled at container-group creation, so a redeploy is required either way |
