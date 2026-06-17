# EasySOC — Tenant Prerequisites v6

> **Audience:** Partner technical engineer responsible for customer tenant preparation
> **Purpose:** Definitive checklist of the **resources, licenses, and services that must already exist** in the customer's Microsoft 365 / Azure tenant before EasySOC onboarding begins
> **Scope:** Prerequisites only — the "is the tenant ready?" gate.
> - The step-by-step run procedure is in **[Partner Tenant Preparation Guide](./Partner%20Tenant%20Preparation%20Guide.md)**.
> - The agent's access rights, the data it touches, what leaves the tenant, and the egress allow-list are in **[Tenant Data Sovereignty and Access](./Tenant%20Data%20Sovereignty%20and%20Access.md)**.
> **Last updated:** 2026-06-17
> **Supersedes:** Tenant Prerequisites v5 — corrects the ACR pull-token row in §8: `$AcrPullPassword` is **not** pre-filled in `deploy-aci.ps1`; it ships blank and the partner engineer must paste it into the PROVIDER section before deploying (the deploy script fails fast with `AcrPullPassword is required` otherwise).

---

## 0. Responsibility Split — Read This First

The EasySOC onboarding has three distinct phases. This document covers **only Phase A** — the resources you must stand up before any script runs.

| Phase | Who | What | Tooling |
|---|---|---|---|
| **A — Tenant prerequisites** | **Partner engineer (you)** | Stand up XDR, Sentinel, the Teams channel, and the Azure AI Foundry inference endpoint; ensure licensing, admin roles, and an Azure subscription are in place | Manual / partner's own automation |
| B — App registration + storage | `Prepare-Tenant.ps1` | App registration, Graph permissions, admin consent, client secret, **Azure Storage account + Files share**, Sentinel Reader role; writes `easysoc-deploy.config.ps1` | Provided by EasySOC |
| C — Container deployment | `deploy-aci.ps1` | Dot-sources `easysoc-deploy.config.ps1`, pulls the agent image, injects env vars, mounts the audit volume, starts the container | Provided by EasySOC |

**Key point:** the **storage account is created by the script (Phase B)** — do *not* pre-create it. Everything in Sections 1–7 below is your responsibility and must be done first, because Phase B/C scripts assume these resources exist and fail or silently misbehave if they don't.

---

## 1. Licensing

| Requirement | Detail | Why the agent needs it |
|---|---|---|
| Microsoft 365 Business Premium **or** Defender for Business P2 | Per protected user/device | Provides Defender XDR endpoint + identity telemetry and the Advanced Hunting `Device*` tables the specialists query |
| Microsoft Sentinel (pay-as-you-go on a Log Analytics workspace) | Workspace-based billing | Provides Sentinel-only tables (`SecurityEvent`, `AzureActivity`, UEBA) and analytics-rule-driven incidents |
| Azure subscription | Any tier with Contributor available to the engineer | Hosts the Foundry resource, the storage account (script-created), and the Container Instance |
| Microsoft Teams (included in M365 BP) | — | Output channel for verdict cards and the human feedback loop |

> The agent's SIEM router runs in `tenant_sku: business_premium` posture by default — endpoint and identity telemetry come from Defender XDR Advanced Hunting; Sentinel supplies the tables XDR does not expose.

---

## 2. Microsoft Defender XDR (mandatory — primary data source)

The agent's **case backend is Defender XDR**: Defender incidents are the case object (no SharePoint list is created for the POC). Defender Advanced Hunting is also the dominant investigation telemetry source.

**Prerequisites:**

- [ ] Defender XDR portal active and licensed (see §1).
- [ ] **Device onboarding complete** — endpoints reporting into Defender for Endpoint, so `DeviceProcessEvents`, `DeviceNetworkEvents`, `DeviceFileEvents`, `DeviceRegistryEvents`, `DeviceImageLoadEvents`, `DeviceEvents`, `DeviceLogonEvents`, and `DeviceInfo` carry data.
- [ ] **Advanced Hunting available** — confirm queries return rows in the Defender portal (Hunting → Advanced hunting). The agent calls `/security/runHuntingQuery` via the Graph Security API.
- [ ] At least one detection source producing incidents (built-in Defender detections are sufficient). Custom detections are fine — but see the custom-detection naming warning in the Data Sovereignty & Access doc.
- [ ] **(Identity, recommended)** If a Microsoft Defender for Identity (MDI) sensor is deployed, `IdentityLogonEvents` / `IdentityInfo` populate and become the primary identity authentication source.

**LogManagement tables in Advanced Hunting** (no Sentinel workspace required): `SigninLogs`, `AADNonInteractiveUserSignInLogs`, `AADServicePrincipalSignInLogs`, `AADManagedIdentitySignInLogs`, `MicrosoftGraphActivityLogs`, `AuditLogs`. These appear in AH automatically on Business Premium tenants — no Entra diagnostic-settings export is required for the agent to read them.

---

## 3. Microsoft Sentinel (mandatory for full coverage)

Sentinel supplies tables Defender XDR does not expose, and its analytics rules generate incidents.

**Prerequisites:**

- [ ] **Log Analytics workspace deployed** and Microsoft Sentinel enabled on it.
- [ ] **Record the workspace `customerId` (GUID)** — `Prepare-Tenant.ps1` auto-discovers workspaces, but recording the GUID lets you pass `-SentinelWorkspaceId` explicitly. Without a workspace selected, the Sentinel Reader role is not assigned and every Sentinel KQL query returns **HTTP 403** at runtime.
  ```powershell
  az monitor log-analytics workspace show --resource-group <RG> --workspace-name <WS> --query customerId -o tsv
  ```
- [ ] **Data connectors enabled** so the Sentinel-routed tables exist and carry data:
  - `SecurityEvent` — Windows Security Events (for `authentication` Windows leg, Event IDs 4624/4625/4648)
  - `AzureActivity` — Azure control-plane operations
  - `BehaviorAnalytics` / `UserPeerAnalytics` — UEBA; requires UEBA enabled in Sentinel
- [ ] **Analytics rules enabled** — built-in scheduled/Fusion rules so Sentinel actually raises incidents for the agent to investigate.

> A missing table is non-fatal but reduces coverage: the agent receives an `HTTP 400 … could not be resolved` and reports a telemetry gap rather than crashing. Enable the connector to close the gap.

---

## 4. Microsoft Teams Channel (output + feedback loop)

The agent posts verdict cards via a **Workflows webhook** and **polls the same channel for customer replies** via the Graph API. The channel's auto-provisioned document library also receives uploaded HTML reports.

**Prerequisites (the channel resource — webhook *creation* is a run step in the Preparation Guide):**

- [ ] A **standard** channel created for EasySOC output. **Must be standard** — private/shared channels lack a compatible drive and break report uploads.
- [ ] The channel's **Shared Documents** library exists (auto-provisioned with the Team — no separate SharePoint site/list to create).
- [ ] A **Team member or owner account** available to create the Workflows webhook. The account that creates the workflow must be a Member or Owner of the Team — not merely a tenant admin (a non-member admin gets a URL, but posts are silently dropped).

> The webhook URL, Team ID, and Channel ID are collected during the run procedure (Preparation Guide, Step 2) — they are the one value set the script cannot auto-discover. Teams output is technically optional (blank to disable) but is the intended POC interface.

---

## 5. Azure AI Foundry — LLM Inference Endpoint (recommended target)

All investigation reasoning is done by Claude. For a data-sovereign deployment the inference endpoint should be **Azure AI Foundry in the customer's own tenant**, so LLM traffic stays on the customer's Azure bill and within their Azure boundary. The agent routes through it via the Anthropic-compatible Foundry endpoint (`ANTHROPIC_BASE_URL` + `ANTHROPIC_API_KEY`).

**Prerequisites:**

- [ ] **Azure AI Foundry resource provisioned** in the customer subscription, in a region offering the Anthropic/Claude models. `Prepare-Tenant.ps1` auto-discovers these resources and offers to wire up the endpoint and key for you.
- [ ] **A Claude model deployed** matching the project's configured model. The whole project uses a single model tier (Supervisor, specialists, and  helpers all resolve to it).
- [ ] **Endpoint URL and key recorded:**
  - `ANTHROPIC_BASE_URL` = the deployment's Anthropic endpoint, e.g. `https://<resource>.services.ai.azure.com/anthropic` (the SDK normalises to `…/anthropic/`).
  - `ANTHROPIC_API_KEY` = the Foundry resource key.
- [ ] **Quota / rate limits reviewed.** Each tenant uses its **own** Foundry deployment with its own budget. Default deployment caps are **80,000 TPM** and **80 RPM**.
  - **TPM is the binding constraint.** A single supervisor turn is ~60–70k tokens, and parallel specialist dispatch can push the peak rolling minute over 80k on True-Positive / multi-specialist investigations.
  - These spikes are absorbed by the SDK's automatic 429 retry/backoff (added latency, not failures) for normal volume. **For higher expected volume, request a TPM quota increase** on the deployment.

> **POC fallback:** the agent also runs against the public Anthropic API (`ANTHROPIC_BASE_URL` blank → `api.anthropic.com`, with an EasySOC-provided key). Use this only if a Foundry resource is not yet available; it routes inference outside the customer tenant and is not the data-sovereign target.

---

## 6. Azure Subscription & Resource Providers

The agent runs as an Azure Container Instance; the script creates the storage account.

**Prerequisites:**

- [ ] An Azure subscription the engineer can deploy into, with **Contributor** on the target resource group (or subscription).
- [ ] Ability to **register resource providers** (included in Contributor). The scripts auto-register what they need:
  - `Prepare-Tenant.ps1` registers `Microsoft.Storage` (a clean subscription otherwise fails storage creation with a misleading `SubscriptionNotFound`).
  - `deploy-aci.ps1` registers `Microsoft.ContainerInstance`.
- [ ] **Azure CLI installed** on the engineer's workstation (`az --version`).
- [ ] If Foundry is in this subscription, also ensure the AI / Cognitive Services provider is registered (typically done by Foundry provisioning).

> **Do NOT pre-create the storage account** — `Prepare-Tenant.ps1` provisions a `StorageV2` account (`Standard_LRS`, TLS 1.2, public blob access off) and a 5 GiB Azure Files share for the audit volume. The container mounts it at `/app/audit`.

> **Duplicate subscription names:** a tenant can hold multiple subscriptions with the same display name. The script lists and selects by **subscription ID**; pick by ID when prompted.

---

## 7. Identity & Admin Roles (the engineer running preparation)

These are the roles **you** must hold to run Phase B/C. They are a readiness gate — the agent's own service-principal access rights are documented separately in the Data Sovereignty & Access doc.

| Role | Needed for | Notes |
|---|---|---|
| **Application Administrator** (or Global Administrator) in the customer Entra ID tenant | Create the app registration and **grant admin consent** | **Critical.** Contributor alone is not enough. Without this, the script still completes and writes the config file, but admin consent is silently skipped → the agent gets **403 on every Graph call** at runtime |
| **Contributor** on the target resource group / subscription | Create the storage account, register providers, deploy the container, assign the Sentinel Reader role | Global Admin does not include Azure RBAC by default — ensure Contributor is also held |

> The app registration (created by Phase B) requests **12 Microsoft Graph application permissions** plus the **Microsoft Sentinel Reader** RBAC role. You do not configure these by hand — the script does — but admin consent for them requires the roles above. The full permission list and rationale are in **[Tenant Data Sovereignty and Access](./Tenant%20Data%20Sovereignty%20and%20Access.md)**.

---

## 8. Items Provided by EasySOC (not partner-sourced)

For completeness — these are handed to you, not prepared in the tenant:

| Item | Used as | Notes |
|---|---|---|
| Agent container image | `easysoc.azurecr.io/soc-agent` | Pulled at deploy time |
| ACR pull token | `$AcrPullPassword` | **You must paste it into the PROVIDER section of `deploy-aci.ps1` before deploying** — the script ships with `$AcrPullPassword` **blank** and stops with `AcrPullPassword is required (PROVIDER section).` if it is left empty (see Preparation Guide Step 4) |
| EasySOC license token | `BOOTSTRAP_TOKEN` | Per-tenant; license validation + runtime prompt delivery |
| EasySOC control endpoint URL | `BOOTSTRAP_URL` | License, prompt bundle, telemetry/TI submission |
| Anthropic API key (POC only) | `ANTHROPIC_API_KEY` | Only if not using customer Foundry (see §5) |

---

## 9. Pre-Flight Readiness Checklist

Run through this before invoking `Prepare-Tenant.ps1`:

| # | Prerequisite | Verified |
|---|---|---|
| 1 | M365 Business Premium / Defender for Business P2 licensed | ☐ |
| 2 | Defender XDR active; devices onboarded; Advanced Hunting returns rows | ☐ |
| 3 | Sentinel workspace deployed; workspace `customerId` GUID recorded | ☐ |
| 4 | Sentinel connectors enabled (`SecurityEvent`, `AzureActivity`, UEBA as needed) | ☐ |
| 5 | Sentinel analytics rules enabled (incidents are being generated) | ☐ |
| 6 | **Standard** Teams channel created; a Team member/owner available to create the webhook | ☐ |
| 7 | Azure AI Foundry resource + Claude deployment; endpoint URL + key recorded; quota reviewed | ☐ |
| 8 | Azure subscription with Contributor; subscription **ID** confirmed | ☐ |
| 9 | Engineer holds **Application Administrator/Global Admin** (consent) **and** Contributor (Azure) | ☐ |
| 10 | Azure CLI installed (`az --version`) | ☐ |
| 11 | **ACR pull-token password received from EasySOC** (to paste into `deploy-aci.ps1` `$AcrPullPassword`) | ☐ |
| 12 | Egress allow-list updated, if filtering is enforced (see Data Sovereignty & Access doc) | ☐ |
| 13 | Custom-detection titles checked for embedded customer identifiers (see Data Sovereignty & Access doc) | ☐ |
| 14 | Storage account **NOT** pre-created (script provisions it) | ☐ |

When all rows are checked, proceed to **[Partner Tenant Preparation Guide](./Partner%20Tenant%20Preparation%20Guide.md)** for the step-by-step preparation and deployment run.
