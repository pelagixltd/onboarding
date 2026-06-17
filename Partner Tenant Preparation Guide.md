# EasySOC — Partner Tenant Preparation Guide v10

> **Audience:** Partner technical engineer
> **Purpose:** The engineering run procedure — prepare a customer tenant and deploy the agent container using the two provided scripts (`Prepare-Tenant.ps1` + `deploy-aci.ps1`)
> **Scope:** Procedure only. This guide assumes the tenant is already ready.
> - Tenant readiness (resources/licenses/services + pre-flight checklist) → **[Tenant Prerequisites](./Tenant%20Prerequisites.md)**
> - What the agent can access, what leaves the tenant, app permissions, egress → **[Tenant Data Sovereignty and Access](./Tenant%20Data%20Sovereignty%20and%20Access.md)**
> **Last updated:** 2026-06-17
> **Supersedes:** Partner Tenant Preparation Guide v9 — two corrections: (1) the ACR pull token `$AcrPullPassword` ships **blank** in `deploy-aci.ps1` and **must be pasted into the PROVIDER section by the engineer** before deploying (the script fails fast with `AcrPullPassword is required` otherwise) — the previous "pre-filled / no manual editing required" wording was wrong; (2) `-DryRun` now writes a **preview** config file (it no longer writes nothing).

---

## 0. Before You Start

Confirm the tenant passes the **pre-flight readiness checklist** in [Tenant Prerequisites](./Tenant%20Prerequisites.md) §9. The quick gate:

| Item | Status |
|---|---|
| M365 Business Premium or Defender for Business P2 licensed | Partner confirms |
| Defender XDR portal active, device onboarding complete | Partner confirms |
| Microsoft Sentinel workspace deployed, analytics rules enabled | Partner confirms |
| **Standard** Teams channel created (Shared Documents auto-provisioned; private/shared channels break report uploads) | Partner confirms |
| Azure subscription available with Contributor access | Partner confirms |
| (Recommended) Azure AI Foundry Claude deployment in the customer subscription | Partner confirms — record endpoint URL + key, or use the EasySOC POC key |
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

Most values are auto-discovered by the script. The Teams Workflows webhook and its IDs are the one set that cannot be retrieved automatically — create them now so you can paste them when prompted (or pass them as parameters).

**Create the webhook**

1. Open the target Teams channel → `···` → **Workflows** → search **Post to a channel when a webhook request is received** → **Add** → **Next**
2. Name it `EasySOC`, then click **Add workflow**
3. Copy the generated webhook URL

> **Webhook creator must be a channel member:** The account used to create the workflow must be a **member or owner of the target Team** — not just a tenant admin. If a Global Admin creates the workflow without being a team member, a webhook URL is issued but posts are silently dropped. Confirm the creating account appears in the Team's Members list (Team → `···` → **Manage team** → **Members**); if not, add them as a member first.

> **Webhook URL format:** The URL may look like a traditional Incoming Webhook (`https://<tenant>.webhook.office.com/webhookb2/...`) or a Power Automate HTTP trigger (`https://prod-*.logic.azure.com/...` or a Power Platform URL with `&sp=...&sv=...&sig=...` parameters). Both formats work — use the URL as-is. Legacy Office 365 "Incoming Webhook" **Connectors** are not supported (retired by Microsoft, different payload API); use the **Workflows** webhook only.

**Retrieve Team ID and Channel ID**

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

### Step 3 — Run the preparation script

`Prepare-Tenant.ps1` does everything: it auto-discovers the subscription, resource group, Sentinel workspace, and any Azure AI Foundry inference endpoint (prompting you to choose only when more than one exists), creates the app registration with all 12 Graph permissions, grants admin consent, mints a client secret, provisions the storage account + Azure Files share, assigns the Sentinel Reader role, prompts for the Teams and (optional) enrichment values, and writes **`easysoc-deploy.config.ps1`**.

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

**Parameters (all optional except `-CustomerId`):**

| Parameter | Notes |
|---|---|
| `-CustomerId` | **Required.** Lowercase letters, digits, hyphens — used as app registration name suffix and config key |
| `-SubscriptionId` | Auto-detected; you are prompted only if the account has more than one enabled subscription |
| `-ResourceGroup` | Prompted (with a list of existing groups) if omitted; created automatically if it does not exist |
| `-Location` | Defaults to the resource group's region; prompted only for a new group |
| `-SentinelWorkspaceId` | Auto-discovered; prompted only if more than one workspace exists. Pass `none` to skip Sentinel (all Sentinel KQL then returns HTTP 403 at runtime) |
| `-AnthropicBaseUrl` / `-AnthropicApiKey` | Auto-discovered from a Foundry resource, or prompted. Blank base URL = public `api.anthropic.com` |
| `-TeamsWebhookUrl` / `-TeamsTeamId` / `-TeamsChannelId` | From Step 2; prompted (blank to disable Teams) if omitted |
| `-VirusTotalApiKey` / `-AbuseIpDbApiKey` / `-IpInfoToken` | Optional enrichment keys; prompted (blank to disable) if omitted |
| `-ConfigOutPath` | Where to write the config file (default `.\easysoc-deploy.config.ps1`) |
| `-NonInteractive` | Never prompt — use only supplied/unambiguous values; fail otherwise. For pipelines |
| `-DryRun` | Read-only: runs Sentinel/Foundry discovery, prints the plan, and makes **no** tenant changes. Writes a **preview** `easysoc-deploy.config.ps1` with the discovered values but placeholder `appId`/`objectId`/`secret` — not deployable as-is; re-run without `-DryRun` to provision real values |

> **Clean subscriptions:** the script runs `az provider register --namespace Microsoft.Storage --wait` automatically. On a brand-new subscription this may take ~1 minute; no manual action needed.

> **Output:** the script writes `easysoc-deploy.config.ps1` next to itself (containing the client secret and any keys) and prints a summary. **Protect that file** — it holds secrets — and delete it after deployment. Re-running the script mints a fresh client secret (`--append`); delete the previous credential from the app registration afterwards if tidiness matters.

The Sentinel Reader role is assigned automatically as part of this step whenever a workspace is selected. If you passed `-SentinelWorkspaceId none` or the assignment failed, use the manual fallback:

```powershell
$WorkspaceResourceId = $(az monitor log-analytics workspace list `
    --query "[?customerId=='<WORKSPACE-GUID>'].id | [0]" --output tsv)
az role assignment create `
    --assignee "<OBJECT-ID-FROM-SCRIPT-SUMMARY>" `
    --role "Microsoft Sentinel Reader" `
    --scope $WorkspaceResourceId
```

> **Two different workspace GUIDs:** the `customerId` is used for Log Analytics queries; the role assignment requires the **ARM resource ID** (a path starting with `/subscriptions/...`). The command above resolves the ARM ID from the `customerId` for you.

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

> If no Azure AI Foundry endpoint was configured, `easysoc-deploy.config.ps1` leaves `$AnthropicApiKey` blank; `deploy-aci.ps1` then uses the EasySOC-provided POC key from its PROVIDER section. Confirm one of the two is present, or the deploy step will stop with "AnthropicApiKey is required".

### Step 5 — Verify the storage account (optional)

```powershell
az group show --name rg-easysoc-poc
az storage account show --name <STORAGE-ACCOUNT-NAME> --resource-group rg-easysoc-poc
```

### Step 6 — Run the deployment script

```powershell
.\deploy-aci.ps1
```

The script will:
1. Load `easysoc-deploy.config.ps1` and validate required values (including `$AcrPullPassword`)
2. Register `Microsoft.ContainerInstance` (no-op if already registered)
3. Fetch the storage account key
4. Delete the existing container instance if present (ACI does not support in-place updates)
5. Create a new container instance with all environment variables and the Azure Files volume mounted at `/app/audit`
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

---

## 3. Verification Checklist

| Check | Command / Action | Expected Result |
|---|---|---|
| App registration visible | Azure portal → Entra ID → App registrations → `AgenticSOC-<customerid>` | Visible with all 12 permissions granted |
| Admin consent granted | Same page → API permissions | All rows show "Granted for \<tenant\>" |
| Storage provider registered | `az provider show --namespace Microsoft.Storage --query registrationState -o tsv` | `Registered` |
| Sentinel Reader role assigned | `az role assignment list --assignee <OBJECT-ID> --role "Microsoft Sentinel Reader"` | One assignment returned |
| Storage account and share exist | `az storage share exists --name audit --account-name <STORAGE>` | `"exists": true` |
| Container running | `az container show -g rg-easysoc-poc -n soc-agent --query "containers[0].instanceView.currentState.state"` | `"Running"` |
| Agent polls successfully | `az container logs -g rg-easysoc-poc -n soc-agent` | `poll:` log lines present, no auth errors |
| Teams card posted | Trigger a test Defender incident | Verdict card appears in the configured Teams channel within ~2 minutes of incident creation |

---

## 4. Troubleshooting Quick Reference

| Symptom | Likely Cause | Fix |
|---|---|---|
| `AcrPullPassword is required (PROVIDER section).` when running `deploy-aci.ps1` | The ACR pull token was not pasted into `$AcrPullPassword` in the PROVIDER section — it ships blank | Open `deploy-aci.ps1`, set `$AcrPullPassword` to the ACR pull-token password EasySOC provided, then re-run |
| `SubscriptionNotFound` during storage account creation (but `az group` commands work) | `Microsoft.Storage` resource provider not registered — storage-RP calls return this misleading error on clean subscriptions | The current script auto-registers it; if you hit this on a manual step, run `az provider register --namespace Microsoft.Storage --wait`, then re-run `Prepare-Tenant.ps1` |
| `AnthropicApiKey is required` when running `deploy-aci.ps1` | The config file left `$AnthropicApiKey` blank and no POC fallback key is set | Set the Foundry key (re-run `Prepare-Tenant.ps1`) or have EasySOC fill the PROVIDER fallback key in `deploy-aci.ps1` |
| `Config file not found` when running `deploy-aci.ps1` | `easysoc-deploy.config.ps1` is not next to the deploy script | Place both files in the same folder, or pass `-ConfigFile <path>` |
| `Teams reply poll failed — 400 Bad Request` in container logs | Channel ID format is incorrect — URL-encoded form or spurious `F` prefix | Fix the `$TeamsChannelId` value in `easysoc-deploy.config.ps1` — raw decoded format starting with `19:` and ending with `@thread.tacv2` (see Step 2). Re-run `deploy-aci.ps1` |
| Webhook POST returns 200 but card never appears | Workflow created by an account that is not a member/owner of the Team — webhook issued but posts dropped | Add the workflow-creating account to the Team as Member or Owner, or have an existing member recreate the workflow and update `$TeamsWebhookUrl` |
| `MSAL token acquisition failed` in logs | Client ID or secret incorrect | Verify values in `easysoc-deploy.config.ps1`; re-run `Prepare-Tenant.ps1` to rotate the secret if needed |
| `HTTP 403` on Advanced Hunting queries | `ThreatHunting.Read.All` not granted or admin consent not applied | Check the API permissions page; re-grant admin consent |
| `HTTP 403` on Sentinel queries | Sentinel Reader role not assigned to the app's service principal on the workspace | Run the Step 3 manual fallback |
| `HTTP 400` from Sentinel — `could not be resolved` | Table does not exist in the workspace (e.g. connector not enabled) | Enable the relevant data connector in Sentinel |
| Container exits immediately | Missing required environment variable | Check logs for `KeyError`/`ValueError`; verify the config file has all required values |
| No incidents polled | No active incidents in Defender XDR | Create a test incident or wait for a real alert to trigger |
