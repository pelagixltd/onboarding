# EasySOC — Tenant Prerequisites v11

> **Audience:** Partner technical engineer responsible for customer tenant preparation
> **Purpose:** Definitive checklist of the **resources, licenses, and services that must already exist** in the customer's Microsoft 365 / Azure tenant before EasySOC onboarding begins
> **Scope:** Prerequisites only — the "is the tenant ready?" gate.
> - The step-by-step run procedure is in **[Partner Tenant Preparation Guide](./Partner%20Tenant%20Preparation%20Guide.md)**.
> - The agent's access rights, the data it touches, what leaves the tenant, and the egress allow-list are in **[Tenant Data Sovereignty and Access](./Tenant%20Data%20Sovereignty%20and%20Access.md)**.
> **Last updated:** 2026-09-06
> **Supersedes:** Tenant Prerequisites v10 — two factual corrections, no procedural changes: (1) §8's agent container image referenced the retired `easysoc.azurecr.io` registry (confirmed dead via `az acr show -n easysoc` → `ResourceNotFound`); corrected to the current `easysoccr-gyfwc2acakhmg5h0.azurecr.io`, matching `deploy-aci.ps1`'s actual PROVIDER section. (2) Cross-references to the Partner Tenant Preparation Guide still pointed at v14, which has since moved to v16 — updated throughout.
> **Prior:** v9 removed `Sites.ReadWrite.All` / same-tenant Graph requirement for report delivery — see v10's own superseded history for detail. v8 added §0a (choosing a case backend) and reworked §2/§3/§4/§7/§9 to be conditional on `-CaseBackend`/`-TeamsMode`. v7 added §5a, an Azure OpenAI alternative to the Anthropic/Foundry inference backend (`-LlmBackend azure_openai`).

---

## 0. Responsibility Split — Read This First

The EasySOC onboarding has three distinct phases. This document covers **only Phase A** — the resources you must stand up before any script runs.

| Phase | Who | What | Tooling |
|---|---|---|---|
| **A — Tenant prerequisites** | **Partner engineer (you)** | Stand up the chosen case backend (Defender XDR, or Sentinel-only — see §0a), the Teams channel (if used), and the Azure AI Foundry inference endpoint; ensure licensing, admin roles, and an Azure subscription are in place | Manual / partner's own automation |
| B — App registration + storage | `Prepare-Tenant.ps1` | App registration, Graph permissions (set varies by `-CaseBackend`/`-TeamsMode` — see §0a), admin consent, client secret, **Azure Storage account + Files share**, Sentinel Reader + Responder roles; writes `easysoc-deploy.config.ps1` | Provided by EasySOC |
| C — Container deployment | `deploy-aci.ps1` | Dot-sources `easysoc-deploy.config.ps1`, pulls the agent image, injects env vars, mounts the audit volume, starts the container | Provided by EasySOC |

**Key point:** the **storage account is created by the script (Phase B)** — do *not* pre-create it. Everything in Sections 1–7 below is your responsibility and must be done first, because Phase B/C scripts assume these resources exist and fail or silently misbehave if they don't.

---

## 0a. Choosing a Case Backend and Teams Mode — Read This Before §2/§3/§4

Two `Prepare-Tenant.ps1` parameters determine which of the sections below actually apply to this tenant. Decide both **before** working through §1–§9, since they change what you need to stand up.

**`-CaseBackend` — where investigations live:**

| Value | Case object | When to use | Prerequisites |
|---|---|---|---|
| `xdr` (default) | Defender XDR incident (Graph Security API) | Tenant is licensed for Defender XDR/M365 (the common case) | §2 (Defender XDR) **and** §3 (Sentinel) both apply |
| `sentinel` | Microsoft Sentinel incident (read via KQL, written via ARM REST) | Tenant has **Sentinel but no Defender XDR/M365 license** — `/security/incidents` is permanently empty there, so `xdr` has nothing to read | §2 **does not apply at all** — skip it entirely. §3 (Sentinel) is the only case-source prerequisite, and becomes mandatory rather than "for full coverage" |
| `sharepoint` | SharePoint List, still backed by the underlying Defender XDR incident | Rare — a case-tracking UI requirement on top of XDR | Same as `xdr`: §2 **and** §3 both apply |

**`-TeamsMode` — how the agent talks to Teams:**

| Value | What works | When to use | Prerequisites |
|---|---|---|---|
| `full` (default) | Posting verdict cards, polling for customer replies, and report delivery | The Team lives in the **same Entra tenant** as the app registration `Prepare-Tenant.ps1` creates (needed for reply-polling specifically) | §4 in full — standard channel, Shared Documents, a Team-member account to create the webhook, and the webhook flow extended per the Preparation Guide's Step 2b |
| `webhook_only` | Posting verdict cards and report delivery (no reply-polling) | The only Teams access available is in a **different Entra tenant** — reply-polling needs same-tenant Graph access and would silently never work otherwise, but posting and report delivery work fine cross-tenant | §4's webhook-creation and flow-extension steps (Step 2b) — same as `full`; only the Team-membership/ID-retrieval steps needed for reply-polling do not apply |
| `none` | No Teams output at all | No Teams available, or a different notification channel is planned | §4 does not apply |

These two choices are independent of each other — e.g. `-CaseBackend sentinel -TeamsMode webhook_only` is the combination for a pure-Azure tenant with no M365 license and Teams access only in a separate tenant. Whichever you pick, tell EasySOC before Phase A so the run procedure ([Partner Tenant Preparation Guide](./Partner%20Tenant%20Preparation%20Guide.md)) uses the matching parameters.

---

## 1. Licensing

| Requirement | Detail | Why the agent needs it |
|---|---|---|
| Microsoft 365 Business Premium **or** Defender for Business P2 — **only for `-CaseBackend xdr`/`sharepoint` (default)** | Per protected user/device | Provides Defender XDR endpoint + identity telemetry and the Advanced Hunting `Device*` tables the specialists query. **Not required for `-CaseBackend sentinel`** — see §0a |
| Microsoft Sentinel (pay-as-you-go on a Log Analytics workspace) | Workspace-based billing | **Always required, regardless of `-CaseBackend`.** Provides Sentinel-only telemetry tables (`SecurityEvent`, `AzureActivity`, UEBA) always; is also the case-object source itself when `-CaseBackend sentinel` |
| Azure subscription | Any tier with Contributor available to the engineer | Hosts the Foundry resource, the storage account (script-created), and the Container Instance |
| Microsoft Teams (included in M365 BP) — **only if `-TeamsMode full`/`webhook_only`** | — | Output channel for verdict cards and (in `full` mode only) the human feedback loop. Not needed at all for `-TeamsMode none` |

> The agent's SIEM router runs in `tenant_sku: business_premium` posture by default — endpoint and identity telemetry come from Defender XDR Advanced Hunting; Sentinel supplies the tables XDR does not expose. A `-CaseBackend sentinel` tenant with no Defender XDR license at all should instead configure `tenant_sku: sentinel_only` (all SIEM queries routed to Sentinel) — flag this to EasySOC before deployment if it applies.

---

## 2. Microsoft Defender XDR (mandatory for `-CaseBackend xdr`/`sharepoint` — the default; **skip this entire section for `-CaseBackend sentinel`**)

The agent's **case backend is Defender XDR** when `-CaseBackend xdr` (the default) or `sharepoint`: Defender incidents are the case object. Defender Advanced Hunting is also the dominant investigation telemetry source for these two backends. **None of this applies to `-CaseBackend sentinel`** — that backend never calls the Defender/Graph Security API at all (see §0a and [Tenant Data Sovereignty and Access](./Tenant%20Data%20Sovereignty%20and%20Access.md) §1.1).

**Prerequisites:**

- [ ] Defender XDR portal active and licensed (see §1).
- [ ] **Device onboarding complete** — endpoints reporting into Defender for Endpoint, so `DeviceProcessEvents`, `DeviceNetworkEvents`, `DeviceFileEvents`, `DeviceRegistryEvents`, `DeviceImageLoadEvents`, `DeviceEvents`, `DeviceLogonEvents`, and `DeviceInfo` carry data.
- [ ] **Advanced Hunting available** — confirm queries return rows in the Defender portal (Hunting → Advanced hunting). The agent calls `/security/runHuntingQuery` via the Graph Security API.
- [ ] At least one detection source producing incidents (built-in Defender detections are sufficient). Custom detections are fine — but see the custom-detection naming warning in the Data Sovereignty & Access doc.
- [ ] **(Identity, recommended)** If a Microsoft Defender for Identity (MDI) sensor is deployed, `IdentityLogonEvents` / `IdentityInfo` populate and become the primary identity authentication source.

**LogManagement tables in Advanced Hunting** (no Sentinel workspace required): `SigninLogs`, `AADNonInteractiveUserSignInLogs`, `AADServicePrincipalSignInLogs`, `AADManagedIdentitySignInLogs`, `MicrosoftGraphActivityLogs`, `AuditLogs`. These appear in AH automatically on Business Premium tenants — no Entra diagnostic-settings export is required for the agent to read them.

---

## 3. Microsoft Sentinel (always mandatory — the case backend itself when `-CaseBackend sentinel`, telemetry-only when `xdr`/`sharepoint`)

Sentinel supplies tables Defender XDR does not expose, and its analytics rules generate incidents. **For `-CaseBackend sentinel`, this section is also where the case objects themselves live** — the agent reads/writes `Microsoft.SecurityInsights/incidents` directly via KQL (read) and ARM REST (write), never touching the Defender unified-incident queue.

**Prerequisites:**

- [ ] **Log Analytics workspace deployed** and Microsoft Sentinel enabled on it.
- [ ] **Record the workspace `customerId` (GUID)** — `Prepare-Tenant.ps1` auto-discovers workspaces, but recording the GUID lets you pass `-SentinelWorkspaceId` explicitly. Without a workspace selected, the Sentinel Reader/Responder roles are not assigned and every Sentinel KQL query returns **HTTP 403** at runtime (for `-CaseBackend sentinel`, the case backend itself is then completely non-functional, not just telemetry-degraded).
  ```powershell
  az monitor log-analytics workspace show --resource-group <RG> --workspace-name <WS> --query customerId -o tsv
  ```
- [ ] **Data connectors enabled** so the Sentinel-routed tables exist and carry data:
  - `SecurityEvent` — Windows Security Events (for `authentication` Windows leg, Event IDs 4624/4625/4648)
  - `AzureActivity` — Azure control-plane operations
  - `BehaviorAnalytics` / `UserPeerAnalytics` — UEBA; requires UEBA enabled in Sentinel
- [ ] **Analytics rules enabled** — built-in scheduled/Fusion rules so Sentinel actually raises incidents for the agent to investigate.

> A missing telemetry table is non-fatal but reduces coverage: the agent receives an `HTTP 400 … could not be resolved` and reports a telemetry gap rather than crashing. Enable the connector to close the gap. (This does not apply to the `SecurityIncident` table itself, which the `sentinel` case backend depends on directly — that one must exist, since it *is* Sentinel's own incident store.)

---

## 4. Microsoft Teams Channel (output + feedback loop — requirements depend on `-TeamsMode`, see §0a)

The agent posts verdict cards via a **Workflows webhook**, and report delivery rides in the same webhook call — both work identically in `full` and `webhook_only`, regardless of which tenant the Team lives in, because delivering the report is the **customer's own flow's** job (it writes to its own SharePoint using its own connection), not a Graph call the agent makes. Only reply-polling (`-TeamsMode full` only) uses the agent's own Graph credentials, which is why it's the one capability that genuinely requires same-tenant access; see §0a.

**Prerequisites — `-TeamsMode full` (the default; the channel resource — webhook *creation* is a run step in the Preparation Guide):**

- [ ] A **standard** channel created for EasySOC output. **Must be standard** — private/shared channels lack a compatible drive and break report delivery.
- [ ] The channel's **Shared Documents** library exists (auto-provisioned with the Team — no separate SharePoint site/list to create).
- [ ] A **Team member or owner account** available to create the Workflows webhook. The account that creates the workflow must be a Member or Owner of the Team — not merely a tenant admin (a non-member admin gets a URL, but posts are silently dropped).
- [ ] The webhook's flow extended with the report-delivery steps (Preparation Guide Step 2b) — without this, cards post but no report ever follows them.

**Prerequisites — `-TeamsMode webhook_only` (Team lives in a different Entra tenant than the app registration):**

- [ ] The same standard-channel, Shared-Documents, Member/Owner, and flow-extension (Step 2b) requirements as `full` above — report delivery needs all of them regardless of tenant. The only things that do **not** apply are the Team ID/Channel ID retrieval steps, since reply-polling is unavailable in this mode.

**Prerequisites — `-TeamsMode none`:** none — this section does not apply.

> The webhook URL (and, in `full` mode, Team ID + Channel ID) are collected during the run procedure (Preparation Guide, Step 2) — they are the one value set the script cannot auto-discover.

---

## 5. Azure AI Foundry — LLM Inference Endpoint (recommended target)

All investigation reasoning is done by the configured model. For a data-sovereign deployment the inference endpoint should be **Azure AI Foundry in the customer's own tenant**, so LLM traffic stays on the customer's Azure bill and within their Azure boundary. The agent routes through it via the Anthropic-compatible Foundry endpoint (`ANTHROPIC_BASE_URL` + `ANTHROPIC_API_KEY`).

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
>
> **If both an Azure OpenAI-kind and an Anthropic-capable Foundry resource exist in the subscription, `Prepare-Tenant.ps1` now asks which one to use rather than silently guessing** — a fixed bug from earlier script versions that could file an Azure OpenAI resource's endpoint into the Anthropic slot, where it silently doesn't work (Azure OpenAI-kind resources have no Anthropic-compatible endpoint). No action needed here beyond answering the prompt if it appears.

---

## 5a. Alternative backend: Azure OpenAI

`Prepare-Tenant.ps1 -LlmBackend azure_openai` configures the agent against an **Azure OpenAI** deployment instead of Anthropic/Foundry. Use this only if the customer's model access is via Azure OpenAI rather than Azure AI Foundry Claude models.

**Prerequisites:**

- [ ] **Azure OpenAI (or Azure AI Foundry) resource provisioned** in the customer subscription, with a chat-completion model deployed.
- [ ] **Deployment name recorded** (e.g. `gpt-5.4`) — `Prepare-Tenant.ps1` always prompts for this; it is not auto-discovered.
- [ ] **Endpoint URL and key recorded:**
  - `AZURE_OPENAI_ENDPOINT` = the resource endpoint, e.g. `https://<resource>.cognitiveservices.azure.com`.
  - `AZURE_OPENAI_API_KEY` = the resource key.

> **No POC fallback for this backend.** Unlike the Anthropic path, there is no EasySOC-provided fallback key for Azure OpenAI — the endpoint, key, and deployment name must all be present in `easysoc-deploy.config.ps1` before `deploy-aci.ps1` will deploy.

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

> **Do NOT pre-create the storage account** — `Prepare-Tenant.ps1` provisions a `StorageV2` account (`Standard_LRS`, TLS 1.2, public blob access off) and a 5 GiB Azure Files share for the audit volume. The container mounts it at `/app/audit`. If a storage account with your chosen name already exists elsewhere in the subscription (e.g. a partial prior run), the script now detects it and offers to reuse it in place, or lets you pick a different name on the spot — see the Preparation Guide's troubleshooting section.

> **Duplicate subscription names:** a tenant can hold multiple subscriptions with the same display name. The script lists and selects by **subscription ID**; pick by ID when prompted.

---

## 7. Identity & Admin Roles (the engineer running preparation)

These are the roles **you** must hold to run Phase B/C. They are a readiness gate — the agent's own service-principal access rights are documented separately in the Data Sovereignty & Access doc.

| Role | Needed for | Notes |
|---|---|---|
| **Application Administrator** (or Global Administrator) in the customer Entra ID tenant | Create the app registration and **grant admin consent** | **Critical.** Contributor alone is not enough. Without this, the script still completes and writes the config file, but admin consent is silently skipped → the agent gets **403 on every Graph call** at runtime |
| **Contributor** on the target resource group / subscription | Create the storage account, register providers, deploy the container, assign the Sentinel Reader **and Responder** roles, and retrieve the Log Analytics workspace's shared key (enables ACI container-log integration — see the Preparation Guide) | Global Admin does not include Azure RBAC by default — ensure Contributor is also held |

> The app registration (created by Phase B) requests a **subset of up to 11 Microsoft Graph application permissions, chosen by `-CaseBackend`/`-TeamsMode`** — as few as 5 for `-CaseBackend sentinel -TeamsMode webhook_only`/`none` (no Defender/Teams-polling permissions requested at all, since neither is usable), up to all 11 for the default `-CaseBackend xdr -TeamsMode full`. Note that report delivery (`full` or `webhook_only`) needs **no** Graph permission at all — see §0a. It also assigns the **Microsoft Sentinel Reader and Responder** RBAC roles whenever a Sentinel workspace is selected, regardless of `-CaseBackend` (Responder is new — needed for `-CaseBackend sentinel`'s write path, and assigned unconditionally so a tenant can switch to it later without a second manual grant). You do not configure any of this by hand — the script does — but admin consent requires the roles above. The full permission list, exactly which subset applies to which choice, and rationale are in **[Tenant Data Sovereignty and Access](./Tenant%20Data%20Sovereignty%20and%20Access.md)**.

---

## 8. Items Provided by EasySOC (not partner-sourced)

For completeness — these are handed to you, not prepared in the tenant:

| Item | Used as | Notes |
|---|---|---|
| Agent container image | `easysoccr-gyfwc2acakhmg5h0.azurecr.io/soc-agent` | Pulled at deploy time |
| ACR pull token | `$AcrPullPassword` | **You must paste it into the PROVIDER section of `deploy-aci.ps1` before deploying** — the script ships with `$AcrPullPassword` **blank** and stops with `AcrPullPassword is required (PROVIDER section).` if it is left empty (see Preparation Guide Step 4) |
| EasySOC license token | `BOOTSTRAP_TOKEN` | Per-tenant; license validation + runtime prompt delivery |
| EasySOC control endpoint URL | `BOOTSTRAP_URL` | License, prompt bundle, telemetry/TI submission |
| Anthropic API key (POC only) | `ANTHROPIC_API_KEY` | Only if not using customer Foundry (see §5) |

---

## 9. Pre-Flight Readiness Checklist

**First, confirm your `-CaseBackend` and `-TeamsMode` choice (§0a)** — it determines which rows below actually apply. Then run through the rest before invoking `Prepare-Tenant.ps1`:

| # | Prerequisite | Applies when | Verified |
|---|---|---|---|
| 1 | M365 Business Premium / Defender for Business P2 licensed | `-CaseBackend xdr`/`sharepoint` (default) only | ☐ |
| 2 | Defender XDR active; devices onboarded; Advanced Hunting returns rows | `-CaseBackend xdr`/`sharepoint` (default) only | ☐ |
| 3 | Sentinel workspace deployed; workspace `customerId` GUID recorded | Always | ☐ |
| 4 | Sentinel connectors enabled (`SecurityEvent`, `AzureActivity`, UEBA as needed) | Always | ☐ |
| 5 | Sentinel analytics rules enabled (incidents are being generated) | Always | ☐ |
| 6 | **Standard** Teams channel created; a Team member/owner available to create the webhook; webhook flow extended for report delivery (Preparation Guide Step 2b) | `-TeamsMode full` or `webhook_only` (both need the full channel + flow setup — only reply-polling's Team ID/Channel ID retrieval is `full`-only); `none` skips entirely | ☐ |
| 7 | Inference endpoint provisioned: Azure AI Foundry + Claude deployment (default), **or** Azure OpenAI deployment if using `-LlmBackend azure_openai` (§5a); endpoint URL + key (+ deployment name for Azure OpenAI) recorded; quota reviewed | Always | ☐ |
| 8 | Azure subscription with Contributor; subscription **ID** confirmed | Always | ☐ |
| 9 | Engineer holds **Application Administrator/Global Admin** (consent) **and** Contributor (Azure) | Always | ☐ |
| 10 | Azure CLI installed (`az --version`) | Always | ☐ |
| 11 | **ACR pull-token password received from EasySOC** (to paste into `deploy-aci.ps1` `$AcrPullPassword`) | Always | ☐ |
| 12 | Egress allow-list updated, if filtering is enforced (see Data Sovereignty & Access doc — allow-list itself now depends on `-CaseBackend`) | Always | ☐ |
| 13 | Custom-detection titles checked for embedded customer identifiers (see Data Sovereignty & Access doc) | `-CaseBackend xdr`/`sharepoint` only (custom Defender detections don't exist under `sentinel`) | ☐ |
| 14 | Storage account **NOT** pre-created (script provisions it, or offers to reuse an existing one with this exact name found elsewhere in the subscription) | Always | ☐ |

When all applicable rows are checked, proceed to **[Partner Tenant Preparation Guide](./Partner%20Tenant%20Preparation%20Guide.md)** for the step-by-step preparation and deployment run.
