# EasySOC — Tenant Data Sovereignty & Access v1

> **Audience:** Partner technical engineer, and the customer's security/compliance reviewer
> **Purpose:** Single reference for **what the agent can access, what data leaves the tenant, and the egress it requires** — the access-rights and data-residency picture, separated from the readiness checklist and the run procedure.
> **Companion docs:**
> - Resources/licenses/services to stand up first → **[Tenant Prerequisites](./Tenant%20Prerequisites.md)**
> - Step-by-step run + deploy procedure → **[Partner Tenant Preparation Guide](./Partner%20Tenant%20Preparation%20Guide.md)**
> **Last updated:** 2026-06-17
> **Supersedes:** consolidates the access/data-sovereignty material previously split across Tenant Prerequisites v4 (§9 egress, §10 custom-detection note) and Partner Tenant Preparation Guide v8 (§1.1–§1.5).

The only data that ever leaves the tenant goes to three destinations: the **inference endpoint** (LLM reasoning), the three **optional threat-intelligence APIs**, and the **EasySOC control endpoint** (licensing, prompt delivery, and operational telemetry / threat-intel). All are outbound-only HTTPS calls initiated by the container — no inbound ports are opened.

---

## 1. Application Permissions (the agent's access rights)

The app registration created by `Prepare-Tenant.ps1` requests the following, all of type **Application** (no user delegation — the agent runs as itself). You do not configure these by hand; they are listed here so the customer can review exactly what the agent is granted.

### 1.1 Microsoft Graph (12 permissions)

| Permission | Why It Is Needed |
|---|---|
| `SecurityAlert.Read.All` | Read Defender XDR and M365 Defender alerts |
| `SecurityAlert.ReadWrite.All` | Update alert status and write comments |
| `SecurityIncident.Read.All` | Read Defender XDR incidents (polling loop) |
| `SecurityIncident.ReadWrite.All` | Write investigation comments, verdict tags, and classification |
| `ThreatHunting.Read.All` | Execute Advanced Hunting KQL queries against all Device\* and LogManagement tables |
| `IdentityRiskEvent.Read.All` | Read Entra ID risky sign-in events and risk levels |
| `AuditLog.Read.All` | Read Entra ID sign-in logs and audit logs |
| `User.Read.All` | Resolve user profiles (UPN, account status, last sign-in) |
| `Directory.Read.All` | Read role assignments and Conditional Access policy metadata |
| `GroupMember.Read.All` | Resolve security group memberships |
| `ChannelMessage.Read.All` | Read Teams channel replies to detect customer responses |
| `Sites.ReadWrite.All` | Upload investigation reports to the Teams channel's Shared Documents (document library) |

> No separate **SharePoint Online** permission is requested — report uploads use the Graph `Sites.ReadWrite.All` above against the Teams channel's drive (`/groups/{team_id}/drive`). The earlier separate *SharePoint Online* `Sites.ReadWrite.All` (resource `00000003-0000-0ff1-ce00-…`) was a leftover from the retired SP-Lists native-comments REST path and is no longer requested.

### 1.2 RBAC (assigned by the script — see Preparation Guide, Step 3)

| Role | Scope | Why It Is Needed |
|---|---|---|
| Microsoft Sentinel Reader | Log Analytics workspace resource | Allows KQL queries against the Sentinel workspace (`api.loganalytics.io`) — without this role all Sentinel queries return HTTP 403 |

---

## 2. Tenant Resources the Agent Touches

| Resource | Service | Access Mode | What the Agent Does With It |
|---|---|---|---|
| Security incidents | Defender XDR | Graph Security API | Polls for open incidents; reads title, status, alerts list; writes comments, verdict classification, and `EasySOC:*` custom tags |
| Security alerts | Defender XDR | Graph Security API | Reads alert details, evidence entities, and techniques; updates alert status |
| Advanced Hunting telemetry | Defender XDR | Graph Security API (`/security/runHuntingQuery`) | Runs read-only KQL queries to retrieve device, identity, email, and alert events for investigation |
| User profiles | Entra ID | Graph API (`/users`) | Resolves UPN, display name, account status, job title, department, last sign-in time |
| Group memberships | Entra ID | Graph API (`/users/{id}/memberOf`) | Resolves security group membership for context enrichment |
| Directory data | Entra ID | Graph API | Reads role assignments and Conditional Access policy metadata |
| Identity risk events | Entra ID Identity Protection | Graph API | Reads risk level and risk detail per user sign-in |
| Audit logs | Entra ID | Graph API | Reads sign-in log data (sign-in time, location, MFA status, CA evaluation) |
| Teams Drive (document library) | SharePoint / Teams | Graph API (`/sites/.../drive`) | Uploads investigation reports (TP, FP/Benign, Info Request) as HTML files to the Teams channel's Shared Documents |
| Teams channel messages | Microsoft Teams | Graph API | Reads channel message replies to detect customer responses to information requests |
| Log Analytics workspace | Microsoft Sentinel | Log Analytics REST API (`api.loganalytics.io`) | Executes KQL queries for Sentinel-native tables (SigninLogs, SecurityEvent, AzureActivity, UEBA) |
| Azure Files share | Azure Storage | Storage account key | Persists audit JSONL logs and customer environment facts across container restarts |

### 2.1 Tables Used in Investigations

All queries are read-only, time-bounded, and filtered to the incident's entities (host, user, IP, file hash).

**Defender XDR Advanced Hunting**

| Category | Tables | Data Retrieved |
|---|---|---|
| Endpoint | `DeviceProcessEvents`, `DeviceNetworkEvents`, `DeviceFileEvents`, `DeviceRegistryEvents`, `DeviceImageLoadEvents`, `DeviceEvents`, `DeviceLogonEvents`, `DeviceInfo` | Process chains, network/DNS/HTTP connections, file and registry changes, DLL loads, behavioral detections, logons, device metadata |
| Alerts & Email | `AlertInfo`, `AlertEvidence`, `EmailEvents` | Alert titles/categories/techniques, raw evidence entities, email delivery and attachments |
| Identity | `IdentityLogonEvents`, `IdentityInfo` | AD/Entra authentication events and account snapshots (primary when an MDI sensor is present) |
| Entra logs (LogManagement) | `SigninLogs`, `AADNonInteractiveUserSignInLogs`, `AADServicePrincipalSignInLogs`, `AADManagedIdentitySignInLogs`, `MicrosoftGraphActivityLogs`, `AuditLogs` | Interactive/non-interactive/service-principal/managed-identity sign-ins, Graph activity, and Entra admin operations — available in Advanced Hunting without a Sentinel workspace |

**Microsoft Sentinel workspace (queried only when Sentinel is configured)**

| Table | Data Retrieved |
|---|---|
| `SecurityEvent` | Windows Security Event Log logon events (Event IDs 4624, 4625, 4648) |
| `AzureActivity` | Azure control-plane operations: resource creation, role changes, policy assignments |
| `BehaviorAnalytics` / `UserPeerAnalytics` | UEBA anomaly scores and peer group baseline deviations |

---

## 3. External Services

The inference endpoint is required; threat-intelligence APIs are optional and can be omitted for the POC.

| Service | Endpoint | Purpose | Credential |
|---|---|---|---|
| **Inference endpoint** | Azure AI Foundry (`<resource>.services.ai.azure.com`) **or** `api.anthropic.com` | LLM inference — all investigation reasoning is done by Claude | `ANTHROPIC_API_KEY` (Foundry resource key, or EasySOC-provided key for the POC fallback) |
| **VirusTotal** | `www.virustotal.com/api/v3` | IP reputation scoring and file hash lookup | `VIRUSTOTAL_API_KEY` (optional) |
| **AbuseIPDB** | `api.abuseipdb.com/api/v2` | IP abuse confidence score (90-day reporting window) | `ABUSEIPDB_API_KEY` (optional) |
| **IPInfo** | `api.ipinfo.io/lite` | IP geolocation and ASN data | `IPINFO_TOKEN` (optional) |
| **EasySOC container registry** | `easysoc.azurecr.io` | Pull the agent container image at deploy time | ACR pull token (pre-filled in the deploy script by EasySOC) |
| **EasySOC control endpoint** | EasySOC server (HTTPS) | License validation, runtime prompt delivery, operational telemetry (heartbeat + per-investigation metrics), and per-true-positive threat-intelligence submissions | Per-tenant license token (provided by EasySOC) |

> **Data sovereignty target:** for a fully data-sovereign deployment, use an **Azure AI Foundry** Claude deployment in the customer's own tenant so inference traffic stays on the customer's Azure bill and within their boundary. The public `api.anthropic.com` (with an EasySOC-provided key) is a POC fallback only.

---

## 4. What Leaves the Tenant — Data Sovereignty Boundary

Customer-environment data (hostnames, user identities/UPNs, internal IPs, file paths, raw alert/log content, and the agent's investigation reasoning) **stays in the tenant**. Investigation reasoning is sent only to the inference endpoint; it is never stored by EasySOC.

The EasySOC control endpoint receives only operational and attacker-focused metadata, enforced by an allow-list on **both** the agent and the server (any unexpected field is rejected):

- **Operational telemetry** — agent version, prompt-bundle version, uptime, per-investigation counts, verdict, confidence, cost/duration metrics, coarse error categories, and an opaque incident identifier. No customer data.
- **Threat-intelligence submission (true-positive incidents only)** — one record per confirmed true positive containing: MITRE technique IDs, kill-chain stage, the names of the evidence sources used (generic table/query labels, not their contents), and **attacker-controlled indicators only** — external/public IPs, domains, URLs, file hashes, and CVEs. Customer device hostnames, internal IPs, and user email/UPN identities are deterministically excluded.

These submissions are best-effort and never block or alter an investigation.

### 4.1 ⚠️ Custom Detection Names — the one egress to check at preparation time

The threat-intelligence submission also includes the **incident name and the names of the alerts** that fired. For Microsoft's built-in detections these names are generic and contain no customer data.

**If your team authors custom detection rules, do not embed user names, hostnames, IP addresses, or other customer-identifying data in the rule/alert title** — those titles are transmitted with the true-positive TI record. Built-in detections are unaffected. Verify custom-detection titles before onboarding (Prerequisites pre-flight checklist, row 12).

---

## 5. Outbound Connectivity (egress allow-list)

The container makes **outbound HTTPS only** — no inbound ports are opened. If the customer enforces egress filtering, allow:

| Destination | Required? | Purpose |
|---|---|---|
| `<resource>.services.ai.azure.com` (Foundry) **or** `api.anthropic.com` | **Yes** | LLM inference |
| `easysoc.azurecr.io` | Yes | Container image pull |
| EasySOC control endpoint (HTTPS) | Yes | License, prompts, telemetry, TI |
| `graph.microsoft.com` | Yes | Defender incidents/alerts, Advanced Hunting, Entra, Teams |
| `api.loganalytics.io` | Yes (if Sentinel used) | Sentinel KQL queries |
| Teams Workflows webhook host (e.g. `*.logic.azure.com` / Power Platform) | Yes | Posting verdict cards |
| `<storage>.file.core.windows.net` | Yes | Audit volume (Azure Files) |
| `www.virustotal.com`, `api.abuseipdb.com`, `api.ipinfo.io` | Optional | Threat-intel enrichment |
