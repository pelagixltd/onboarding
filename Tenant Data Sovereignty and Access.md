# EasySOC — Tenant Data Sovereignty & Access v7

> **Audience:** Partner technical engineer, and the customer's security/compliance reviewer
> **Purpose:** Single reference for **what the agent can access, what data leaves the tenant, and the egress it requires** — the access-rights and data-residency picture, separated from the readiness checklist and the run procedure.
> **Companion docs:**
> - Resources/licenses/services to stand up first → **[Tenant Prerequisites](./Tenant%20Prerequisites.md)**
> - Step-by-step run + deploy procedure → **[Partner Tenant Preparation Guide](./Partner%20Tenant%20Preparation%20Guide.md)**
> **Last updated:** 2026-09-20
> **Supersedes:** Tenant Data Sovereignty and Access v6 — documents what the agent **writes into the customer tenant**, which no partner document named before: the audit Data Collection Endpoint and Rule, and the `EasySOC_Audit_CL` custom table in the customer’s own Log Analytics workspace — one row per completed investigation, holding the incident and investigation ID, the rendered audit report, cost/token/duration counts and the harness’s decision scalars. It never leaves the tenant. Adds **Monitoring Metrics Publisher** to the RBAC table, scoped to the single Data Collection Rule rather than the workspace, so it grants no read of any customer table.
> **Prior:** v4 removed `Sites.ReadWrite.All` — see v5's own superseded history for detail. v3 made §1.1's permission list conditional on `-CaseBackend`/`-TeamsMode`, added the **Microsoft Sentinel Responder** role, and added the `-CaseBackend sentinel` access model. v2 added the Azure OpenAI inference backend (§3, §5) alongside Anthropic/Foundry.

The only data that ever leaves the tenant goes to three destinations: the **inference endpoint** (LLM reasoning), the three **optional threat-intelligence APIs**, and the **EasySOC control endpoint** (licensing, prompt delivery, and operational telemetry / threat-intel). All are outbound-only HTTPS calls initiated by the container — no inbound ports are opened.

---

## 1. Application Permissions (the agent's access rights)

The app registration created by `Prepare-Tenant.ps1` requests the following, all of type **Application** (no user delegation — the agent runs as itself). **Which of these get requested depends on `-CaseBackend`/`-TeamsMode`** (see [Tenant Prerequisites](./Tenant%20Prerequisites.md) §0a) — the script builds the permission set accordingly rather than requesting a fixed list, so the customer's admin-consent screen only ever shows scopes the deployment can actually use.

### 1.1 Microsoft Graph (5–11 permissions, depending on choices)

**Always requested (5 — identity/context resolution, independent of case backend or Teams mode):**

| Permission | Why It Is Needed |
|---|---|
| `IdentityRiskEvent.Read.All` | Read Entra ID risky sign-in events and risk levels |
| `AuditLog.Read.All` | Read Entra ID sign-in logs and audit logs |
| `User.Read.All` | Resolve user profiles (UPN, account status, last sign-in) |
| `Directory.Read.All` | Read role assignments and Conditional Access policy metadata |
| `GroupMember.Read.All` | Resolve security group memberships |

**Requested only for `-CaseBackend xdr`/`sharepoint` (the default) — omitted entirely for `-CaseBackend sentinel`:**

| Permission | Why It Is Needed |
|---|---|
| `SecurityAlert.Read.All` | Read Defender XDR and M365 Defender alerts |
| `SecurityAlert.ReadWrite.All` | Update alert status and write comments |
| `SecurityIncident.Read.All` | Read Defender XDR incidents (polling loop) |
| `SecurityIncident.ReadWrite.All` | Write investigation comments, verdict tags, and classification |
| `ThreatHunting.Read.All` | Execute Advanced Hunting KQL queries against all Device\* and LogManagement tables |

> **Why `-CaseBackend sentinel` needs none of these:** that backend never calls `graph.microsoft.com/security/*` at all — it reads/writes `Microsoft.SecurityInsights/incidents` directly against `management.azure.com` (ARM) and `api.loganalytics.io` (KQL) instead. A tenant with no Defender XDR/M365 license has nothing behind these scopes to grant access to in the first place; requesting them anyway would be a pure trust cost on the consent screen with zero functional benefit. See §2 below for exactly what `sentinel` touches instead.

**Requested only for `-TeamsMode full` (the default) — omitted for `webhook_only`/`none`:**

| Permission | Why It Is Needed |
|---|---|
| `ChannelMessage.Read.All` | Read Teams channel replies to detect customer responses |

> **Why `webhook_only`/`none` don't need it:** this permission gates the Graph delta-query call (`/teams/{id}/channels/{id}/messages/delta`) that only succeeds when the Team lives in the **same Entra tenant** as this app registration. Posting verdict cards, and delivering the investigation report, both go via the Incoming Webhook URL and need no Graph permission at all — it's an unauthenticated HTTPS POST to the webhook — which is why `webhook_only` still gets full posting and report delivery for a Team in a different tenant, while only reply-polling never would.
>
> **No Graph permission is requested for report delivery at all, in any `-TeamsMode`.** The agent's app registration never touches the Teams channel's SharePoint drive. Instead, the investigation report rides as an extra field (`report: {filename, contentBase64}`) in the same webhook POST as the card, and the **customer's own Power Automate flow** — using its own SharePoint connection, authorized separately by whoever built the flow, never this app registration's credentials — writes it to the channel's Shared Documents and posts the link back as a follow-up message. This is a genuine security-posture improvement over the prior design (which used this app's own `Sites.ReadWrite.All` Graph grant against `/groups/{team_id}/drive`): the file write is now performed by an identity the customer already controls and can audit independently, not by EasySOC's app registration. See the Preparation Guide's Step 2b for what the customer's flow needs to do.
>
> No separate **SharePoint Online** permission (the legacy resource `00000003-0000-0ff1-ce00-…`, a leftover from the retired SP-Lists native-comments REST path) is requested either — it was already unused before this change and remains so.

### 1.2 RBAC (assigned by the script — see Preparation Guide, Step 3)

| Role | Scope | Assigned when | Why It Is Needed |
|---|---|---|---|
| Microsoft Sentinel Reader | Log Analytics workspace resource | A Sentinel workspace is selected (any `-CaseBackend`) | Allows KQL queries against the Sentinel workspace (`api.loganalytics.io`) — without this role all Sentinel queries return HTTP 403 |
| Microsoft Sentinel Responder | Log Analytics workspace resource | A Sentinel workspace is selected (any `-CaseBackend`, not just `sentinel`) | **New.** Write access to Sentinel incidents (labels/comments/classification) — required for `-CaseBackend sentinel`'s write path. Assigned unconditionally alongside Reader so a tenant prepared with `-CaseBackend xdr` can be switched to `sentinel` later without a second manual role grant |
| **Monitoring Metrics Publisher** | **The audit Data Collection Rule `dcr-easysoc-<customer-id>`** | **Always (when a Sentinel workspace is selected)** | **New.** Lets the agent POST its own investigation audit rows to the Logs Ingestion API endpoint. Scoped to the one DCR, not the workspace — it grants no read of any customer table. Without it the write fails 403 and the agent falls back to the JSONL file on the Azure Files share |

---

## 2. Tenant Resources the Agent Touches

| Resource | Service | Access Mode | Requested for | What the Agent Does With It |
|---|---|---|---|---|
| Security incidents | Defender XDR | Graph Security API | `xdr`/`sharepoint` | Polls for open incidents; reads title, status, alerts list; writes comments, verdict classification, and `EasySOC:*` custom tags |
| Security alerts | Defender XDR | Graph Security API | `xdr`/`sharepoint` | Reads alert details, evidence entities, and techniques; updates alert status |
| Advanced Hunting telemetry | Defender XDR | Graph Security API (`/security/runHuntingQuery`) | `xdr`/`sharepoint` | Runs read-only KQL queries to retrieve device, identity, email, and alert events for investigation |
| **Sentinel incidents** | **Microsoft Sentinel** | **ARM REST (`management.azure.com/…/Microsoft.SecurityInsights/incidents`) for writes; Log Analytics KQL (`api.loganalytics.io`) for reads** | **`sentinel` only** | **Polls `SecurityIncident` via KQL for open/replied incidents; reads/writes the same `EasySOC:*` state via `properties.labels` (Sentinel's label array, not Graph's `customTags`); writes comments (`properties.message`) and resolution classification via ARM PUT; polls the incident's own comments (ARM GET, not KQL — avoids the few-minutes Log Analytics ingestion lag on the human-reply-detection path) to detect a customer's reply, distinguishing it from the agent's own comments by Entra object ID** |
| User profiles | Entra ID | Graph API (`/users`) | Always | Resolves UPN, display name, account status, job title, department, last sign-in time |
| Group memberships | Entra ID | Graph API (`/users/{id}/memberOf`) | Always | Resolves security group membership for context enrichment |
| Directory data | Entra ID | Graph API | Always | Reads role assignments and Conditional Access policy metadata |
| Identity risk events | Entra ID Identity Protection | Graph API | Always | Reads risk level and risk detail per user sign-in |
| Audit logs | Entra ID | Graph API | Always | Reads sign-in log data (sign-in time, location, MFA status, CA evaluation) |
| Teams channel messages | Microsoft Teams | Graph API | `-TeamsMode full` only | Reads channel message replies to detect customer responses to information requests |
| Teams webhook (posting + report delivery) | Microsoft Teams | Unauthenticated HTTPS POST to the Incoming Webhook URL | `-TeamsMode full` or `webhook_only` | Posts verdict cards, and carries the investigation report (TP, FP/Benign, Info Request) as a base64 field alongside the card. Works across Entra tenants — no Graph permission or token involved, just the webhook URL itself as the credential. **The agent itself never touches the Teams channel's SharePoint drive** — writing the report there is the customer's own Power Automate flow's job, using a SharePoint connection this app registration has no part in |
| Log Analytics workspace | Microsoft Sentinel | Log Analytics REST API (`api.loganalytics.io`) | Always (when Sentinel is configured) | Executes KQL queries for Sentinel-native tables (SigninLogs, SecurityEvent, AzureActivity, UEBA) — and, for `sentinel`, also the incident/case data itself (see above) |
| Azure Files share | Azure Storage | Storage account key | Always | Persists audit JSONL logs and customer environment facts across container restarts |
| **Audit Data Collection Endpoint** | **Azure Monitor** | **Created by `Prepare-Tenant.ps1` as `dce-easysoc-<customer-id>`** | **Always (when a Sentinel workspace is selected)** | **The HTTPS ingestion endpoint the agent POSTs audit rows to. Public network access enabled; no customer data flows in through it except the agent’s own rows** |
| **Audit Data Collection Rule** | **Azure Monitor** | **Created as `dcr-easysoc-<customer-id>`; agent holds Monitoring Metrics Publisher on it** | **Always (when a Sentinel workspace is selected)** | **Declares the 24 columns of `EasySOC_Audit_CL` and routes them to the customer’s own workspace with `transformKql: source`. A field the rule does not declare is discarded silently with HTTP 204** |
| **`EasySOC_Audit_CL` custom table** | **Microsoft Sentinel / Log Analytics** | **Created in the customer’s own workspace; agent writes via the Logs Ingestion API, reads via KQL** | **Always (when a Sentinel workspace is selected)** | **The agent’s own investigation record: one row per completed investigation. Incident and investigation ID, the rendered audit report, cost/token/duration/call counts, and the harness’s decision scalars (`Band_s`, `Branch_s`, `Separation_d`, `Entropy_d`, `DisagreementMargin_d`, `Caps_s`, three context counts and four flags). **It never leaves the tenant** — it is written into the customer’s workspace and read back from it on a resumed case, and nothing in it is sent to EasySOC. Retention follows the workspace’s own setting** |
| Log Analytics workspace (same one, deploy-time only) | Azure Container Instances | Workspace shared key, passed to `az container create --log-analytics-workspace-key` | Always (when Sentinel is configured) | **Not** an agent access right — used only by `deploy-aci.ps1`, at container-group creation, to turn on ACI's built-in diagnostic pipe so `soc-agent`'s stdout/stderr lands in `ContainerInstanceLog_CL` in the customer's own workspace. The key is retrieved by the partner engineer's own `az` session in `Prepare-Tenant.ps1` (their Contributor credentials, not the agent's service principal) and never transmitted to EasySOC. See [Partner Tenant Preparation Guide](./Partner%20Tenant%20Preparation%20Guide.md) for why the Azure Portal can't configure this |

### 2.1 Tables Used in Investigations

All queries are read-only, time-bounded, and filtered to the incident's entities (host, user, IP, file hash).

**Defender XDR Advanced Hunting** (`xdr`/`sharepoint` case backends only — irrelevant to `sentinel`, which routes the equivalent Device*/identity telemetry through Sentinel's own forwarded copies instead, when a Defender connector or streaming forwarding is enabled)

| Category | Tables | Data Retrieved |
|---|---|---|
| Endpoint | `DeviceProcessEvents`, `DeviceNetworkEvents`, `DeviceFileEvents`, `DeviceRegistryEvents`, `DeviceImageLoadEvents`, `DeviceEvents`, `DeviceLogonEvents`, `DeviceInfo` | Process chains, network/DNS/HTTP connections, file and registry changes, DLL loads, behavioral detections, logons, device metadata |
| Alerts & Email | `AlertInfo`, `AlertEvidence`, `EmailEvents` | Alert titles/categories/techniques, raw evidence entities, email delivery and attachments |
| Identity | `IdentityLogonEvents`, `IdentityInfo` | AD/Entra authentication events and account snapshots (primary when an MDI sensor is present) |
| Entra logs (LogManagement) | `SigninLogs`, `AADNonInteractiveUserSignInLogs`, `AADServicePrincipalSignInLogs`, `AADManagedIdentitySignInLogs`, `MicrosoftGraphActivityLogs`, `AuditLogs` | Interactive/non-interactive/service-principal/managed-identity sign-ins, Graph activity, and Entra admin operations — available in Advanced Hunting without a Sentinel workspace |

**Microsoft Sentinel workspace** (queried whenever Sentinel is configured, any case backend; **also the incident/case store itself for `-CaseBackend sentinel`**)

| Table | Data Retrieved |
|---|---|
| `SecurityEvent` | Windows Security Event Log logon events (Event IDs 4624, 4625, 4648) |
| `AzureActivity` | Azure control-plane operations: resource creation, role changes, policy assignments |
| `BehaviorAnalytics` / `UserPeerAnalytics` | UEBA anomaly scores and peer group baseline deviations |
| `SecurityIncident` | **`sentinel` case backend only** — the incident objects themselves (title, description, status, labels, comments) |

---

## 3. External Services

The inference endpoint is required; threat-intelligence APIs are optional and can be omitted for the POC.

| Service | Endpoint | Purpose | Credential |
|---|---|---|---|
| **Inference endpoint** | Azure AI Foundry (`<resource>.services.ai.azure.com`), `api.anthropic.com`, **or** Azure OpenAI (`<resource>.cognitiveservices.azure.com`) if `-LlmBackend azure_openai` | LLM inference — all investigation reasoning done by the configured model | `ANTHROPIC_API_KEY` (Foundry resource key, or EasySOC-provided key for the POC fallback) — **or** `AZURE_OPENAI_API_KEY` (Azure OpenAI resource key; no POC fallback for this backend) |
| **VirusTotal** | `www.virustotal.com/api/v3` | IP reputation scoring and file hash lookup | `VIRUSTOTAL_API_KEY` (optional) |
| **AbuseIPDB** | `api.abuseipdb.com/api/v2` | IP abuse confidence score (90-day reporting window) | `ABUSEIPDB_API_KEY` (optional) |
| **IPInfo** | `api.ipinfo.io/lite` | IP geolocation and ASN data | `IPINFO_TOKEN` (optional) |
| **EasySOC container registry** | `easysoccr-gyfwc2acakhmg5h0.azurecr.io` | Pull the agent container image at deploy time | ACR pull token (pre-filled in the deploy script by EasySOC) |
| **EasySOC control endpoint** | EasySOC server (HTTPS) | License validation, runtime prompt delivery, operational telemetry (heartbeat + per-investigation metrics), and per-true-positive threat-intelligence submissions | Per-tenant license token (provided by EasySOC) |

> **Data sovereignty target:** for a fully data-sovereign deployment, use an **Azure AI Foundry** Claude deployment (default) **or an Azure OpenAI deployment** (`-LlmBackend azure_openai`) in the customer's own tenant so inference traffic stays on the customer's Azure bill and within their boundary. The public `api.anthropic.com` (with an EasySOC-provided key) is a POC fallback only available on the Anthropic backend.

---

## 4. What Leaves the Tenant — Data Sovereignty Boundary

Customer-environment data (hostnames, user identities/UPNs, internal IPs, file paths, raw alert/log content, and the agent's investigation reasoning) **stays in the tenant**. Investigation reasoning is sent only to the inference endpoint; it is never stored by EasySOC. This holds identically regardless of `-CaseBackend`/`-TeamsMode` — those choices only change *which Azure/Microsoft 365 APIs* the agent calls in-tenant, not what crosses the tenant boundary.

The EasySOC control endpoint receives only operational and attacker-focused metadata, enforced by an allow-list on **both** the agent and the server (any unexpected field is rejected):

- **Operational telemetry** — agent version, prompt-bundle version, uptime, per-investigation counts, verdict, confidence, cost/duration metrics, coarse error categories, and an opaque incident identifier. No customer data.
- **Threat-intelligence submission (true-positive incidents only)** — one record per confirmed true positive containing: MITRE technique IDs, kill-chain stage, the names of the evidence sources used (generic table/query labels, not their contents), and **attacker-controlled indicators only** — external/public IPs, domains, URLs, file hashes, and CVEs. Customer device hostnames, internal IPs, and user email/UPN identities are deterministically excluded.

These submissions are best-effort and never block or alter an investigation.

> **Container logs (optional, in-tenant only):** if a Log Analytics workspace shared key was retrieved during preparation (see §2), the agent's stdout/stderr also lands in `ContainerInstanceLog_CL` in the **customer's own** workspace via ACI's built-in diagnostic integration — this is a durable, queryable copy of the same log stream `az container logs` already shows, staying entirely within the customer's tenant/subscription. It is not sent to EasySOC and is not a new egress path.

### 4.1 ⚠️ Custom Detection Names — the one egress to check at preparation time

The threat-intelligence submission also includes the **incident name and the names of the alerts** that fired. For Microsoft's built-in detections these names are generic and contain no customer data.

**If your team authors custom detection rules, do not embed user names, hostnames, IP addresses, or other customer-identifying data in the rule/alert title** — those titles are transmitted with the true-positive TI record. Built-in detections are unaffected. Verify custom-detection titles before onboarding (Prerequisites pre-flight checklist, row 13). This applies to Defender custom detections (`xdr`/`sharepoint`) and equally to Sentinel analytics-rule names (`sentinel`, or Sentinel-sourced incidents under `xdr`/`sharepoint`).

---

## 5. Outbound Connectivity (egress allow-list)

The container makes **outbound HTTPS only** — no inbound ports are opened. If the customer enforces egress filtering, allow the rows relevant to your `-CaseBackend`/`-TeamsMode` choice:

| Destination | Required? | Purpose |
|---|---|---|
| `<resource>.services.ai.azure.com` (Foundry), `api.anthropic.com`, **or** `<resource>.cognitiveservices.azure.com` (Azure OpenAI, if used) | **Yes** | LLM inference |
| `easysoccr-gyfwc2acakhmg5h0.azurecr.io` | Yes | Container image pull |
| EasySOC control endpoint (HTTPS) | Yes | License, prompts, telemetry, TI |
| `graph.microsoft.com` | Yes for `-CaseBackend xdr`/`sharepoint`, or if `-TeamsMode full` (identity/context calls always use Graph regardless, so this is effectively always required in practice — see §1.1's "always requested" set) | Defender incidents/alerts, Advanced Hunting, Entra, Teams |
| `management.azure.com` | Yes for `-CaseBackend sentinel` only | Sentinel incident write path (ARM REST: labels, comments, classification) |
| `api.loganalytics.io` | Yes (if Sentinel used — i.e. always, per §1) | Sentinel KQL queries; also the Sentinel incident read path for `-CaseBackend sentinel` |
| Teams Workflows webhook host (e.g. `*.logic.azure.com` / Power Platform) | Yes if `-TeamsMode full` or `webhook_only` | Posting verdict cards and delivering the investigation report |
| `<storage>.file.core.windows.net` | Yes | Audit volume (Azure Files) |
| `www.virustotal.com`, `api.abuseipdb.com`, `api.ipinfo.io` | Optional | Threat-intel enrichment |
