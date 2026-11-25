# Feature Spec: Tag-Pinned Platform Module & DRY Terragrunt Environments (`dev`/`uat`/`prod`)

- **Status:** Approved
- **Module / Component:** `platform_unified_data_gcp/infra/platform` (with atomic `module-versions.yaml`) + `platform_unified_data_gcp/infra/envs/{root.hcl, dev, uat, prod}` (OpenTofu `>= 1.12.2`, Terragrunt `>= 0.72`)
- **Archetype:** Infrastructure-as-Code Contract (DRY Multi-Environment Composition & Immutable Release Tagging)
- **Tier:** Full Spec
- **Owner:** Xavier Ruiz
- **Depends On:** External Org bootstrap [`x-ruiz/platform_gcp_org_bootstrap`](https://github.com/x-ruiz/platform_gcp_org_bootstrap) *(graduated from `specs/01_gcp_bootstrap_and_wif.md`)*
- **Companion Spec:** `specs/04_github_actions_cicd.md` (Trunk-Based GitOps CI/CD & Tag Promotion)
- **Supersedes:** `specs/02_gcp_core_modules.md` (removes local `infra/modules/` in favor of tag-pinned public GitHub modules)

---

## 1. Goal & Context

### Problem Statement
Maintaining custom or vendored copies of foundational GCP Terraform modules under `infra/modules/` creates unnecessary boilerplate and drift from upstream Google Cloud best practices, while pointing all environments (`dev`, `uat`, `prod`) at the same mutable relative path (`../../platform//.`) couples production to `main` HEAD — meaning any untested change merged to `infra/platform/` or `module-versions.yaml` immediately alters the desired state of `uat` and `prod`.

Leveraging OpenTofu 1.8+ **Early Variable & Local Evaluation** in `module.source` together with **Terragrunt immutable Git tag pinning**:
- `module-versions.yaml` lives **inside `infra/platform/module-versions.yaml`** and is read natively by `infra/platform/` via `yamldecode(file("${path.module}/module-versions.yaml"))`, so upstream `cloud-foundation-fabric` and `terraform-google-project-factory` release tags freeze **atomically** inside every `udp-gcp-vX.Y.Z` platform Git tag.
- `infra/envs/dev/terragrunt.hcl` tracks `../../platform//.` (`main` HEAD) for fast development iteration.
- `infra/envs/uat/` and `infra/envs/prod/` each hold a 1-line machine-promoted `release.yaml` (`platform_version: "udp-gcp-vX.Y.Z"` or `"unreleased"` on Day 0) so `uat` and `prod` remain completely isolated from `main` HEAD until explicitly promoted via PR.

### Success Metrics
- `platform_unified_data_gcp/infra/modules/` does not exist; zero vendored/hand-rolled modules and zero custom module-version sync scripts exist in the repository.
- All 5 upstream `module` blocks live cleanly in `infra/platform/main.tf` using `?ref=${local.cff_version}` / `?ref=${local.project_factory_version}` evaluated directly from `infra/platform/module-versions.yaml` (zero generated `modules.tf`, zero hardcoded `?ref=vX.Y.Z` tags in `.tf` files).
- Every `udp-gcp-vX.Y.Z` Git tag freezes both `infra/platform/*.tf` and `infra/platform/module-versions.yaml` together as one immutable release unit.
- Zero `.tf` files exist under `infra/envs/`; `dev` tracks `../../platform//.`, while `uat` and `prod` pin immutable release tags via `release.yaml` + `include.root.locals.platform_git_source`.
- OpenTofu + Terragrunt checks (`tofu fmt`, `terragrunt hcl fmt --check`, `terragrunt render`, `tofu validate` / `terragrunt validate`, `tflint --recursive`, `trivy config` with zero HIGH/CRITICAL findings, and mocked `tofu test` via Terragrunt) all pass offline.
- Steady-state default network cost in `dev` and `uat` is `$0/month` (`enable_cloud_nat = false`, `enable_flow_logs = false`).
- Full verification coverage of `TC-001` through `TC-006`.

---

## 2. Scope & Explicit Non-Goals

### In Scope
- **Removal of `platform_unified_data_gcp/infra/modules/` and custom sync scripts:** Zero local `infra/modules/` and zero `sync_module_versions.sh` scripts.
- **Atomic Upstream Module Version Manifest (`platform_unified_data_gcp/infra/platform/module-versions.yaml`):**
  - Single source of truth declaring every upstream public GitHub module repository URL and exact semantic release tag (`vX.Y.Z`).
  - Lives inside `infra/platform/` so it travels atomically with every `udp-gcp-vX.Y.Z` Git tag and is read directly by OpenTofu Early Evaluation (`yamldecode(file("${path.module}/module-versions.yaml"))`).
- **Single Platform Composition Module (`platform_unified_data_gcp/infra/platform/`):**
  - Defined once (`versions.tf`, `variables.tf`, `main.tf` holding all 5 upstream `module` blocks parameterized via `?ref=${local.cff_version}` / `?ref=${local.project_factory_version}`, `module-versions.yaml`, `outputs.tf`, `.terraform.lock.hcl`, `tests/platform_composition.tftest.hcl`).
  - Independently validatable via `tofu validate` as well as via Terragrunt.
- **DRY Terragrunt Root & Environment Wrappers (`platform_unified_data_gcp/infra/envs/`):**
  - `infra/envs/root.hcl`: Pins `terraform_binary = "tofu"`, exposes `platform_git_source` (parameterized for graduation portability), supports `UDP_GCP_OFFLINE_TEST` and `UDP_GCP_EPHEMERAL_PLAN_STATE` (pre-first-apply read-only PR plans), and generates only `backend.tf` (`envs/<env>`), `encryption.tf` (OpenTofu `gcp_kms` + `aes_gcm`), and `provider.tf` (`google` + `google-beta`).
  - `infra/envs/dev/terragrunt.hcl`: Tracks `terraform.source = "../../platform//."` (`main` HEAD).
  - `infra/envs/uat/{terragrunt.hcl, release.yaml}` and `infra/envs/prod/{terragrunt.hcl, release.yaml}`: Pin immutable `platform_version` tags (`"unreleased"` on Day 0, `"udp-gcp-vX.Y.Z"` once promoted) and resolve `terraform.source` to `${include.root.locals.platform_git_source}?ref=${local.platform_version}` (falling back to `../../platform//.` only when `UDP_GCP_OFFLINE_TEST=true`).

### Non-Goals (Do Not Implement)
- **No CI/CD workflow YAML:** GitHub Actions PR checks, path-scoped plans/applies, and the tag-promotion workflow live in `specs/04_github_actions_cicd.md`.
- **No local `infra/modules/` directory, vendored upstream clones, or custom version-sync scripts.**
- **No floating Git refs:** Never use `?ref=main`, `?ref=master`, or unpinned module URLs in `module-versions.yaml` or `release.yaml`.
- **No duplicated per-environment `.tf` roots or OpenTofu CLI workspaces:** State isolation is strictly per-environment Terragrunt directory + GCS prefix.
- **No data-layer services yet:** GCS medallion buckets, BigQuery, BigLake, Dataproc, Composer, and Pub/Sub remain deferred to future specs (which may become independent domain stacks with their own tag namespaces as the platform scales).

---

## 3. Functional Requirements

- `REQ-01`: **Atomic Upstream Version Manifest (`infra/platform/module-versions.yaml`) & Early Evaluation** — `platform_unified_data_gcp/infra/modules/` and any custom sync scripts shall not exist. Every upstream public GitHub repository URL and semantic release tag (`^v[0-9]+\.[0-9]+\.[0-9]+$`) shall be declared once in `infra/platform/module-versions.yaml`. `infra/platform/main.tf` shall load `yamldecode(file("${path.module}/module-versions.yaml")).modules` into early-evaluated `locals` (`cff_version`, `project_factory_version`) and interpolate `?ref=${local.cff_version}` and `?ref=${local.project_factory_version}` directly in `module.source` using OpenTofu 1.8+ Early Evaluation.
- `REQ-02`: **Platform Composition (`infra/platform/main.tf`)** — `infra/platform/main.tf` shall directly declare all 5 tag-parameterized upstream modules:
  - **GCP Project, Billing Link & APIs** (`cloud-foundation-fabric//modules/project`): creates project under `platform_folder_id` with random 4-char hex suffix (`random_id`), links `billing_account_id`, enforces `auto_create_network = false`, activates required platform APIs (`disable_on_destroy = false`), merges mandatory labels (`managed_by = "opentofu"`, `platform`, `environment`, `cost_center`), and sets `deletion_policy` (default `"PREVENT"`).
  - **Custom VPC & Regional Subnet** (`cloud-foundation-fabric//modules/net-vpc`): custom-mode VPC (`auto_create_subnetworks = false`), primary regional subnet with Private Google Access enabled, and opt-in VPC Flow Logs (`enable_flow_logs`, default `false`).
  - **Baseline Firewalls** (`cloud-foundation-fabric//modules/net-vpc-firewall`): allow IAP SSH (`35.235.240.0/20`, TCP `22`) to `iap_ssh_target_tags`, allow intra-subnet internal traffic, and explicit low-priority deny-all-ingress fallback (`65534`).
  - **Opt-In Cloud NAT** (`cloud-foundation-fabric//modules/net-cloudnat`): provisioned only when `enable_cloud_nat == true` (default `false` → `$0/mo` baseline).
  - **Project-Scoped Budget Guardrail** (`terraform-google-project-factory//modules/budget` + `google_monitoring_notification_channel`): monthly USD budget scoped strictly to the environment project with `[0.5, 0.8, 1.0]` thresholds routed to `budget_alert_email`.
- `REQ-03`: **DRY Terragrunt Root Generation (`infra/envs/root.hcl`)** — `infra/envs/root.hcl` shall pin `terraform_binary = "tofu"`, expose `locals.platform_git_source` (parameterized via `UDP_GCP_PLATFORM_REPO` for graduation portability), support `UDP_GCP_OFFLINE_TEST` (unit tests/validate) and `UDP_GCP_EPHEMERAL_PLAN_STATE` (pre-first-apply read-only PR plan when `default.tfstate` does not yet exist in GCS), and dynamically generate only:
  - `backend.tf`: `backend "gcs"` using `UDP_GCP_STATE_BUCKET` and `prefix = "envs/${path_relative_to_include()}"` (`envs/dev`, `envs/uat`, `envs/prod`).
  - `encryption.tf`: OpenTofu native `encryption` (`gcp_kms` + `aes_gcm`, `enforced = true`, zero `unencrypted` fallback) reading `UDP_GCP_STATE_KMS_KEY_ID`.
  - `provider.tf`: `provider "google"` and `provider "google-beta"` bound to the configured region.
- `REQ-04`: **Thin Environment Wrappers & Release Pins (`dev`, `uat`, `prod`)** — `infra/envs/{dev,uat,prod}/` shall contain zero `.tf` files and include `find_in_parent_folders("root.hcl")` (`expose = true`):
  - `dev/terragrunt.hcl`: sets `terraform.source = "../../platform//."` (always tracks `main` HEAD).
  - `uat/{terragrunt.hcl, release.yaml}` and `prod/{terragrunt.hcl, release.yaml}`: read `platform_version` from `${get_terragrunt_dir()}/release.yaml` (`"unreleased"` on Day 0 or `"udp-gcp-vX.Y.Z"` once promoted) and set `terraform.source` to `"${include.root.locals.platform_git_source}?ref=${local.platform_version}"` (falling back to `"../../platform//."` only when `include.root.locals.offline_test == true`).
  - Each wrapper supplies only environment-specific inputs (non-overlapping CIDRs `10.10.0.0/20`, `10.20.0.0/20`, `10.30.0.0/20`, project ID prefixes, budget caps `$50/$100/$250`, and opt-in feature toggles such as `enable_cloud_nat` / `enable_flow_logs`).
- `REQ-05`: **Strict Input Validation & Multi-Platform Provider Lock** — `infra/platform/variables.tf` shall enforce validation rules for `environment` (`dev | uat | prod`), folder ID, billing account ID, base project ID prefix (`4–25` chars), valid IPv4 CIDR, positive monthly budget, email address, and `deletion_policy`. `infra/platform/.terraform.lock.hcl` shall be locked for `darwin_arm64` and `linux_amd64` and committed.
- `REQ-06`: **Offline Platform Composition Tests** — `infra/platform/tests/platform_composition.tftest.hcl` shall validate wiring for `dev`, `uat`, and `prod`, `$0/mo` default NAT behavior, mandatory labels, and negative input validation (`expect_failures`) via `mock_provider` executed through Terragrunt (and directly via `tofu test`).

---

## 4. Interface & Data Contract

### 4.1 Directory Layout

```text
platform_unified_data_gcp/
├── scripts/
│   ├── detect_affected_envs.sh       # Spec 04 path-scoped CI change detection
│   └── test_detect_affected_envs.sh  # Offline unit tests for change detection
└── infra/
    ├── platform/                     # Single OpenTofu platform module (tagged atomically as udp-gcp-vX.Y.Z)
    │   ├── module-versions.yaml      # Single source of truth for upstream module tags (read via OpenTofu Early Eval)
    │   ├── versions.tf
    │   ├── variables.tf
    │   ├── main.tf                   # Upstream modules using ?ref=${local.cff_version} / ?ref=${local.project_factory_version}
    │   ├── outputs.tf
    │   ├── .terraform.lock.hcl       # Locked for darwin_arm64 + linux_amd64
    │   └── tests/
    │       └── platform_composition.tftest.hcl
    └── envs/                         # Thin DRY Terragrunt wrappers (ZERO .tf files)
        ├── root.hcl                  # Exposes platform_git_source; generates backend.tf, encryption.tf, provider.tf
        ├── dev/
        │   └── terragrunt.hcl        # Tracks ../../platform//. (main HEAD)
        ├── uat/
        │   ├── release.yaml          # Machine-promoted pin: platform_version: "unreleased" | "udp-gcp-vX.Y.Z"
        │   └── terragrunt.hcl        # Fetches tagged platform ref from release.yaml
        └── prod/
            ├── release.yaml          # Machine-promoted pin: platform_version: "unreleased" | "udp-gcp-vX.Y.Z"
            └── terragrunt.hcl        # Fetches tagged platform ref from release.yaml
```

### 4.2 Upstream Module Version Manifest (`infra/platform/module-versions.yaml`)

| Platform Concern | Manifest Key | Upstream GitHub Repository | Module Subpath | Pinned Release Tag |
| :--- | :--- | :--- | :--- | :--- |
| GCP Project, Billing Link, APIs & Labels | `cloud-foundation-fabric` | `https://github.com/GoogleCloudPlatform/cloud-foundation-fabric.git` | `//modules/project` | `v60.0.0` |
| Custom VPC & Regional Subnet (PGA + Flow Logs) | `cloud-foundation-fabric` | `https://github.com/GoogleCloudPlatform/cloud-foundation-fabric.git` | `//modules/net-vpc` | `v60.0.0` |
| Baseline Firewall Rules (IAP SSH, Internal, Deny) | `cloud-foundation-fabric` | `https://github.com/GoogleCloudPlatform/cloud-foundation-fabric.git` | `//modules/net-vpc-firewall` | `v60.0.0` |
| Opt-In Cloud Router & Cloud NAT | `cloud-foundation-fabric` | `https://github.com/GoogleCloudPlatform/cloud-foundation-fabric.git` | `//modules/net-cloudnat` | `v60.0.0` |
| Project-Scoped Billing Budget | `terraform-google-project-factory` | `https://github.com/terraform-google-modules/terraform-google-project-factory.git` | `//modules/budget` | `v18.4.0` |

External manifest payload format (`infra/platform/module-versions.yaml`):

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
| Input | `environment` | `string` | Required | Allowed values: `dev`, `uat`, `prod`. |
| Input | `platform_folder_id` | `string` | Required | Platform Folder ID from bootstrap (`folders/<id>` or numeric). |
| Input | `billing_account_id` | `string` | Required | Format `^[A-Z0-9]{6}-[A-Z0-9]{6}-[A-Z0-9]{6}$`. |
| Input | `project_id` | `string` | Required | Base prefix (`^[a-z][a-z0-9-]{2,23}[a-z0-9]$`); `random_id` appends `-xxxx`. |
| Input | `project_name` | `string` | Required | Human-readable GCP project display name (4–30 chars). |
| Input | `region` | `string` | `"us-central1"` | Primary GCP region. |
| Input | `subnet_cidr` | `string` | Required | Valid IPv4 CIDR block (non-overlapping per environment). |
| Input | `enable_cloud_nat` | `bool` | `false` | Opt-in Cloud Router + Cloud NAT (feature toggle). |
| Input | `enable_flow_logs` | `bool` | `false` | Opt-in VPC Flow Logs on primary subnet (feature toggle). |
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

| Environment | `terraform.source` Strategy | GCS State Prefix | `project_id` Base Prefix | `subnet_cidr` | `enable_cloud_nat` | `enable_flow_logs` | `monthly_budget_usd` |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| `dev` | `../../platform//.` (`main` HEAD) | `envs/dev` | `UDP_GCP_DEV_PROJECT_ID` (default `udp-dev`) | `10.10.0.0/20` | `false` | `false` | `50` |
| `uat` | `${platform_git_source}?ref=<release.yaml>` | `envs/uat` | `UDP_GCP_UAT_PROJECT_ID` (default `udp-uat`) | `10.20.0.0/20` | `false` | `false` | `100` |
| `prod` | `${platform_git_source}?ref=<release.yaml>` | `envs/prod` | `UDP_GCP_PROD_PROJECT_ID` (default `udp-prod`) | `10.30.0.0/20` | `false` (opt-in) | `true` | `250` |

---

## 5. Invariants, Edge Cases & Failure Modes

### Key Invariants
1. **Atomic Platform & Upstream Release Units:** Upstream module tags appear **only** in `infra/platform/module-versions.yaml`, read directly inside `infra/platform/main.tf` via OpenTofu 1.8+ Early Evaluation. Cutting a `udp-gcp-vX.Y.Z` Git tag freezes platform HCL and upstream module versions together.
2. **Environment Isolation on Single Trunk (`main`):** Changes to `infra/platform/**` (including upstream module bumps) affect `dev` only; `uat` and `prod` remain pinned to their respective `release.yaml` tags until promoted.
3. **Zero Local Module Duplication:** Neither `infra/modules/` nor any `.tf` files under `infra/envs/` shall exist.
4. **Immutable Pinning Everywhere:** Every `version` in `infra/platform/module-versions.yaml` matches `^v[0-9]+\.[0-9]+\.[0-9]+$`; every `platform_version` in `infra/envs/{uat,prod}/release.yaml` matches `^(unreleased|udp-gcp-v[0-9]+\.[0-9]+\.[0-9]+)$`. Floating branches (`main`/`master`) are forbidden.
5. **OpenTofu-Backed Terragrunt & Fail-Closed Encryption:** `terraform_binary = "tofu"` in `root.hcl` generates `encryption.tf` (`gcp_kms` + `aes_gcm`, `enforced = true`). Disabling remote backend/encryption is allowed **only** via `UDP_GCP_OFFLINE_TEST=true` (offline validate/unit tests) or `UDP_GCP_EPHEMERAL_PLAN_STATE=true` (pre-first-apply read-only PR plan when `default.tfstate` does not yet exist in GCS).
6. **Default `$0/mo` Network Footprint (`dev` & `uat`):** `enable_cloud_nat = false` and `enable_flow_logs = false` create zero billable idle network resources.

### Failure Mode Matrix

| Failure Condition | Expected Error / Status | Notes |
| :--- | :--- | :--- |
| Malformed or floating tag (`main`/`master`) in `infra/platform/module-versions.yaml` or `release.yaml` | Schema check fails in CI before any GCP auth | Enforces immutable semantic tags (`vX.Y.Z` / `udp-gcp-vX.Y.Z`). |
| Missing key in `infra/platform/module-versions.yaml` | OpenTofu early-evaluation error during `init` | Fails fast with zero GCP or state mutation. |
| Running `terragrunt plan/apply` on `uat`/`prod` while `release.yaml` is `"unreleased"` | CI skips unreleased env cleanly; local run fails resolving `?ref=unreleased` | Prevents accidental provisioning prior to first `dev-to-uat` promotion. |
| Non-existent Git tag written into `release.yaml` | `terragrunt init` Git checkout fails during PR check | Caught before merge to `main`. |
| Upstream module version requires newer `hashicorp/google` / `google-beta` provider | `tofu validate` / `terragrunt init` error | Align provider constraints and re-lock `infra/platform/.terraform.lock.hcl`. |
| Missing `UDP_GCP_STATE_BUCKET` or `UDP_GCP_STATE_KMS_KEY_ID` during plan/apply | Terragrunt `get_env()` failure | Fails closed before OpenTofu initializes remote state. |
| Accidental `terragrunt destroy` on any environment | `deletion_policy = "PREVENT"` error | Requires explicit override to `"DELETE"` for deliberate teardown. |

---

## 6. Acceptance Criteria & Verification Matrix

| Case ID | Scenario | Input / Precondition | Expected Outcome |
| :--- | :--- | :--- | :--- |
| `TC-001` | OpenTofu & Terragrunt Formatting / Validation | `infra/platform/` and `infra/envs/{root.hcl,dev,uat,prod}` | `tofu fmt -check -recursive`, `terragrunt hcl fmt --check`, `tofu validate` (`infra/platform`), `terragrunt validate` (`envs/dev` offline), `tflint`, and `trivy config` exit `0`. |
| `TC-002` | Zero Local Modules, Zero Sync Scripts & DRY Wrapper Hygiene | Inspect `platform_unified_data_gcp/` | `infra/modules/` does not exist; no `sync_module_versions.sh` exists; zero `.tf` files exist under `infra/envs/`; zero hardcoded `?ref=v...` literals exist in `infra/platform/*.tf` (all use `?ref=${local.*}`). |
| `TC-003` | Upstream & Release Manifest Schema Audit | Inspect `infra/platform/module-versions.yaml` and `infra/envs/{uat,prod}/release.yaml` | Valid YAML; upstream versions match `^v[0-9]+\.[0-9]+\.[0-9]+$`; env `platform_version` matches `^(unreleased|udp-gcp-v[0-9]+\.[0-9]+\.[0-9]+)$`. |
| `TC-004` | Terragrunt Root & Source Resolution (`dev`/`uat`/`prod`) | `terragrunt render --json` for `dev`, `uat`, `prod` | `dev` renders `../../platform//.` with `envs/dev`; `uat`/`prod` render `${platform_git_source}?ref=<platform_version>` with `envs/uat` & `envs/prod`, `gcp_kms` encryption, and `google`/`google-beta` providers. |
| `TC-005` | Mocked Platform Composition Test | Run `terragrunt test` (with `mock_provider`) on `infra/envs/dev` and `tofu test` on `infra/platform` | Wires all 5 upstream modules via Early Evaluation from `infra/platform/module-versions.yaml`; enforces `dev | uat | prod` enum, CIDR, and positive budget (`expect_failures`). |
| `TC-006` | Multi-Platform Provider Lock & Graduation Portability | Inspect `infra/platform/.terraform.lock.hcl` and `infra/envs/root.hcl` | Lockfile includes `darwin_arm64` + `linux_amd64` hashes; `platform_git_source` is parameterized in one place (`root.hcl`). |
