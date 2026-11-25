# Feature Spec: GCP Org Bootstrap, KMS State & Keyless WIF

- **Status:** Approved
- **Module / Component:** `platform_unified_data_gcp/infra/bootstrap` + `scripts/bootstrap_init.sh` (OpenTofu `>= 1.8`, `hashicorp/google ~> 6.0`, `integrations/github ~> 6.0`)
- **Archetype:** Infrastructure-as-Code & GitOps Contract (One-Time Bootstrap)
- **Tier:** Full Spec
- **Owner:** Xavier Ruiz

---

## 1. Goal & Context

### Problem Statement
Before any continuous GitOps environment (`envs/dev`) or reusable GCP modules can run autonomously, `platform_unified_data_gcp` requires a hardened, one-time Organization bootstrap layer. This bootstrap establishes the dedicated Platform Folder, Seed Project, client-side KMS-encrypted GCS remote state, keyless GitHub OIDC Workload Identity Federation (WIF) with dual least-privilege CI Service Accounts, and declarative GitHub Actions repository variables—automated via a safe local preflight script.

### Success Metrics
- `infra/bootstrap/` passes `tofu fmt -check -recursive`, `tofu validate`, `tflint`, `trivy config`, and offline `tofu test` (`mock_provider`) with zero HIGH/CRITICAL security findings.
- Live bootstrap apply + two-phase Cloud KMS state migration completes cleanly, producing an encrypted GCS state object and zero diff on re-plan.
- `scripts/test_bootstrap_init.sh` verifies preflight auto-discovery, validation, `--dry-run`, and `--skip-apply` / `--auto-approve` flows offline.
- Full verification coverage of `TC-001` through `TC-007`.

---

## 2. Scope & Explicit Non-Goals

### In Scope
- Automated preflight script `scripts/bootstrap_init.sh` (and offline mocked suite `scripts/test_bootstrap_init.sh`) for Org/Billing/GitHub auto-discovery, base Org IAM bindings, Billing Account & ADC verification, `terraform.tfvars` generation, and `tofu init` / `plan` / `apply` execution.
- One-time `infra/bootstrap/` root module provisioning:
  - Dedicated **Platform Folder** under `org_id` and **Seed GCP Project** linked to `billing_account_id`.
  - Hardened **GCS Remote State Bucket** (versioned, UBLA, PAP enforced, noncurrent lifecycle retention, `prevent_destroy`).
  - **Cloud KMS KeyRing & CryptoKey** (90-day rotation, `prevent_destroy`) for OpenTofu native `gcp_kms` client-side state encryption.
  - **WIF Pool & GitHub OIDC Provider** pinned to `var.github_repository` + dual CI Service Accounts (`sa-tofu-plan` read-only; `sa-tofu-apply` restricted to `refs/heads/main`) with Folder-scoped IAM only.
  - All 9 `UDP_GCP_*` GitHub Actions repository variables via `integrations/github` (`github_actions_variable`).

### Non-Goals (Do Not Implement)
- **No platform composition or Terragrunt environments:** `infra/platform` (consuming tag-pinned public GitHub modules) and Terragrunt `infra/envs/{dev,uat,prod}` live in Spec 03 (`specs/03_platform_and_terragrunt_envs.md`).
- **No CI/CD workflow YAML:** `.github/workflows/udp-gcp-*.yml` live in Spec 04 (`specs/04_github_actions_cicd.md`).
- **No static credentials:** Zero `google_service_account_key` resources or long-lived GCP JSON secrets.
- **No data platform workloads:** BigQuery, BigLake, Dataproc, Composer, and medallion buckets are deferred to future specs.

---

## 3. Functional Requirements

- `REQ-01`: **Toolchain & Version Pinning** — `infra/bootstrap/` shall declare `required_version` (`>= 1.8.0, < 2.0.0`), pin `hashicorp/google` (`~> 6.0`), `hashicorp/random` (`~> 3.6`), and `integrations/github` (`~> 6.0`), and commit `.terraform.lock.hcl`.
- `REQ-02`: **Platform Folder & Seed Project** — Create a Platform Folder under `org_id` and a Seed GCP project inside it linked to `billing_account_id`, with `auto_create_network = false`, random 4-char hex suffix on `seed_project_id`, mandatory platform labels (`managed_by = "opentofu"`, `platform`, `environment = "seed"`, `cost_center`), `deletion_policy = "PREVENT"`, and required bootstrap APIs (`cloudresourcemanager`, `iam`, `iamcredentials`, `sts`, `serviceusage`, `cloudbilling`, `storage`, `cloudkms`, `billingbudgets`, `monitoring`).
- `REQ-03`: **Hardened Remote State Bucket** — Create a GCS bucket in the Seed project with versioning enabled, `uniform_bucket_level_access = true`, `public_access_prevention = "enforced"`, noncurrent version retention (max 10 versions / 30-day age), `force_destroy = false`, and `lifecycle { prevent_destroy = true }`.
- `REQ-04`: **Cloud KMS State Encryption** — Create a Cloud KMS KeyRing and CryptoKey (90-day automatic rotation, `prevent_destroy = true`) in the Seed project and configure OpenTofu native `encryption` (`gcp_kms` + `aes_gcm`) for post-migration encrypted state.
- `REQ-05`: **Keyless WIF & Dual CI Service Accounts** — Configure a WIF Pool and GitHub OIDC Provider (`https://token.actions.githubusercontent.com`) restricting federation to `var.github_repository`, and provision `sa-tofu-plan` (read-only PRs/branches) and `sa-tofu-apply` (strictly `refs/heads/main`) with Folder/Bucket/KMS/Billing bindings only—zero Organization-level roles.
- `REQ-06`: **Declarative GitHub Actions Variables** — Provision all 9 `UDP_GCP_*` repository variables (`WIF_PROVIDER`, `PLAN_SA`, `APPLY_SA`, `STATE_BUCKET`, `STATE_KMS_KEY_ID`, `PLATFORM_FOLDER_ID`, `BILLING_ACCOUNT_ID`, `DEV_PROJECT_ID`, `BUDGET_ALERT_EMAIL`) via `github_actions_variable`.
- `REQ-07`: **Automated Bootstrap Preflight Script** — `scripts/bootstrap_init.sh` shall verify `gcloud`/`tofu`, reuse existing `terraform.tfvars` defaults, auto-discover Org/Billing/GitHub/admin metadata, validate inputs against `variables.tf` contracts, idempotently bind `folderAdmin`/`projectCreator`/`billing.admin` on the Org, verify Billing Account access & ADC alignment, write `terraform.tfvars` atomically, and run `tofu init` → `plan` → `apply` (supporting `--dry-run`, `--skip-apply`, `--auto-approve`, `--non-interactive`, and `--skip-adc-check`).

---

## 4. Interface & Data Contract

### 4.1 `infra/bootstrap` Inputs & Outputs

| Direction | Name | Type | Default / Required | Validation & Contract |
| :--- | :--- | :--- | :--- | :--- |
| Input | `org_id` | `string` | Required | Numeric GCP Organization ID (`^[0-9]+$`). |
| Input | `billing_account_id` | `string` | Required | Format `^[A-Z0-9]{6}-[A-Z0-9]{6}-[A-Z0-9]{6}$`. |
| Input | `github_repository` | `string` | Required | Exact `owner/repo` string. |
| Input | `platform_name` | `string` | `"unified-data-platform"` | Lowercase slug for Folder name, labels, and prefixes. |
| Input | `seed_project_id` | `string` | Required | Base prefix (4–25 chars, lowercase/digits/hyphens); random `-xxxx` suffix appended. |
| Input | `dev_project_id` | `string` | Required | Base prefix (4–25 chars), synced to `UDP_GCP_DEV_PROJECT_ID`. |
| Input | `budget_alert_email` | `string` | Required | Valid email synced to `UDP_GCP_BUDGET_ALERT_EMAIL`. |
| Input | `region` | `string` | `"us-central1"` | Primary region for state bucket and KMS KeyRing. |
| Input | `cost_center` | `string` | `"engineering-playground"` | Applied to mandatory `cost_center` label. |
| Output | `platform_folder_id` | `string` | — | Created Platform Folder ID (`folders/<id>`). |
| Output | `seed_project_id` | `string` | — | Provisioned Seed Project ID. |
| Output | `state_bucket_name` | `string` | — | GCS bucket name for OpenTofu remote state. |
| Output | `kms_key_id` | `string` | — | Fully qualified Cloud KMS CryptoKey ID for `gcp_kms`. |
| Output | `wif_provider_name` | `string` | — | Full WIF provider resource path for `google-github-actions/auth`. |
| Output | `plan_service_account_email` | `string` | — | Email of `sa-tofu-plan`. |
| Output | `apply_service_account_email` | `string` | — | Email of `sa-tofu-apply`. |

### 4.2 IAM & WIF Principal Matrix

| Principal | WIF Condition | Scope | Assigned Roles | Purpose |
| :--- | :--- | :--- | :--- | :--- |
| `sa-tofu-plan` | `assertion.repository == var.github_repository` | Platform Folder | `roles/viewer`, `roles/iam.securityReviewer` | Read-only PR plan & drift detection. |
| `sa-tofu-plan` | Same | Seed State Bucket | `roles/storage.objectViewer` | Read-only state access (`-lock=false`). |
| `sa-tofu-plan` | Same | Seed KMS Key | `roles/cloudkms.cryptoKeyDecrypter` | Decrypt state on PR plan (cannot write). |
| `sa-tofu-apply` | `assertion.repository == var.github_repository && assertion.ref == "refs/heads/main"` | Platform Folder | `projectCreator`, `projectDeleter`, `projectIamAdmin`, `compute.networkAdmin`, `serviceUsageAdmin`, `monitoring.notificationChannelEditor` | Manage environment projects, VPCs, APIs, and alerts under Platform Folder only. |
| `sa-tofu-apply` | Same | Billing Account | `roles/billing.user`, `roles/billing.costsManager` | Link environment projects & manage budgets. |
| `sa-tofu-apply` | Same | Seed State Bucket | `roles/storage.objectUser` | Read/write state and `.tflock` files. |
| `sa-tofu-apply` | Same | Seed KMS Key | `roles/cloudkms.cryptoKeyEncrypterDecrypter` | Decrypt & re-encrypt state on apply. |

### 4.3 `scripts/bootstrap_init.sh` CLI Summary
- **Value Flags** (all fall back to existing `tfvars` → auto-discovery): `--org-id`, `--billing-account`, `--github-repo`, `--seed-project-id`, `--dev-project-id`, `--budget-alert-email`, `--platform-name`, `--region`, `--cost-center`, `--admin-user`.
- **Mode Flags:** `--dry-run`, `--skip-apply`, `--auto-approve`, `--non-interactive` (requires `--auto-approve` or `--skip-apply` unless `--dry-run`), `--skip-adc-check`, `-h`/`--help`.
- **Exit Codes:** `0` = success; `1` = missing prerequisite, auth error, or GCP/OpenTofu failure; `2` = invalid flag, invalid input value, or missing required value in `--non-interactive` mode.

---

## 5. Invariants, Edge Cases & Failure Modes

### Key Invariants
1. **Zero Org-Wide CI Blast Radius:** Neither `sa-tofu-plan` nor `sa-tofu-apply` holds Organization-level IAM roles.
2. **Zero Static Credentials:** No `google_service_account_key` resources or JSON keys anywhere in code or CI.
3. **Two-Phase Encrypted State Migration:** Bootstrap applies locally first, migrates state to GCS with a temporary `unencrypted` fallback block (`tofu init -migrate-state`), verifies ciphertext in GCS, then removes the fallback so plaintext state is permanently rejected.
4. **Destruction Guardrails:** Seed project (`deletion_policy = "PREVENT"`), state bucket (`force_destroy = false`, `prevent_destroy = true`), and KMS key (`prevent_destroy = true`) reject accidental `tofu destroy`.
5. **External Billing Delegation:** When a Billing Account lives outside the GCP Org (e.g., under personal Gmail), the billing owner must grant `roles/billing.admin` directly on that Billing Account to the Org Admin once before bootstrap runs.

### Failure Mode Matrix

| Failure Condition | Expected Error / Status | Notes |
| :--- | :--- | :--- |
| Invalid `org_id`, `billing_account_id`, or `seed_project_id` | OpenTofu validation error (or script exit `2`) | Fails fast before any GCP API call or file write. |
| Non-`main` branch attempts to impersonate `sa-tofu-apply` | GCP STS `403 PERMISSION_DENIED` | Enforced server-side by WIF principal binding. |
| Missing `roles/billing.admin` on external Billing Account or mismatched ADC | `bootstrap_init.sh` exit `1` (or ADC refresh prompt) | Prints exact remediation before running `tofu apply`. |
| Accidental `tofu destroy` on `infra/bootstrap/` | OpenTofu lifecycle / `PREVENT` error | Protects Seed project, remote state, and KMS key. |
| `tofu init` without KMS decrypt permission after fallback removal | OpenTofu `Failed to decrypt state` | Fail-closed; refuses unreadable or plaintext state. |

---

## 6. Acceptance Criteria & Verification Matrix

| Case ID | Scenario | Input / Precondition | Expected Outcome |
| :--- | :--- | :--- | :--- |
| `TC-001` | Static hygiene & security scan | `infra/bootstrap/` tree | `tofu fmt -check`, `tofu validate`, `tflint`, and `trivy config` exit `0` with zero HIGH/CRITICAL findings. |
| `TC-002` | Hardening & WIF least privilege (Mocked) | `tofu test` / `tofu plan` on `infra/bootstrap/` | Bucket has versioning, UBLA, PAP enforced, `force_destroy = false`, `prevent_destroy = true`; KMS has rotation + `prevent_destroy = true`; `sa-tofu-apply` restricts to `refs/heads/main`; zero static keys or Org-level CI roles. |
| `TC-003` | Input validation negative tests (Mocked) | Invalid `org_id`, malformed `billing_account_id`, uppercase `seed_project_id` | Plan fails with explicit variable validation errors. |
| `TC-004` | Live bootstrap apply & KMS state migration | Local bootstrap apply against GCP Org → migrate to GCS + KMS → remove fallback | Platform Folder, Seed project, GCS bucket, KMS key, WIF, dual SAs, and 9 GitHub vars exist; GCS state object is encrypted ciphertext; re-plan yields zero diff. |
| `TC-005` | Branch security boundary (Negative) | Request WIF token for `sa-tofu-apply` from a non-`main` PR branch | GCP STS rejects with `403 PERMISSION_DENIED`. |
| `TC-006` | Preflight script happy path & modes (Mocked) | `scripts/test_bootstrap_init.sh` with stubbed `gcloud`/`tofu` (`--auto-approve`, `--skip-apply`, invalid inputs) | Auto-discovers values, binds Org roles, writes `terraform.tfvars`, runs `init`→`plan`→`apply` (`--skip-apply` stops after `plan`); invalid args or unattended `--non-interactive` exit `2` with zero mutations. |
| `TC-007` | Preflight dry-run & idempotent `tfvars` reuse (Mocked) | Run `--dry-run` and re-run against existing `terraform.tfvars` | `--dry-run` makes zero GCP/file/OpenTofu mutations; re-run preserves existing `terraform.tfvars` defaults. |
