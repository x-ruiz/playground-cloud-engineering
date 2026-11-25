# Feature Spec: Tag-Pinned Platform Module & DRY Terragrunt Environments (`dev`/`uat`/`prod`)

- **Status:** Approved
- **Module / Component:** `platform_unified_data_gcp/infra/module-versions.yaml` + `platform_unified_data_gcp/infra/platform` + `platform_unified_data_gcp/infra/envs/{root.hcl, dev, uat, prod}` (OpenTofu `>= 1.12.2`, Terragrunt `>= 0.72`)
- **Archetype:** Infrastructure-as-Code Contract (DRY Multi-Environment Composition & Native Terragrunt Tag Lookup)
- **Tier:** Full Spec
- **Owner:** Xavier Ruiz
- **Depends On:** `specs/01_gcp_bootstrap_and_wif.md`
- **Supersedes:** `specs/02_gcp_core_modules.md` (removes local `infra/modules/` in favor of tag-pinned public GitHub modules)

---

## 1. Goal & Context

### Problem Statement
Maintaining custom or vendored copies of foundational GCP Terraform modules under `infra/modules/` creates unnecessary boilerplate and drift from upstream Google Cloud best practices, while duplicating OpenTofu root files or repeating `?ref=vX.Y.Z` module tags across files creates maintenance overhead. Leveraging OpenTofu 1.8+ **Early Variable Evaluation** in `module.source`, this spec removes `infra/modules/` and any custom sync scripts completely: all platform `module` blocks live directly in `infra/platform/main.tf` using `?ref=${var.<version>}`, all release tags are declared **once** in `infra/module-versions.yaml`, and `infra/envs/root.hcl` reads `infra/module-versions.yaml` via `yamldecode(file(...))` and passes those tags as standard `inputs` to `infra/platform/`.

### Success Metrics
- `platform_unified_data_gcp/infra/modules/` does not exist; zero vendored/hand-rolled modules and zero custom module-version sync scripts exist in the repository.
- All 5 upstream `module` blocks live cleanly in `infra/platform/main.tf` with `?ref=${var.cff_version}` / `?ref=${var.project_factory_version}` (zero generated `modules.tf`, zero hardcoded `?ref=vX.Y.Z` tags in `.tf` files).
- Every upstream GitHub module release tag (`vX.Y.Z`) is declared **once** in `platform_unified_data_gcp/infra/module-versions.yaml` and passed into `infra/platform/` via `infra/envs/root.hcl` `inputs`.
- Zero `.tf` files exist under `infra/envs/`; `dev`, `uat`, and `prod` contain only thin `terragrunt.hcl` wrappers pointing to `../../platform//.`.
- OpenTofu + Terragrunt checks (`tofu fmt`, `terragrunt hcl fmt --check`, `terragrunt render`, `terragrunt validate`, `tflint --recursive`, `trivy config` with zero HIGH/CRITICAL findings, and mocked `tofu test` via Terragrunt) all pass offline.
- Steady-state default network cost in `dev` and `uat` is `$0/month` (`enable_cloud_nat = false`, `enable_flow_logs = false`).
- Full verification coverage of `TC-001` through `TC-006`.

---

## 2. Scope & Explicit Non-Goals

### In Scope
- **Removal of `platform_unified_data_gcp/infra/modules/` and custom sync scripts:** Delete local `infra/modules/` and any `sync_module_versions.sh` / `test_sync_module_versions.sh` scripts.
- **Central Upstream Module Version Manifest (`platform_unified_data_gcp/infra/module-versions.yaml`):**
  - Single source of truth declaring every upstream public GitHub module repository URL and exact semantic release tag (`vX.Y.Z`).
- **DRY Terragrunt Root & Environment Wrappers (`platform_unified_data_gcp/infra/envs/`):**
  - `infra/envs/root.hcl`: Pins `terraform_binary = "tofu"`, reads `../module-versions.yaml` via `yamldecode(file(...))`, passes `cff_version` & `project_factory_version` as `inputs`, and generates only `backend.tf` (`envs/<env>`), `encryption.tf` (OpenTofu `gcp_kms` + `aes_gcm`), and `provider.tf` (`google` + `google-beta`).
  - Thin wrappers `infra/envs/dev/terragrunt.hcl`, `infra/envs/uat/terragrunt.hcl`, and `infra/envs/prod/terragrunt.hcl` pointing `terraform.source = "../../platform//."` with non-overlapping CIDRs and environment-specific inputs.
- **Single Platform Composition Module (`platform_unified_data_gcp/infra/platform/`):**
  - Defined once (`versions.tf`, `variables.tf`, `main.tf` holding all 5 upstream `module` blocks parameterized via `?ref=${var.cff_version}` / `?ref=${var.project_factory_version}`, `outputs.tf`, `.terraform.lock.hcl`, `tests/platform_composition.tftest.hcl`).

### Non-Goals (Do Not Implement)
- **No CI/CD workflow YAML:** GitHub Actions PR checks, multi-env plans, and promotion/apply pipelines live in `specs/04_github_actions_cicd.md`.
- **No local `infra/modules/` directory, vendored upstream clones, or custom version-sync scripts:** Version lookup and static `module.source` rendering are handled 100% natively by Terragrunt (`yamldecode(file(...))` + `generate`).
- **No floating Git refs:** Never use `?ref=main`, `?ref=master`, or unpinned module URLs in `infra/module-versions.yaml`.
- **No duplicated per-environment `.tf` roots or OpenTofu CLI workspaces:** State isolation is strictly per-environment Terragrunt directory + GCS prefix.
- **No data-layer services yet:** GCS medallion buckets, BigQuery, BigLake, Dataproc, Composer, and Pub/Sub remain deferred to future specs.

---

## 3. Functional Requirements

- `REQ-01`: **Single Version Manifest (`infra/module-versions.yaml`) & Early Variable Evaluation** — `platform_unified_data_gcp/infra/modules/` and any custom sync scripts shall not exist. Every upstream public GitHub repository URL and semantic release tag (`^v[0-9]+\.[0-9]+\.[0-9]+$`) shall be declared once in `infra/module-versions.yaml`. `infra/envs/root.hcl` shall read `infra/module-versions.yaml` via `yamldecode(file(...))` and pass `cff_version` and `project_factory_version` as `inputs` into `infra/platform/`, where `infra/platform/main.tf` interpolates `?ref=${var.cff_version}` and `?ref=${var.project_factory_version}` directly in `module.source` using OpenTofu 1.8+ Early Variable Evaluation.
- `REQ-02`: **Platform Composition (`infra/platform/main.tf`)** — `infra/platform/main.tf` shall directly declare all 5 tag-parameterized upstream modules:
  - **GCP Project, Billing Link & APIs** (`cloud-foundation-fabric//modules/project`): creates project under `platform_folder_id` with random 4-char hex suffix (`random_id`), links `billing_account_id`, enforces `auto_create_network = false`, activates required platform APIs (`disable_on_destroy = false`), merges mandatory labels (`managed_by = "opentofu"`, `platform`, `environment`, `cost_center`), and sets `deletion_policy` (default `"PREVENT"`).
  - **Custom VPC & Regional Subnet** (`cloud-foundation-fabric//modules/net-vpc`): custom-mode VPC (`auto_create_subnetworks = false`), primary regional subnet with Private Google Access enabled, and opt-in VPC Flow Logs (`enable_flow_logs`, default `false`).
  - **Baseline Firewalls** (`cloud-foundation-fabric//modules/net-vpc-firewall`): allow IAP SSH (`35.235.240.0/20`, TCP `22`) to `iap_ssh_target_tags`, allow intra-subnet internal traffic, and explicit low-priority deny-all-ingress fallback (`65534`).
  - **Opt-In Cloud NAT** (`cloud-foundation-fabric//modules/net-cloudnat`): provisioned only when `enable_cloud_nat == true` (default `false` → `$0/mo` baseline).
  - **Project-Scoped Budget Guardrail** (`terraform-google-project-factory//modules/budget` + `google_monitoring_notification_channel`): monthly USD budget scoped strictly to the environment project with `[0.5, 0.8, 1.0]` thresholds routed to `budget_alert_email`.
- `REQ-03`: **DRY Terragrunt Root Generation (`infra/envs/root.hcl`)** — `infra/envs/root.hcl` shall pin `terraform_binary = "tofu"`, pass `cff_version` and `project_factory_version` from `infra/module-versions.yaml` via `inputs`, and dynamically generate only:
  - `backend.tf`: `backend "gcs"` using `UDP_GCP_STATE_BUCKET` and `prefix = "envs/${path_relative_to_include()}"` (`envs/dev`, `envs/uat`, `envs/prod`).
  - `encryption.tf`: OpenTofu native `encryption` (`gcp_kms` + `aes_gcm`, `enforced = true`, zero `unencrypted` fallback) reading `UDP_GCP_STATE_KMS_KEY_ID`.
  - `provider.tf`: `provider "google"` and `provider "google-beta"` bound to the configured region.
- `REQ-04`: **Thin Environment Wrappers (`dev`, `uat`, `prod`)** — `infra/envs/{dev,uat,prod}/terragrunt.hcl` shall contain zero `.tf` files, include `find_in_parent_folders("root.hcl")`, set `terraform.source = "../../platform//."`, and supply only environment-specific inputs (non-overlapping CIDRs `10.10.0.0/20`, `10.20.0.0/20`, `10.30.0.0/20`, project ID prefixes, budget caps `$50/$100/$250`, and flow-log/NAT toggles).
- `REQ-05`: **Strict Input Validation & Multi-Platform Provider Lock** — `infra/platform/variables.tf` shall enforce validation rules for `environment` (`dev | uat | prod`), folder ID, billing account ID, base project ID prefix (`4–25` chars), valid IPv4 CIDR, positive monthly budget, email address, and `deletion_policy`. `infra/platform/.terraform.lock.hcl` shall be locked for `darwin_arm64` and `linux_amd64` and committed.
- `REQ-06`: **Offline Platform Composition Tests** — `infra/platform/tests/platform_composition.tftest.hcl` shall validate wiring for `dev`, `uat`, and `prod`, `$0/mo` default NAT behavior, mandatory labels, and negative input validation (`expect_failures`) via `mock_provider` executed through Terragrunt so generated `modules.tf` is evaluated natively.

---

## 4. Interface & Data Contract

### 4.1 Directory Layout

```text
platform_unified_data_gcp/
├── scripts/
│   ├── bootstrap_init.sh
│   └── test_bootstrap_init.sh
└── infra/
    ├── module-versions.yaml          # Single source of truth read natively by Terragrunt root.hcl
    ├── bootstrap/                    # Spec 01 (plain OpenTofu, one-time)
    ├── platform/                     # Single OpenTofu platform module (all 5 upstream module blocks live here)
    │   ├── versions.tf
    │   ├── variables.tf              # Includes cff_version & project_factory_version (validated vX.Y.Z)
    │   ├── main.tf                   # Upstream modules using ?ref=${var.cff_version} / ?ref=${var.project_factory_version}
    │   ├── outputs.tf
    │   ├── .terraform.lock.hcl       # Locked for darwin_arm64 + linux_amd64
    │   └── tests/
    │       └── platform_composition.tftest.hcl
    └── envs/                         # Thin DRY Terragrunt wrappers (ZERO .tf files)
        ├── root.hcl                  # Reads ../module-versions.yaml into inputs; generates backend.tf, encryption.tf, provider.tf
        ├── dev/
        │   └── terragrunt.hcl
        ├── uat/
        │   └── terragrunt.hcl
        └── prod/
            └── terragrunt.hcl
```

### 4.2 Central Version Manifest Contract (`infra/module-versions.yaml`)

| Platform Concern | Manifest Key | Upstream GitHub Repository | Module Subpath | Pinned Release Tag |
| :--- | :--- | :--- | :--- | :--- |
| GCP Project, Billing Link, APIs & Labels | `cloud-foundation-fabric` | `https://github.com/GoogleCloudPlatform/cloud-foundation-fabric.git` | `//modules/project` | `v60.0.0` |
| Custom VPC & Regional Subnet (PGA + Flow Logs) | `cloud-foundation-fabric` | `https://github.com/GoogleCloudPlatform/cloud-foundation-fabric.git` | `//modules/net-vpc` | `v60.0.0` |
| Baseline Firewall Rules (IAP SSH, Internal, Deny) | `cloud-foundation-fabric` | `https://github.com/GoogleCloudPlatform/cloud-foundation-fabric.git` | `//modules/net-vpc-firewall` | `v60.0.0` |
| Opt-In Cloud Router & Cloud NAT | `cloud-foundation-fabric` | `https://github.com/GoogleCloudPlatform/cloud-foundation-fabric.git` | `//modules/net-cloudnat` | `v60.0.0` |
| Project-Scoped Billing Budget | `terraform-google-project-factory` | `https://github.com/terraform-google-modules/terraform-google-project-factory.git` | `//modules/budget` | `v18.4.0` |

External manifest payload format (`infra/module-versions.yaml`):

```yaml
modules:
  cloud-foundation-fabric:
    repository: "https://github.com/GoogleCloudPlatform/cloud-foundation-fabric.git"
    version: "v60.0.0"
  terraform-google-project-factory:
    repository: "https://github.com/terraform-google-modules/terraform-google-project-factory.git"
    version: "v18.4.0"
```

### 4.3 `infra/platform` Input / Output Contract

| Direction | Name | Type | Default / Required | Validation & Contract |
| :--- | :--- | :--- | :--- | :--- |
| Input | `cff_version` | `string` | Required | Immutable semantic tag (`^v[0-9]+\.[0-9]+\.[0-9]+$`) for `cloud-foundation-fabric` (passed by `root.hcl`). |
| Input | `project_factory_version` | `string` | Required | Immutable semantic tag (`^v[0-9]+\.[0-9]+\.[0-9]+$`) for `terraform-google-project-factory` (passed by `root.hcl`). |
| Input | `environment` | `string` | Required | Allowed values: `dev`, `uat`, `prod`. |
| Input | `platform_folder_id` | `string` | Required | Platform Folder ID from bootstrap (`folders/<id>` or numeric). |
| Input | `billing_account_id` | `string` | Required | Format `^[A-Z0-9]{6}-[A-Z0-9]{6}-[A-Z0-9]{6}$`. |
| Input | `project_id` | `string` | Required | Base prefix (`^[a-z][a-z0-9-]{2,23}[a-z0-9]$`); `random_id` appends `-xxxx`. |
| Input | `project_name` | `string` | Required | Human-readable GCP project display name (4–30 chars). |
| Input | `region` | `string` | `"us-central1"` | Primary GCP region. |
| Input | `subnet_cidr` | `string` | Required | Valid IPv4 CIDR block (non-overlapping per environment). |
| Input | `enable_cloud_nat` | `bool` | `false` | Opt-in Cloud Router + Cloud NAT. |
| Input | `enable_flow_logs` | `bool` | `false` | Opt-in VPC Flow Logs on primary subnet. |
| Input | `monthly_budget_usd` | `number` | `50` | Must be `> 0`. |
| Input | `budget_alert_email` | `string` | Required | Valid email address for budget threshold alerts. |
| Input | `deletion_policy` | `string` | `"PREVENT"` | Allowed values: `PREVENT`, `DELETE`, `ABANDON`. |
| Input | `platform_name` | `string` | `"unified-data-platform"` | Applied to mandatory `platform` label. |
| Input | `cost_center` | `string` | `"engineering-playground"` | Applied to mandatory `cost_center` label. |
| Input | `iap_ssh_target_tags` | `list(string)` | `["allow-iap-ssh"]` | Non-empty network tags permitted SSH TCP `22` from Google IAP `35.235.240.0/20`. |
| Output | `project_id` | `string` | — | Provisioned environment GCP Project ID (with `-xxxx` suffix). |
| Output | `project_number` | `string` | — | Provisioned numeric GCP Project number. |
| Output | `vpc_id` | `string` | — | Custom-mode VPC ID. |
| Output | `subnet_id` | `string` | — | Primary regional subnet ID. |
| Output | `nat_enabled` | `bool` | — | Whether Cloud NAT was provisioned. |
| Output | `budget_id` | `string` | — | Project-scoped Billing Budget ID. |
| Output | `notification_channel_id` | `string` | — | Cloud Monitoring email notification channel ID. |

### 4.4 Environment Wrapper Configuration Matrix (`infra/envs/*/terragrunt.hcl`)

| Environment | GCS State Prefix | `project_id` Base Prefix | `subnet_cidr` | `enable_cloud_nat` | `enable_flow_logs` | `monthly_budget_usd` | `deletion_policy` |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| `dev` | `envs/dev` | `UDP_GCP_DEV_PROJECT_ID` (default `udp-dev`) | `10.10.0.0/20` | `false` | `false` | `50` | `PREVENT` |
| `uat` | `envs/uat` | `UDP_GCP_UAT_PROJECT_ID` (default `udp-uat`) | `10.20.0.0/20` | `false` | `false` | `100` | `PREVENT` |
| `prod` | `envs/prod` | `UDP_GCP_PROD_PROJECT_ID` (default `udp-prod`) | `10.30.0.0/20` | `false` (opt-in) | `true` | `250` | `PREVENT` |

---

## 5. Invariants, Edge Cases & Failure Modes

### Key Invariants
1. **True Single Source of Module Versions (Zero Sync Scripts, Zero Generated HCL Modules):** Upstream module tags appear **only** in `infra/module-versions.yaml`. All 5 `module` blocks stay cleanly inside `infra/platform/main.tf` using OpenTofu 1.8+ Early Variable Evaluation (`?ref=${var.cff_version}` / `?ref=${var.project_factory_version}`), with `infra/envs/root.hcl` passing those tags via standard `inputs`.
2. **Zero Local Module Duplication:** Neither `infra/modules/` nor any `.tf` files under `infra/envs/` shall exist.
3. **Immutable Upstream Pinning:** Every `version` in `infra/module-versions.yaml` must match `^v[0-9]+\.[0-9]+\.[0-9]+$`; floating branches (`main`/`master`) are forbidden.
4. **OpenTofu-Backed Terragrunt:** `terraform_binary = "tofu"` in `root.hcl` ensures OpenTofu native Cloud KMS state encryption works cleanly locally and in CI.
5. **Fail-Closed Encrypted State:** Generated `encryption.tf` enforces Cloud KMS encryption with zero plaintext fallback (for offline `terragrunt validate` / `terragrunt test` without GCP credentials, `encryption.tf` generation may be skipped only when an explicit offline validation/test env flag is set, never during `plan`/`apply`).
6. **Default `$0/mo` Network Footprint (`dev` & `uat`):** `enable_cloud_nat = false` and `enable_flow_logs = false` create zero billable idle network resources.

### Failure Mode Matrix

| Failure Condition | Expected Error / Status | Notes |
| :--- | :--- | :--- |
| Malformed or floating tag (`main`/`master`) in `infra/module-versions.yaml` | Schema check fails in CI (or Terragrunt/OpenTofu fails to resolve tag) | Enforces immutable semantic versioning (`vX.Y.Z`). |
| Missing key in `infra/module-versions.yaml` | Terragrunt `yamldecode` lookup error before OpenTofu runs | Fails fast with zero GCP or state mutation. |
| Running plain `tofu validate` directly inside `infra/platform/` without Terragrunt | Missing generated `modules.tf` errors (`Reference to undeclared module`) | Expected by design: `infra/platform/` is invoked through Terragrunt (`infra/envs/<env>`), which generates `modules.tf` from `module-versions.yaml`. |
| Upstream module version requires newer `hashicorp/google` / `google-beta` provider | `terragrunt init` / `validate` error | Align provider constraints and re-lock `infra/platform/.terraform.lock.hcl`. |
| Missing `UDP_GCP_STATE_BUCKET` or `UDP_GCP_STATE_KMS_KEY_ID` during plan/apply | Terragrunt `get_env()` failure | Fails closed before OpenTofu initializes remote state. |
| Accidental `terragrunt destroy` on any environment | `deletion_policy = "PREVENT"` error | Requires explicit override to `"DELETE"` for deliberate teardown. |

---

## 6. Acceptance Criteria & Verification Matrix

| Case ID | Scenario | Input / Precondition | Expected Outcome |
| :--- | :--- | :--- | :--- |
| `TC-001` | OpenTofu & Terragrunt Formatting / Validation | `infra/platform/` and `infra/envs/{root.hcl,dev,uat,prod}` | `tofu fmt -check -recursive`, `terragrunt hcl fmt --check`, `terragrunt init -backend=false && terragrunt validate`, `tflint`, and `trivy config` exit `0`. |
| `TC-002` | Zero Local Modules, Zero Sync Scripts & DRY Wrapper Hygiene | Inspect `platform_unified_data_gcp/` | `infra/modules/` does not exist; no `sync_module_versions.sh` exists; zero `.tf` files exist under `infra/envs/`; zero hardcoded `?ref=v...` literals exist in `infra/platform/*.tf` (all use `?ref=${var.*}`). |
| `TC-003` | Central Manifest Schema & Tag Pinning Audit | Inspect `infra/module-versions.yaml` | Valid YAML; every `repository` matches `https://github.com/...git` and every `version` matches `^v[0-9]+\.[0-9]+\.[0-9]+$`. |
| `TC-004` | Terragrunt Root Inputs & Generation (`dev`/`uat`/`prod`) | `terragrunt render --json` for `dev`, `uat`, `prod` | Passes `cff_version` (`v60.0.0`) and `project_factory_version` (`v18.4.0`) from `infra/module-versions.yaml` as `inputs`, and generates isolated `backend.tf` prefixes (`envs/dev`, `envs/uat`, `envs/prod`), `encryption.tf` (`gcp_kms` + `aes_gcm`), and `provider.tf` (`google` + `google-beta`). |
| `TC-005` | Mocked Platform Composition Test | Run `terragrunt test` (with `mock_provider`) on `infra/envs/dev` for `dev`, `uat`, `prod`, and negative cases | Wires all 5 upstream modules in `infra/platform/main.tf` via Early Variable Evaluation; enforces `dev | uat | prod` enum, CIDR, and positive budget (`expect_failures`). |
| `TC-006` | Multi-Platform Provider Lock & Isolation | Inspect `infra/platform/.terraform.lock.hcl` and relative paths | Lockfile includes `darwin_arm64` + `linux_amd64` hashes; zero `../` paths escape `platform_unified_data_gcp/`. |
