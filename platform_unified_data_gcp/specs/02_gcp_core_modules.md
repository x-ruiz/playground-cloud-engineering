# Feature Spec: Reusable GCP Core Modules (`project_factory`, `vpc_network`, `budget_guardrail`)

- **Status:** Superseded (by `specs/03_platform_and_terragrunt_envs.md` — local `infra/modules/` removed in favor of tag-pinned public GitHub modules directly in `infra/platform/`)
- **Module / Component:** `platform_unified_data_gcp/infra/modules/*` (OpenTofu `>= 1.8`, `hashicorp/google ~> 6.0`, `hashicorp/random ~> 3.6`)
- **Archetype:** Infrastructure-as-Code Contract (Reusable Modules)
- **Tier:** Full Spec
- **Owner:** Xavier Ruiz
- **Depends On:** `specs/01_gcp_bootstrap_and_wif.md`

---

## 1. Goal & Context

### Problem Statement
The shared platform composition (`infra/platform/`, consumed by Terragrunt environment wrappers `envs/dev`, `envs/uat`, and `envs/prod`) must provision GCP projects, custom-mode VPC networking, and billing guardrails consistently without duplicating HCL, leaking default networks, omitting mandatory labels, or incurring idle NAT costs. Encapsulating these primitives into three self-contained, offline-testable OpenTofu modules establishes a clean, repeatable platform contract.

### Success Metrics
- All three modules pass `tofu fmt -check -recursive`, `tofu validate`, `tflint` (Google ruleset), `trivy config` (zero HIGH/CRITICAL findings), and offline `tofu test` (`mock_provider`) with zero GCP credentials or cost.
- Default `vpc_network` configuration (`enable_cloud_nat = false`, `enable_flow_logs = false`) provisions zero billable idle resources (`$0/mo`).
- Full verification coverage of `TC-001` through `TC-007`.

---

## 2. Scope & Explicit Non-Goals

### In Scope
- Three reusable OpenTofu modules under `platform_unified_data_gcp/infra/modules/`:
  - `project_factory`: Creates an environment GCP project under a Folder, links Billing, enforces `auto_create_network = false`, enables caller-supplied APIs (`disable_on_destroy = false`), merges mandatory labels, and configures `deletion_policy`.
  - `vpc_network`: Creates a custom-mode VPC (`auto_create_subnetworks = false`), primary regional subnet with Private Google Access (PGA), opt-in VPC Flow Logs, baseline firewalls (IAP SSH `35.235.240.0/20`, intra-subnet internal, explicit deny-all-ingress fallback), and opt-in Cloud Router + Cloud NAT (`enable_cloud_nat = false` default).
  - `budget_guardrail`: Creates a Cloud Monitoring email notification channel and a project-scoped GCP Billing Budget with configurable threshold alerts (default `50% / 80% / 100%`).
- Mandatory Resource Labels contract enforced across all label-supporting resources.
- Strict OpenTofu `validation` blocks on all critical module inputs and offline `tests/*.tftest.hcl` suites using `mock_provider`.

### Non-Goals (Do Not Implement)
- **No environment wrappers or CI workflows:** `infra/platform/`, Terragrunt `infra/envs/{dev,uat,prod}/`, and GitHub Actions pipelines live in Spec 03.
- **No Shared VPC / peering / Cloud VPN:** Single-project isolated VPCs only.
- **No data services:** No GCS medallion buckets, BigQuery datasets, BigLake catalogs, Dataproc, or Pub/Sub.
- **No Terragrunt inside leaf modules:** `infra/modules/*` remain plain reusable OpenTofu HCL modules (Terragrunt wraps `infra/platform/` in Spec 03).

---

## 3. Functional Requirements

- `REQ-01`: **Toolchain Pinning** — Each module shall declare `required_version` (`>= 1.8.0, < 2.0.0`) and pin `hashicorp/google` (`~> 6.0`) (plus `hashicorp/random` `~> 3.6` in `project_factory` for 4-char random project ID suffixes).
- `REQ-02`: **Project Factory (`modules/project_factory`)** — Provision a GCP project under `folder_id` with a 4-char hex suffix appended to `project_id`, linked to `billing_account_id`, `auto_create_network = false`, mandatory labels merged without allowing callers to drop them, APIs enabled with `disable_on_destroy = false`, and `deletion_policy` defaulting to `"PREVENT"`.
- `REQ-03`: **Baseline VPC Network (`modules/vpc_network`)** — Provision a custom-mode VPC (`auto_create_subnetworks = false`), regional subnet with `private_ip_google_access = true`, opt-in VPC Flow Logs (`enable_flow_logs = false` default), baseline firewalls (allow IAP TCP `22` from `35.235.240.0/20` to `iap_ssh_target_tags`, allow intra-subnet traffic, explicit low-priority deny-all-ingress), and opt-in Cloud Router + Cloud NAT gated by `enable_cloud_nat` (default `false`).
- `REQ-04`: **Budget Guardrail (`modules/budget_guardrail`)** — Provision a Cloud Monitoring email notification channel in `project_id` and a GCP Billing Budget on `billing_account_id` filtered strictly to `projects/<project_number>` with actual and forecasted threshold rules (default `[0.5, 0.8, 1.0]`).
- `REQ-05`: **Input Validation & Mandatory Labels** — Enforce `validation` blocks for environment enum (`dev|uat|prod`), billing account regex, project ID format, valid IPv4 CIDR (`cidrhost`), positive `monthly_amount_usd`, valid threshold percents (`> 0` and `<= 2.0`), and lowercase GCP-compliant labels (`managed_by = "opentofu"`, `platform`, `environment`, `cost_center`).
- `REQ-06`: **Offline Mocked Unit Tests** — Every module shall ship a `tests/*.tftest.hcl` suite using OpenTofu `mock_provider` verifying both happy-path resource invariants and `expect_failures` negative validation cases.

---

## 4. Interface & Data Contract

### 4.1 `infra/modules/project_factory`

| Direction | Name | Type | Default / Required | Validation & Contract |
| :--- | :--- | :--- | :--- | :--- |
| Input | `project_id` | `string` | Required | Base prefix (`^[a-z][a-z0-9-]{2,23}[a-z0-9]$`); random `-xxxx` suffix appended. |
| Input | `project_name` | `string` | Required | Display name (4–30 chars). |
| Input | `folder_id` | `string` | Required | Parent Folder ID (`folders/<id>` or numeric ID normalized cleanly). |
| Input | `billing_account_id` | `string` | Required | Format `^[A-Z0-9]{6}-[A-Z0-9]{6}-[A-Z0-9]{6}$`. |
| Input | `environment` | `string` | Required | Allowed: `dev`, `uat`, `prod`. |
| Input | `activate_apis` | `set(string)` | `[]` | Enabled with `disable_on_destroy = false`. |
| Input | `deletion_policy` | `string` | `"PREVENT"` | Allowed: `PREVENT`, `DELETE`, `ABANDON`. |
| Input | `labels` | `map(string)` | `{}` | Merged with mandatory labels (cannot override `managed_by`). |
| Output | `project_id` | `string` | — | Provisioned project ID (with suffix). |
| Output | `project_number` | `string` | — | Provisioned numeric project number (for budgets/IAM). |
| Output | `enabled_apis` | `set(string)` | — | Activated GCP service APIs. |

### 4.2 `infra/modules/vpc_network`

| Direction | Name | Type | Default / Required | Validation & Contract |
| :--- | :--- | :--- | :--- | :--- |
| Input | `project_id` | `string` | Required | Target GCP Project ID. |
| Input | `network_name` | `string` | Required | Lowercase DNS-safe VPC name. |
| Input | `region` | `string` | `"us-central1"` | Subnet and optional Router/NAT region. |
| Input | `subnet_cidr` | `string` | `"10.10.0.0/20"` | Must pass `cidrhost(var.subnet_cidr, 0)` validation. |
| Input | `enable_flow_logs` | `bool` | `false` | Toggles VPC Flow Logs on primary subnet. |
| Input | `enable_cloud_nat` | `bool` | `false` | Creates Cloud Router + NAT only when `true` (`$0/mo` default). |
| Input | `iap_ssh_target_tags` | `list(string)` | `["allow-iap-ssh"]` | Tags permitted TCP `22` from `35.235.240.0/20`. |
| Output | `vpc_id` | `string` | — | ID / self-link of custom-mode VPC. |
| Output | `vpc_name` | `string` | — | Name of custom-mode VPC. |
| Output | `subnet_id` | `string` | — | ID of primary regional subnet. |
| Output | `nat_enabled` | `bool` | — | Reflects whether Cloud NAT was provisioned. |

### 4.3 `infra/modules/budget_guardrail`

| Direction | Name | Type | Default / Required | Validation & Contract |
| :--- | :--- | :--- | :--- | :--- |
| Input | `billing_account_id` | `string` | Required | Format `^[A-Z0-9]{6}-[A-Z0-9]{6}-[A-Z0-9]{6}$`. |
| Input | `project_id` | `string` | Required | Host project for Cloud Monitoring notification channel. |
| Input | `project_number` | `string` | Required | Numeric project number targeted by budget filter (`projects/<number>`). |
| Input | `display_name` | `string` | Required | Budget display name (e.g., `udp-dev-monthly-budget`). |
| Input | `monthly_amount_usd` | `number` | `50` | Must be `> 0`. |
| Input | `alert_email` | `string` | Required | Non-empty valid email address. |
| Input | `threshold_percents` | `list(number)` | `[0.5, 0.8, 1.0]` | Each value `> 0` and `<= 2.0`. |
| Output | `budget_id` | `string` | — | Resource ID of Billing Budget. |
| Output | `notification_channel_id` | `string` | — | Resource ID of Cloud Monitoring email channel. |

### 4.4 Mandatory Labels Contract
Every label-supporting resource must include `managed_by = "opentofu"`, `platform`, `environment`, and `cost_center` (lowercase, hyphens/underscores only).

---

## 5. Invariants, Edge Cases & Failure Modes

### Key Invariants
1. **Default `$0/mo` Network Footprint:** With default inputs (`enable_cloud_nat = false`, `enable_flow_logs = false`), `vpc_network` creates zero Cloud NAT gateways, zero static external IPs, and zero default VPCs.
2. **Safe Project Destruction & API Preservation:** `project_factory` defaults to `deletion_policy = "PREVENT"` and sets `disable_on_destroy = false` on every `google_project_service`.
3. **Zero Public SSH Exposure:** SSH firewalling allows only Google IAP (`35.235.240.0/20`) on explicitly tagged targets; never `0.0.0.0/0`.
4. **Provider-Propagation Ordering:** Dependent resources (VPC, Monitoring channels) declare explicit `depends_on` / module-output dependency chains after API enablement.

### Failure Mode Matrix

| Failure Condition | Expected Error / Status | Notes |
| :--- | :--- | :--- |
| Invalid `environment`, `billing_account_id`, `project_id`, `subnet_cidr`, or `monthly_amount_usd <= 0` | OpenTofu variable validation error during `validate` / `plan` | Fails fast before any provider API call. |
| Public `0.0.0.0/0` SSH rule or unhardened resource introduced | `trivy config` non-zero exit | Blocks PR in static security checks. |
| API propagation lag right after `google_project_service` enablement | Transient `403 SERVICE_NOT_ACTIVATED` | Mitigated via explicit dependency ordering between API enablement and downstream resources. |
| Global GCP project ID collision on apply | GCP `409 ALREADY_EXISTS` | Random `-xxxx` suffix minimizes collisions; no orphaned state left behind. |

---

## 6. Acceptance Criteria & Verification Matrix

| Case ID | Scenario | Input / Precondition | Expected Outcome |
| :--- | :--- | :--- | :--- |
| `TC-001` | Formatting & syntax validation | All 3 module directories under `infra/modules/` | `tofu fmt -check -recursive` and `tofu validate` exit `0`. |
| `TC-002` | Linting & IaC security scan | `infra/modules/` tree | `tflint --recursive` (Google ruleset) and `trivy config` exit `0` with zero HIGH/CRITICAL findings. |
| `TC-003` | `project_factory` happy path (Mocked) | `tofu test` with valid inputs and APIs list | Creates project with `auto_create_network = false`, `deletion_policy = "PREVENT"`, mandatory labels merged, and `disable_on_destroy = false` on all APIs. |
| `TC-004` | `project_factory` input validation (Mocked) | Invalid `environment = "qa"`, malformed `billing_account_id`, or uppercase `project_id` | Plan fails with explicit variable validation error (`expect_failures`). |
| `TC-005` | `vpc_network` `$0/mo` default path (Mocked) | Default inputs (`enable_cloud_nat = false`, `enable_flow_logs = false`) | Creates custom-mode VPC, PGA-enabled subnet, IAP SSH (`35.235.240.0/20`) + internal + deny-all-ingress firewalls, and **0** Cloud Router/NAT resources. |
| `TC-006` | `vpc_network` opt-in NAT & invalid CIDR (Mocked) | `enable_cloud_nat = true`; negative test with `subnet_cidr = "not-a-cidr"` | Positive test creates Router + NAT (`nat_enabled == true`); negative test fails validation. |
| `TC-007` | `budget_guardrail` thresholds & validation (Mocked) | `monthly_amount_usd = 50`, default `[0.5, 0.8, 1.0]`; negative test with `monthly_amount_usd = 0` | Positive test creates email channel + project-scoped budget with 3 thresholds; negative test fails validation. |
