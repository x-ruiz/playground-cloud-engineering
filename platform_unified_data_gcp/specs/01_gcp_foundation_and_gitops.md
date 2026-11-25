# Feature Spec: GCP Foundation, Project Factory & OpenTofu GitOps

- **Status:** Approved
- **Module / Component:** `platform_unified_data_gcp/infra` (`bootstrap`, `modules/*`, `envs/dev`) + root `.github/workflows/udp-gcp-*.yml` (OpenTofu `>= 1.8`, GCP `hashicorp/google` `~> 6.0`)
- **Archetype:** Infrastructure-as-Code & GitOps Platform Contract
- **Tier:** Full Spec
- **Owner:** Xavier Ruiz

---

## 1. Goal & Context

### Problem Statement
`playground-cloud-engineering` is a newly created incubator repository for prototyping cloud engineering concepts before graduating mature projects into standalone repositories. The first project, `platform_unified_data_gcp`, requires a production-grade, repeatable GCP foundation—combining a GCP Organization Project Factory, encrypted remote state, keyless GitOps automation, baseline VPC networking, and billing guardrails—before any data lakehouse, BigQuery, or compute workloads are introduced in subsequent specs.

### Success Metrics
- Clean, zero-error execution of the full quality pipeline (`tofu fmt -check -recursive`, `tofu validate`, `tflint`, `trivy config`, and `tofu test` with mocked GCP providers) locally and in GitHub Actions PR checks.
- End-to-end keyless GitOps loop via GitHub Actions + GCP Workload Identity Federation (WIF): PRs run read-only `plan` under `sa-tofu-plan`, and merges to `main` apply `envs/dev` under `sa-tofu-apply` with Cloud KMS-encrypted GCS remote state.
- Steady-state monthly cost of `envs/dev` baseline infrastructure (excluding negligible KMS key version storage) is `$0/month` by default (`enable_cloud_nat = false`).
- `platform_unified_data_gcp/` has zero cross-project dependencies so it can graduate cleanly to a standalone repository.
- Full verification coverage of `TC-001` through `TC-016`.

---

## 2. Scope & Explicit Non-Goals

### In Scope
- Repository scaffolding conventions: root `.gitignore`, root `README.md`, project `README.md`, and self-contained layout under `platform_unified_data_gcp/`.
- Automated bootstrap script `scripts/bootstrap_init.sh` (plus offline mocked test `scripts/test_bootstrap_init.sh`) that auto-discovers/validates Org, Billing Account, and GitHub repo metadata, idempotently grants required base Org IAM roles (`roles/resourcemanager.folderAdmin`, `roles/resourcemanager.projectCreator`, `roles/billing.admin`), verifies/refreshes Application Default Credentials (ADC) and Billing Account access, populates `infra/bootstrap/terraform.tfvars`, and automatically runs `tofu init`, `tofu plan`, and `tofu apply`.
- One-time `infra/bootstrap/` root module creating:
  - Dedicated top-level **Platform Folder** under `org_id`.
  - **Seed GCP Project** under the Platform Folder linked to `billing_account_id`.
  - **GCS Remote State Bucket** (versioned, uniform bucket-level access, public access enforced, protected against destroy).
  - **Cloud KMS KeyRing & CryptoKey** for OpenTofu native client-side state encryption.
  - **Workload Identity Federation (WIF) Pool & GitHub OIDC Provider** pinned to the target GitHub repository.
  - **Dual CI Service Accounts** (`sa-tofu-plan` read-only for PRs; `sa-tofu-apply` restricted to `refs/heads/main`) with Folder-scoped IAM bindings (never Org-wide).
  - **Declarative GitHub Actions Variables** via `integrations/github` (`github_actions_variable`), wiring all 9 required `UDP_GCP_*` repository variables automatically from bootstrap outputs with zero manual GitHub UI setup.
- Reusable OpenTofu modules under `infra/modules/`:
  - `project_factory`: Provisions an environment GCP project under the Platform Folder, links Billing, enables declared APIs, enforces `auto_create_network = false`, applies mandatory labels, and configures `deletion_policy`.
  - `vpc_network`: Provisions a custom-mode VPC, primary regional subnet with Private Google Access (PGA), opt-in VPC Flow Logs, baseline firewall rules (IAP SSH + internal subnet traffic + explicit deny-all-ingress fallback), and opt-in Cloud Router/Cloud NAT (`enable_cloud_nat = false` default).
  - `budget_guardrail`: Provisions a GCP Billing Budget scoped to the environment project with 50% / 80% / 100% thresholds and Cloud Monitoring email notification channel.
- Environment root module `infra/envs/dev/` composing `project_factory`, `vpc_network`, and `budget_guardrail`, configured with the Seed GCS backend and OpenTofu Cloud KMS state encryption.
- Path-scoped GitHub Actions workflows at `<repo-root>/.github/workflows/` (`udp-gcp-pr-check.yml`, `udp-gcp-apply-dev.yml`) running `tofu fmt`, `tofu validate`, `tflint`, `trivy config`, `tofu test`, PR `plan` comment, and `main` `apply`.
- Mocked unit test suites (`*.tftest.hcl`) for every reusable module and `envs/dev`.

### Non-Goals (Do Not Implement)
- **Data platform services:** No GCS medallion/lakehouse buckets, BigQuery datasets, BigLake/Iceberg catalogs, Dataproc Serverless, Dataform, Composer, or Pub/Sub (deferred to Spec 02+).
- **Additional environments:** No `envs/staging` or `envs/prod` root modules in Spec 01 (the structure must support adding them later without refactoring `modules/`).
- **Wrapper/orchestration tools:** No Terragrunt, OpenTofu CLI workspaces, HCP Terraform, Atlantis, or GCP Infrastructure Manager.
- **Kubernetes / GKE GitOps:** No GKE clusters, Argo CD, Flux, Crossplane, or GCP Config Connector.
- **Shared VPC / multi-project networking:** No Host/Service Shared VPC peering or Cloud VPN/Interconnect.
- **Static credentials:** No downloadable Service Account JSON keys (`google_service_account_key`) or long-lived GitHub secrets containing GCP credentials.

---

## 3. Functional Requirements

- `REQ-01`: **Repository Isolation & Layout** — All project specs, OpenTofu modules, bootstrap config, and environment roots shall reside under `platform_unified_data_gcp/` with zero relative references outside that directory. GitHub Actions workflows shall live in `<repo-root>/.github/workflows/` and trigger exclusively on path filters scoped to `platform_unified_data_gcp/**` and their own workflow files.
- `REQ-02`: **Toolchain & Version Pinning** — Every OpenTofu root and module shall declare `required_version` (`>= 1.8.0, < 2.0.0`) and pin `hashicorp/google` (`~> 6.0`) (plus `hashicorp/random` `~> 3.6` for random project ID suffixes and `integrations/github` `~> 6.0` in `bootstrap/` for declarative GitHub Actions variables). Root modules shall commit `.terraform.lock.hcl` to version control.
- `REQ-03`: **Bootstrap Platform Folder & Seed Project** — `infra/bootstrap/` shall create a dedicated Platform Folder directly under `org_id` and a Seed GCP project inside that Folder linked to `billing_account_id`, with `auto_create_network = false`, mandatory labels, `deletion_policy = "PREVENT"`, and required bootstrap APIs enabled (`cloudresourcemanager`, `iam`, `iamcredentials`, `sts`, `serviceusage`, `cloudbilling`, `storage`, `cloudkms`, `billingbudgets`, `monitoring`).
- `REQ-04`: **Hardened Remote State Bucket** — `infra/bootstrap/` shall create a GCS state bucket in the Seed project with object versioning enabled, `uniform_bucket_level_access = true`, `public_access_prevention = "enforced"`, a lifecycle rule keeping recent noncurrent versions (e.g., max 10 noncurrent versions / 30-day age), `force_destroy = false`, and `lifecycle { prevent_destroy = true }`.
- `REQ-05`: **Cloud KMS State Encryption** — `infra/bootstrap/` shall create a Cloud KMS KeyRing and CryptoKey (with automatic rotation, default 90 days, and `prevent_destroy = true`) in the Seed project. `infra/envs/dev/` (and `infra/bootstrap/` post-migration) shall configure OpenTofu native `encryption` using the `gcp_kms` key provider and `aes_gcm` method so state files stored in GCS are client-side encrypted.
- `REQ-06`: **Keyless WIF, Dual CI Service Accounts & Declarative GitHub Variables** — `infra/bootstrap/` shall configure a WIF Pool and GitHub OIDC Provider (`https://token.actions.githubusercontent.com`) with an `attribute_condition` restricting federation strictly to `var.github_repository`. It shall create two Service Accounts in the Seed project:
  - `sa-tofu-plan`: Impersonatable by workflows in `var.github_repository` (PRs and branches); granted strictly read-only Folder/Project roles, `roles/storage.objectViewer` on the state bucket, and `roles/cloudkms.cryptoKeyDecrypter` on the KMS state key.
  - `sa-tofu-apply`: Impersonatable **only** when `assertion.repository == var.github_repository` AND `assertion.ref == "refs/heads/main"`; granted Folder-scoped provisioning roles (project creation, IAM, VPC, APIs, monitoring), Billing Account linking/budget roles, `roles/storage.objectUser` on the state bucket, and `roles/cloudkms.cryptoKeyEncrypterDecrypter` on the KMS state key.
  - Provision all 9 `UDP_GCP_*` GitHub Actions repository variables declaratively via `github_actions_variable` (`integrations/github` provider authenticated via `GITHUB_TOKEN` or `gh auth token`).
- `REQ-07`: **Project Factory Module** — `infra/modules/project_factory/` shall create a GCP project under the supplied `folder_id`, link `billing_account_id`, set `auto_create_network = false`, enforce mandatory standard labels, enable the caller-supplied list of GCP APIs (with `disable_on_destroy = false`), and apply a configurable `deletion_policy` defaulting to `"PREVENT"`.
- `REQ-08`: **Baseline VPC Network Module** — `infra/modules/vpc_network/` shall create a custom-mode VPC (`auto_create_subnetworks = false`), a primary regional subnet with `private_ip_google_access = true`, optional VPC Flow Logs (`enable_flow_logs` defaulting to `false`), baseline firewall rules (allow IAP SSH from `35.235.240.0/20` to tagged targets, allow intra-subnet internal traffic, explicit low-priority deny-all-ingress rule), and optional Cloud Router + Cloud NAT gated by `enable_cloud_nat` (default `false`).
- `REQ-09`: **Billing Budget Guardrail Module** — `infra/modules/budget_guardrail/` shall create a Cloud Monitoring email notification channel and a GCP Billing Budget scoped strictly to the target project's number/ID with alert thresholds at 50%, 80%, and 100% of the configured monthly amount (supporting both actual and forecasted spend rules).
- `REQ-10`: **Environment Composition (`envs/dev`)** — `infra/envs/dev/` shall compose `project_factory`, `vpc_network`, and `budget_guardrail` with explicit GCS state prefix (`envs/dev`), Cloud KMS state encryption, `us-central1` default region, and `enable_cloud_nat = false`.
- `REQ-11`: **GitHub Actions PR Quality & Plan Workflow** — `udp-gcp-pr-check.yml` shall run on pull requests touching `platform_unified_data_gcp/**`: execute `tofu fmt -check -recursive`, `tofu validate`, `tflint` (with Google ruleset), `trivy config` (failing on HIGH/CRITICAL findings unless explicitly justified/ignored), and `tofu test`; then authenticate via WIF as `sa-tofu-plan`, run `tofu plan -lock=false -no-color` against `envs/dev`, and post/update a concise plan summary on the PR.
- `REQ-12`: **GitHub Actions Apply Workflow** — `udp-gcp-apply-dev.yml` shall run on pushes to `main` touching `platform_unified_data_gcp/infra/**` (and optional manual `workflow_dispatch`), enforce serialized execution via a workflow `concurrency` group with `cancel-in-progress: false`, authenticate via WIF as `sa-tofu-apply`, and run `tofu init` + `tofu apply -auto-approve` against `envs/dev` with full GCS state locking enabled.
- `REQ-13`: **Input Validation & Naming Discipline** — Every module shall validate critical inputs via OpenTofu `validation` blocks (e.g., environment enum `dev|staging|prod`, numeric `org_id`, billing account format `XXXXXX-XXXXXX-XXXXXX`, valid IPv4 CIDR block, positive budget amount, lowercase GCP-compliant label keys/values).
- `REQ-14`: **Mocked Unit Tests** — Every reusable module (`project_factory`, `vpc_network`, `budget_guardrail`), `bootstrap`, and `envs/dev` shall include `tofu test` suites (`tests/*.tftest.hcl`) using OpenTofu `mock_provider` blocks so all contract assertions execute offline with zero GCP credentials or cost.
- `REQ-15`: **Automated Bootstrap Preflight, `terraform.tfvars` & OpenTofu Execution Script** — `scripts/bootstrap_init.sh` shall automate Phase 0 + Phase 1 end-to-end:
  - Verify `gcloud` and `tofu` binaries and active `gcloud` authentication.
  - Reuse any existing `infra/bootstrap/terraform.tfvars` values as defaults, auto-discover missing `org_id`, `billing_account_id`, `github_repository`, and active admin email via `gcloud`/`git`, and accept CLI flags or interactive overrides.
  - Validate every parameter against the exact `infra/bootstrap/variables.tf` regex contracts before mutating GCP or writing files.
  - Idempotently grant `roles/resourcemanager.folderAdmin`, `roles/resourcemanager.projectCreator`, and `roles/billing.admin` on `organizations/<org_id>` to the active admin user, verify Billing Account IAM access on `billing_account_id` (supporting both Org-inherited and direct `roles/billing.admin`), and ensure Application Default Credentials (ADC) match the active Org Admin (refreshing ADC if missing or bound to a different account, and warning/unsetting stale quota projects).
  - Atomically populate `infra/bootstrap/terraform.tfvars` (gitignored), then automatically execute `tofu init`, `tofu plan -out=tfplan`, and `tofu apply tfplan` (prompting before apply unless `--auto-approve` is supplied, or stopping after `tofu plan` when `--skip-apply` is supplied), cleaning up `tfplan` on exit.
  - Support `--dry-run` (zero GCP mutations, file writes, or OpenTofu executions) and `--non-interactive` (requiring explicit `--auto-approve` or `--skip-apply` to avoid accidental unattended applies).

---

## 4. Interface & Data Contract

### 4.1 Repository Directory Layout

```text
playground-cloud-engineering/
├── .gitignore
├── README.md
├── .github/
│   └── workflows/
│       ├── udp-gcp-pr-check.yml
│       └── udp-gcp-apply-dev.yml
└── platform_unified_data_gcp/
    ├── README.md
    ├── .tflint.hcl
    ├── .trivyignore                  # Optional, documented suppressions only
    ├── specs/
    │   └── 01_gcp_foundation_and_gitops.md
    ├── scripts/
    │   ├── bootstrap_init.sh         # Automated Phase 0 IAM, ADC check, and bootstrap terraform.tfvars setup
    │   └── test_bootstrap_init.sh    # Offline mocked test suite for bootstrap_init.sh
    └── infra/
        ├── bootstrap/                # One-time local execution -> migrated to Seed GCS + KMS
        │   ├── versions.tf
        │   ├── backend.tf            # Activated in Step 2 of bootstrap migration
        │   ├── encryption.tf         # OpenTofu Cloud KMS state encryption
        │   ├── variables.tf
        │   ├── main.tf
        │   ├── iam_wif.tf
        │   ├── github_actions.tf     # Declarative GitHub Actions repository variables (integrations/github)
        │   ├── outputs.tf
        │   └── terraform.tfvars.example
        ├── modules/
        │   ├── project_factory/
        │   │   ├── versions.tf
        │   │   ├── variables.tf
        │   │   ├── main.tf
        │   │   ├── outputs.tf
        │   │   └── tests/
        │   │       └── project_factory.tftest.hcl
        │   ├── vpc_network/
        │   │   ├── versions.tf
        │   │   ├── variables.tf
        │   │   ├── main.tf
        │   │   ├── outputs.tf
        │   │   └── tests/
        │   │       └── vpc_network.tftest.hcl
        │   └── budget_guardrail/
        │       ├── versions.tf
        │       ├── variables.tf
        │       ├── main.tf
        │       ├── outputs.tf
        │       └── tests/
        │           └── budget_guardrail.tftest.hcl
        └── envs/
            └── dev/
                ├── versions.tf
                ├── backend.tf
                ├── encryption.tf
                ├── variables.tf
                ├── main.tf
                ├── outputs.tf
                ├── terraform.tfvars.example
                └── tests/
                    └── dev_composition.tftest.hcl
```

### 4.2 Module Input / Output Contracts

#### A. `infra/bootstrap` (Root Module)

| Direction | Name | Type | Default / Required | Validation & Contract |
| :--- | :--- | :--- | :--- | :--- |
| Input | `org_id` | `string` | Required | Numeric GCP Organization ID (`^[0-9]+$`). |
| Input | `billing_account_id` | `string` | Required | GCP Billing Account ID (`^[A-Z0-9]{6}-[A-Z0-9]{6}-[A-Z0-9]{6}$`). |
| Input | `github_repository` | `string` | Required | Exact `owner/repo` string (e.g., `x-ruiz/playground-cloud-engineering`). |
| Input | `platform_name` | `string` | `"unified-data-platform"` | Lowercase slug used in Folder name, labels, and resource prefixes. |
| Input | `seed_project_id` | `string` | Required | Base GCP Project ID prefix (4–25 chars, lowercase letters/digits/hyphens); OpenTofu appends a random 4-char hex suffix (`-xxxx`) to prevent global 409 collisions. |
| Input | `dev_project_id` | `string` | Required | Base GCP Project ID prefix for `envs/dev` (4–25 chars), synced to GitHub Actions variable `UDP_GCP_DEV_PROJECT_ID`. |
| Input | `budget_alert_email` | `string` | Required | Email address for dev Billing Budget alerts, synced to GitHub Actions variable `UDP_GCP_BUDGET_ALERT_EMAIL`. |
| Input | `region` | `string` | `"us-central1"` | Primary GCP region for state bucket & KMS KeyRing. |
| Input | `cost_center` | `string` | `"engineering-playground"` | Applied to mandatory `cost_center` label. |
| Output | `platform_folder_id` | `string` | — | Resource ID of created Platform Folder (`folders/<id>`). |
| Output | `seed_project_id` | `string` | — | Created Seed Project ID. |
| Output | `state_bucket_name` | `string` | — | GCS bucket name for OpenTofu remote state. |
| Output | `kms_key_id` | `string` | — | Fully qualified Cloud KMS CryptoKey ID for OpenTofu `gcp_kms` encryption. |
| Output | `wif_provider_name` | `string` | — | Full WIF provider resource path for `google-github-actions/auth`. |
| Output | `plan_service_account_email` | `string` | — | Email of `sa-tofu-plan`. |
| Output | `apply_service_account_email` | `string` | — | Email of `sa-tofu-apply`. |

#### B. `infra/modules/project_factory`

| Direction | Name | Type | Default / Required | Validation & Contract |
| :--- | :--- | :--- | :--- | :--- |
| Input | `project_id` | `string` | Required | Base GCP Project ID prefix (`^[a-z][a-z0-9-]{2,23}[a-z0-9]$`); OpenTofu appends a random 4-char hex suffix (`-xxxx`) to prevent global 409 collisions. |
| Input | `project_name` | `string` | Required | Human-readable GCP display name (4–30 chars). |
| Input | `folder_id` | `string` | Required | Parent Folder ID (`folders/<id>` or numeric ID normalized cleanly). |
| Input | `billing_account_id` | `string` | Required | Format `^[A-Z0-9]{6}-[A-Z0-9]{6}-[A-Z0-9]{6}$`. |
| Input | `environment` | `string` | Required | Allowed values: `dev`, `staging`, `prod`. |
| Input | `activate_apis` | `set(string)` | `[]` | GCP service APIs enabled with `disable_on_destroy = false`. |
| Input | `deletion_policy` | `string` | `"PREVENT"` | Allowed values: `PREVENT`, `DELETE`, `ABANDON`. |
| Input | `labels` | `map(string)` | `{}` | Merged with mandatory platform labels (mandatory labels cannot be dropped). |
| Output | `project_id` | `string` | — | Provisioned project ID. |
| Output | `project_number` | `string` | — | Provisioned numeric project number (used by budgets/IAM). |
| Output | `enabled_apis` | `set(string)` | — | Set of activated GCP service APIs. |

#### C. `infra/modules/vpc_network`

| Direction | Name | Type | Default / Required | Validation & Contract |
| :--- | :--- | :--- | :--- | :--- |
| Input | `project_id` | `string` | Required | Target GCP Project ID. |
| Input | `network_name` | `string` | Required | Lowercase DNS-safe VPC name. |
| Input | `region` | `string` | `"us-central1"` | Subnet and optional Router/NAT region. |
| Input | `subnet_cidr` | `string` | `"10.10.0.0/20"` | Must pass `cidrhost(var.subnet_cidr, 0)` IPv4 CIDR validation. |
| Input | `enable_flow_logs` | `bool` | `false` | Toggles VPC Flow Logs metadata on primary subnet. |
| Input | `enable_cloud_nat` | `bool` | `false` | When `true`, provisions Cloud Router + Cloud NAT; when `false`, creates zero Router/NAT resources (`$0/mo` idle). |
| Input | `iap_ssh_target_tags` | `list(string)` | `["allow-iap-ssh"]` | Network tags permitted inbound TCP `22` from Google IAP range `35.235.240.0/20`. |
| Output | `vpc_id` | `string` | — | Self-link / ID of the custom-mode VPC. |
| Output | `vpc_name` | `string` | — | Name of the custom-mode VPC. |
| Output | `subnet_id` | `string` | — | ID of the primary regional subnet. |
| Output | `nat_enabled` | `bool` | — | Reflects whether Cloud NAT was provisioned. |

#### D. `infra/modules/budget_guardrail`

| Direction | Name | Type | Default / Required | Validation & Contract |
| :--- | :--- | :--- | :--- | :--- |
| Input | `billing_account_id` | `string` | Required | Format `^[A-Z0-9]{6}-[A-Z0-9]{6}-[A-Z0-9]{6}$`. |
| Input | `project_id` | `string` | Required | Host project for the Cloud Monitoring notification channel. |
| Input | `project_number` | `string` | Required | Numeric project number targeted by the Billing Budget filter (`projects/<number>`). |
| Input | `display_name` | `string` | Required | Budget display name (e.g., `udp-dev-monthly-budget`). |
| Input | `monthly_amount_usd` | `number` | `50` | Must be `> 0`. |
| Input | `alert_email` | `string` | Required | Non-empty valid email address for budget alert notifications. |
| Input | `threshold_percents` | `list(number)` | `[0.5, 0.8, 1.0]` | Each value must be `> 0` and `<= 2.0`. |
| Output | `budget_id` | `string` | — | Resource ID of the Billing Budget. |
| Output | `notification_channel_id` | `string` | — | Resource ID of the Cloud Monitoring email channel. |

### 4.3 IAM & WIF Principal Matrix

| Principal | WIF Federation Condition | Scope | Assigned Roles | Purpose |
| :--- | :--- | :--- | :--- | :--- |
| `sa-tofu-plan` | `assertion.repository == var.github_repository` | Platform Folder | `roles/viewer`, `roles/iam.securityReviewer` | Read-only state refresh & drift detection during PR plans. |
| `sa-tofu-plan` | Same | Seed State Bucket | `roles/storage.objectViewer` | Read-only access to remote state objects (PR plan runs `-lock=false`). |
| `sa-tofu-plan` | Same | Seed KMS CryptoKey | `roles/cloudkms.cryptoKeyDecrypter` | Decrypt OpenTofu state during PR plan (cannot encrypt/write state). |
| `sa-tofu-apply` | `assertion.repository == var.github_repository && assertion.ref == "refs/heads/main"` | Platform Folder | `roles/resourcemanager.projectCreator`, `roles/resourcemanager.projectDeleter`, `roles/resourcemanager.projectIamAdmin`, `roles/compute.networkAdmin`, `roles/serviceusage.serviceUsageAdmin`, `roles/monitoring.notificationChannelEditor` | Create/manage environment projects, VPCs, APIs, and alert channels under Platform Folder only. |
| `sa-tofu-apply` | Same | Billing Account | `roles/billing.user`, `roles/billing.costsManager` | Link environment projects to Billing and manage project Billing Budgets. |
| `sa-tofu-apply` | Same | Seed State Bucket | `roles/storage.objectUser` | Read/write state objects and manage `.tflock` lock files. |
| `sa-tofu-apply` | Same | Seed KMS CryptoKey | `roles/cloudkms.cryptoKeyEncrypterDecrypter` | Decrypt and re-encrypt OpenTofu state on apply. |

### 4.4 Mandatory Resource Labels Contract

All label-supporting GCP resources provisioned by `bootstrap` and `modules/*` must include these baseline keys (lowercase, hyphens/underscores only):

| Label Key | Example Value | Source |
| :--- | :--- | :--- |
| `managed_by` | `opentofu` | Hardcoded invariant across all modules |
| `platform` | `unified-data-platform` | Variable default / passed by env root |
| `environment` | `seed` / `dev` | Environment root |
| `cost_center` | `engineering-playground` | Variable |

### 4.5 External Input Payload Example (`envs/dev/terraform.tfvars.json`)

```json
{
  "platform_folder_id": "folders/123456789012",
  "billing_account_id": "01ABCD-23EFGH-45IJKL",
  "project_id": "udp-dev-xruiz-001",
  "project_name": "UDP Dev",
  "region": "us-central1",
  "subnet_cidr": "10.10.0.0/20",
  "enable_cloud_nat": false,
  "enable_flow_logs": false,
  "monthly_budget_usd": 50,
  "budget_alert_email": "alerts@example.com",
  "deletion_policy": "PREVENT"
}
```

### 4.6 GitHub Actions Workflow Contract

| Workflow File | Triggers | Permissions | Auth Principal | Steps & Concurrency |
| :--- | :--- | :--- | :--- | :--- |
| `.github/workflows/udp-gcp-pr-check.yml` | `pull_request` on paths `platform_unified_data_gcp/**` and `.github/workflows/udp-gcp-*.yml` | `contents: read`, `id-token: write`, `pull-requests: write` | `sa-tofu-plan` via WIF | Job 1 (`static-checks`): `tofu fmt -check -recursive`, `tofu validate`, `tflint`, `trivy config`, `tofu test`. Job 2 (`plan-dev`, depends on Job 1): WIF auth, `tofu init`, `tofu plan -lock=false -no-color`, upsert PR comment. |
| `.github/workflows/udp-gcp-apply-dev.yml` | `push` to `main` on paths `platform_unified_data_gcp/infra/**` (plus `workflow_dispatch`) | `contents: read`, `id-token: write` | `sa-tofu-apply` via WIF | `concurrency: { group: "udp-gcp-dev-apply", cancel-in-progress: false }`. WIF auth, `tofu init`, `tofu plan -out=tfplan`, `tofu apply -auto-approve tfplan`. |

### 4.7 Bootstrap Preflight Script CLI Contract (`scripts/bootstrap_init.sh`)

| Flag | Type | Default / Auto-Discovery | Validation & Behavior |
| :--- | :--- | :--- | :--- |
| `--org-id <id>` | `string` | Existing `tfvars` → `gcloud organizations list` | Numeric GCP Org ID (`^[0-9]+$`). |
| `--billing-account <id>` | `string` | Existing `tfvars` → first open `gcloud billing accounts list` | Format `^[A-Z0-9]{6}-[A-Z0-9]{6}-[A-Z0-9]{6}$`. |
| `--github-repo <owner/repo>` | `string` | Existing `tfvars` → parsed from `git remote get-url origin` | Format `^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$`. |
| `--seed-project-id <id>` | `string` | Existing `tfvars` → interactive prompt / generated slug | Format `^[a-z][a-z0-9-]{2,23}[a-z0-9]$`. |
| `--dev-project-id <id>` | `string` | Existing `tfvars` → `"udp-dev-<owner>"` / `"udp-dev-001"` | Format `^[a-z][a-z0-9-]{2,23}[a-z0-9]$` (synced to `UDP_GCP_DEV_PROJECT_ID`). |
| `--budget-alert-email <email>` | `string` | Existing `tfvars` → active Org Admin email | Valid email address (synced to `UDP_GCP_BUDGET_ALERT_EMAIL`). |
| `--platform-name <slug>` | `string` | Existing `tfvars` → `"unified-data-platform"` | Format `^[a-z][a-z0-9-]{2,28}[a-z0-9]$`. |
| `--region <region>` | `string` | Existing `tfvars` → `"us-central1"` | Format `^[a-z]+-[a-z]+[0-9]+$`. |
| `--cost-center <label>` | `string` | Existing `tfvars` → `"engineering-playground"` | Format `^[a-z][a-z0-9_-]{1,61}[a-z0-9]$`. |
| `--admin-user <email>` | `string` | Active `gcloud config get-value account` | Non-empty Google identity email granted Org bootstrap roles. |
| `--skip-adc-check` | `bool` | `false` | Skips ADC credential refresh (useful in scripted/mocked runs). |
| `--auto-approve` | `bool` | `false` | Applies the generated `tfplan` without interactive confirmation prompt. |
| `--skip-apply` | `bool` | `false` | Runs `tofu init` and `tofu plan` only, skipping `tofu apply`. |
| `--non-interactive` | `bool` | `false` | Never prompts on stdin; requires `--auto-approve` or `--skip-apply` (unless `--dry-run`) and exits `2` if any required input is unresolved. |
| `--dry-run` | `bool` | `false` | Validates inputs, prints planned IAM bindings, rendered `terraform.tfvars`, and OpenTofu commands with zero GCP mutations, file writes, or OpenTofu executions. |
| `-h`, `--help` | `bool` | `false` | Prints usage summary and exits `0`. |

**Exit Codes:** `0` = preflight and OpenTofu plan/apply succeeded; `1` = prerequisite missing (`gcloud`/`tofu`, unauthenticated CLI, or GCP API/IAM/OpenTofu failure); `2` = invalid flag, missing `--auto-approve`/`--skip-apply` in `--non-interactive` mode, or variable validation failure.

---

## 5. Invariants, Edge Cases & Failure Modes

### Key Invariants
1. **Zero Org-Wide CI Blast Radius:** Neither `sa-tofu-plan` nor `sa-tofu-apply` shall hold Organization-level IAM roles. All resource-management IAM bindings are anchored strictly at the Platform Folder (`platform_folder_id`), Seed State Bucket, Seed KMS CryptoKey, or Billing Account.
2. **True Read-Only PR Plans:** Unmerged PRs must never be able to impersonate `sa-tofu-apply`, write state, or mutate GCP resources. WIF `attribute_condition` / principal binding enforces `refs/heads/main` for `sa-tofu-apply`, and `udp-gcp-pr-check.yml` runs `tofu plan -lock=false`.
3. **Zero Static Credentials:** No `google_service_account_key` resources or JSON key secrets shall exist anywhere in code, tests, or CI configuration.
4. **Two-Phase Bootstrap State Encryption Migration:** Because `bootstrap/` creates the GCS state bucket and Cloud KMS key it will later depend on, initial bootstrap runs locally with local state; once Seed + GCS + KMS exist, the operator enables `backend "gcs"` and OpenTofu `encryption` (with an `unencrypted` `fallback` block for the single `tofu init -migrate-state` run), verifies the GCS object is encrypted ciphertext, and removes the `unencrypted` fallback block so plaintext state is permanently rejected.
5. **Default `$0/mo` Network Footprint:** With default variable values (`enable_cloud_nat = false`, `enable_flow_logs = false`), `vpc_network` must provision zero billable idle resources (no Cloud NAT gateways, no static external IPs, no default VPC).
6. **Protection Against Accidental Destruction:** The Seed project, GCS state bucket, and KMS CryptoKey must carry `prevent_destroy = true` / `deletion_policy = "PREVENT"` and `force_destroy = false`. The `dev` project defaults to `deletion_policy = "PREVENT"` and requires an explicit variable change to `"DELETE"` before intentional teardown.
7. **Deterministic Labeling & API Preservation:** Mandatory labels (`managed_by`, `platform`, `environment`, `cost_center`) are merged into every label-supporting resource, and `google_project_service` resources set `disable_on_destroy = false` so tearing down a module does not cascade-break shared GCP APIs.
8. **External Billing Account Delegation Prerequisite:** When reusing a Billing Account owned outside the GCP Organization (e.g., created under a personal `@gmail.com` account), Organization-level `roles/billing.admin` does not inherit onto that Billing Account. The Billing Account owner must grant `roles/billing.admin` directly on the Billing Account to the Org Admin identity (and optionally migrate the Billing Account into the Organization) once before running `scripts/bootstrap_init.sh`.

### Failure Mode Matrix

| Failure Condition | Expected Error / Status | Notes |
| :--- | :--- | :--- |
| Invalid `org_id`, `billing_account_id`, `project_id`, `environment`, `subnet_cidr`, or `monthly_amount_usd <= 0` | OpenTofu variable validation error during `tofu validate` / `tofu plan` | Fails fast before any provider API call; zero state mutation. |
| PR from a branch other than `main` attempts to impersonate `sa-tofu-apply` | GCP STS `403 PERMISSION_DENIED` (WIF principal mismatch) | Enforced server-side by GCP WIF IAM binding; cannot be bypassed by modifying PR workflow YAML. |
| Two merges to `main` occur in rapid succession | Second `udp-gcp-apply-dev.yml` run queues behind the first (`cancel-in-progress: false`); GCS `.tflock` acts as secondary lock | Prevents torn state or half-applied resources. |
| `tofu init` in `envs/dev` without KMS decrypt permission or wrong KMS key ID | OpenTofu state decryption error (`Failed to decrypt state`) | Fail-closed; refuses to proceed with unreadable or plaintext state once fallback is disabled. |
| `trivy config` detects public GCS bucket, open `0.0.0.0/0` SSH firewall, or missing uniform bucket access | Non-zero exit code in `static-checks` job; PR blocked before `plan-dev` executes | Requires fixing misconfiguration (or explicit documented suppression in `.trivyignore`). |
| Accidental `tofu destroy` run against `bootstrap/` or default `envs/dev` | OpenTofu lifecycle error (`Instance cannot be destroyed` / `deletion_policy = PREVENT`) | Protects Seed project, remote state, KMS key, and `dev` project from accidental deletion. |
| Project ID collision globally across GCP during `envs/dev` apply | GCP Resource Manager `409 ALREADY_EXISTS` | Operator updates `project_id` in `tfvars`; no orphaned state resources left behind. |
| GCP API propagation lag right after `google_project_service` enablement | Provider retry or transient `403 SERVICE_NOT_ACTIVATED` | Modules must declare explicit `depends_on` between API enablement and dependent resources (VPC, Monitoring channel). |
| `scripts/bootstrap_init.sh` invoked with invalid input format or missing required value in `--non-interactive` mode | Exit code `2` with descriptive stderr message | Fails fast before invoking `gcloud organizations add-iam-policy-binding` or writing `terraform.tfvars`. |
| Active `gcloud` account lacks `roles/billing.admin` on `billing_account_id` (e.g., Billing Account lives outside the Org under a personal `@gmail.com` account) or ADC points to a different account | Exit code `1` (or interactive ADC refresh prompt) displaying the exact `gcloud` error and remediation steps | Prevents silent `403` failures during subsequent `tofu apply`; Billing Account owner must grant `roles/billing.admin` directly to the Org Admin (via Console or `gcloud billing accounts add-iam-policy-binding`) and optionally move the Billing Account into the Org. |

---

## 6. Acceptance Criteria & Verification Matrix

| Case ID | Scenario | Input / Precondition | Expected Outcome |
| :--- | :--- | :--- | :--- |
| `TC-001` | Formatting & Syntax Hygiene | All `.tf` and `.tftest.hcl` files under `platform_unified_data_gcp/infra/` | `tofu fmt -check -recursive` and `tofu validate` exit `0` across `bootstrap`, all 3 modules, and `envs/dev`. |
| `TC-002` | GCP Linting & IaC Security Scan | Full `platform_unified_data_gcp/infra/` tree | `tflint --recursive` (Google ruleset) and `trivy config` exit `0` with zero HIGH/CRITICAL findings. |
| `TC-003` | `project_factory` Happy Path (Mocked) | `tofu test` with valid `project_id`, `folder_id`, `billing_account_id`, `environment = "dev"`, and APIs list | Creates project with `auto_create_network = false`, `deletion_policy = "PREVENT"`, mandatory labels merged, and `disable_on_destroy = false` on all APIs. |
| `TC-004` | `project_factory` Input Validation (Mocked) | `tofu test` with invalid `environment = "qa"`, malformed `billing_account_id`, or uppercase `project_id` | Plan fails with explicit variable validation error (`expect_failures`). |
| `TC-005` | `vpc_network` `$0/mo` Default Path (Mocked) | `tofu test` with default inputs (`enable_cloud_nat = false`, `enable_flow_logs = false`) | Creates custom-mode VPC, subnet with `private_ip_google_access = true`, IAP SSH (`35.235.240.0/20`) + internal + deny-all-ingress firewalls, and **0** Cloud Router / Cloud NAT resources. |
| `TC-006` | `vpc_network` Opt-In NAT & Invalid CIDR (Mocked) | `tofu test` with `enable_cloud_nat = true`; separate negative test with `subnet_cidr = "not-a-cidr"` | Positive test creates Cloud Router + Cloud NAT (`nat_enabled == true`); negative test fails validation. |
| `TC-007` | `budget_guardrail` Thresholds & Validation (Mocked) | `tofu test` with `monthly_amount_usd = 50`, default thresholds `[0.5, 0.8, 1.0]`; negative test with `monthly_amount_usd = 0` | Positive test creates Monitoring email channel + project-scoped Billing Budget with 3 threshold rules; negative test fails validation. |
| `TC-008` | `envs/dev` Composition & Hygiene (Mocked) | `tofu test` on `envs/dev` with mocked providers | Composes `project_factory`, `vpc_network`, and `budget_guardrail` cleanly; wires `project_id`/`project_number` outputs between modules; `enable_cloud_nat` remains `false`. |
| `TC-009` | Bootstrap Hardening & WIF Least Privilege | Static inspection + `tofu plan` on `bootstrap/` | State bucket has versioning, UBLA, PAP enforced, `force_destroy = false`, `prevent_destroy = true`; KMS key has rotation + `prevent_destroy = true`; `sa-tofu-apply` WIF condition restricts strictly to `refs/heads/main`; zero `google_service_account_key` resources; zero Org-level IAM roles on CI SAs. |
| `TC-010` | Bootstrap Live Apply & KMS State Migration | Run `bootstrap/` locally against GCP Org, migrate state to Seed GCS with Cloud KMS encryption, remove `unencrypted` fallback | Platform Folder, Seed project, GCS bucket, KMS key, WIF pool/provider, and dual CI SAs exist; state object in GCS is encrypted ciphertext; subsequent `tofu plan` produces zero diff (idempotent). |
| `TC-011` | PR Workflow Read-Only Enforcement | Open a GitHub PR modifying `platform_unified_data_gcp/infra/envs/dev/` | `udp-gcp-pr-check.yml` passes static checks + `tofu test`, authenticates as `sa-tofu-plan`, runs `tofu plan -lock=false`, and posts plan output on the PR without mutating GCP or GCS state. |
| `TC-012` | Branch Security Boundary (Negative) | Attempt WIF token exchange for `sa-tofu-apply` from a non-`main` PR branch | GCP STS rejects impersonation with `403 PERMISSION_DENIED`. |
| `TC-013` | Main Branch Apply & Idempotency | Merge PR into `main` | `udp-gcp-apply-dev.yml` authenticates as `sa-tofu-apply`, provisions `dev` project, custom VPC, and Billing Budget; a re-run produces zero changes (`No changes`). |
| `TC-014` | Monorepo Graduation Readiness | Inspect all file references inside `platform_unified_data_gcp/` | Zero relative paths (`../`) escaping `platform_unified_data_gcp/`; `.terraform.lock.hcl` committed; project README documents bootstrap migration and standalone extraction steps. |
| `TC-015` | Bootstrap Script Validation, `tfvars` & Auto Plan/Apply (Mocked) | Run `scripts/test_bootstrap_init.sh` with stubbed `gcloud` and `tofu` on `PATH` (happy path `--auto-approve`, `--skip-apply`, invalid inputs) | Happy path auto-discovers Org/Billing/Admin, binds `folderAdmin`, `projectCreator`, and `billing.admin`, writes `terraform.tfvars`, and runs `tofu init` → `tofu plan` → `tofu apply`; `--skip-apply` runs `init` + `plan` only; invalid inputs or `--non-interactive` without `--auto-approve`/`--skip-apply` exit `2` with zero mutations. |
| `TC-016` | Bootstrap Script Dry-Run & Existing `tfvars` Reuse (Mocked) | Run `scripts/bootstrap_init.sh --dry-run` and re-run against an existing `terraform.tfvars` | `--dry-run` performs zero `add-iam-policy-binding` calls, zero `tofu` calls, and writes no files; re-run preserves existing `terraform.tfvars` values as defaults idempotently. |
