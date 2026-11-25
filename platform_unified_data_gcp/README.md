# Unified Data Platform — GCP Foundation (`platform_unified_data_gcp`)

OpenTofu-managed GCP foundation and GitOps platform governed by three lifecycle-scoped specs:
- [Spec 01: GCP Org Bootstrap, KMS State & Keyless WIF](./specs/01_gcp_bootstrap_and_wif.md)
- [Spec 02: Reusable GCP Core Modules](./specs/02_gcp_core_modules.md)
- [Spec 03: `envs/dev` Composition & GitHub Actions GitOps Workflows](./specs/03_dev_env_and_gitops.md)

## Architecture Overview

- **IaC Engine:** OpenTofu (`>= 1.8`, plain modular HCL, `hashicorp/google ~> 6.0`).
- **Org & Project Topology:** One-time `infra/bootstrap/` creates a dedicated **Platform Folder** under your GCP Organization, a **Seed Project** (GCS versioned state bucket + Cloud KMS state encryption key + GitHub Actions WIF Pool/Provider), and **dual CI Service Accounts** scoped strictly to the Platform Folder (zero Org-wide roles).
- **Keyless GitOps (GitHub Actions + WIF):**
  - `sa-tofu-plan`: Read-only on Folder/Projects/GCS/KMS; runs `tofu plan -lock=false` on PRs.
  - `sa-tofu-apply`: Restricted server-side via WIF attribute condition to `refs/heads/main`; runs serialized `tofu apply` with GCS locking.
- **Environment Modules (`infra/envs/dev`):**
  - `modules/project_factory`: Creates the `dev` GCP project under the Platform Folder, links Billing, enables declared APIs (`disable_on_destroy = false`), enforces mandatory labels, and defaults `deletion_policy = "PREVENT"`.
  - `modules/vpc_network`: Custom-mode VPC (`auto_create_network = false`), primary regional subnet with Private Google Access, IAP SSH + internal + deny-all-ingress firewall rules, and opt-in Cloud Router/NAT (`enable_cloud_nat = false` for a `$0/mo` idle baseline).
  - `modules/budget_guardrail`: Project-scoped Billing Budget (50% / 80% / 100%) + Cloud Monitoring email notification channel.

## Local Prerequisites

```bash
brew install opentofu trivy terraform-linters/tap/tflint
# Plus gcloud CLI authenticated as an Org/Billing Admin for the one-time bootstrap step:
gcloud auth application-default login
```

## Quality & Offline Verification

All static checks, security scans, and mocked unit tests run locally with zero GCP credentials or cost:

```bash
# Formatting
tofu fmt -check -recursive platform_unified_data_gcp/infra

# Validate all roots and modules
for d in bootstrap modules/project_factory modules/vpc_network modules/budget_guardrail envs/dev; do
  tofu -chdir="platform_unified_data_gcp/infra/${d}" init -backend=false
  tofu -chdir="platform_unified_data_gcp/infra/${d}" validate
done

# TFLint (Google ruleset)
(cd platform_unified_data_gcp && tflint --init --config="$(pwd)/.tflint.hcl" && tflint --recursive --config="$(pwd)/.tflint.hcl" --chdir=infra)

# Trivy IaC security scan
trivy config --severity HIGH,CRITICAL --exit-code 1 platform_unified_data_gcp/infra

# Mocked OpenTofu unit tests
for d in bootstrap modules/project_factory modules/vpc_network modules/budget_guardrail envs/dev; do
  tofu -chdir="platform_unified_data_gcp/infra/${d}" test -verbose
done
```

## One-Time Bootstrap & Cloud KMS State Migration Runbook

Because `infra/bootstrap/` creates the GCS state bucket and Cloud KMS key that store and encrypt its own state, bootstrap follows a deterministic **2-phase migration**.

### Phase 1: Automated Org IAM, ADC, `terraform.tfvars` & Bootstrap Apply

> **Prerequisite — External / Personal Billing Account:** If your Billing Account was created outside your GCP Organization (for example, under a personal `@gmail.com` account), Org-level `roles/billing.admin` cannot reach it. Grant your Org Admin identity **`Billing Account Administrator`** (`roles/billing.admin`) directly on the Billing Account once from the billing owner's account:
> - **GCP Console:** Open `https://console.cloud.google.com/billing/<billing-account-id>/manage` as the billing owner → **Add Principal** → add `admin@yourdomain.com` with role **`Billing Account Administrator`** → **Save** *(optionally click **Change Organization** on the same page to move the Billing Account into your Org)*.
> - **`gcloud` CLI:**
>   ```bash
>   # Temporarily sign in as the account that owns the Billing Account
>   gcloud auth login
>   gcloud billing accounts add-iam-policy-binding "<billing-account-id>" \
>     --member="user:admin@yourdomain.com" \
>     --role="roles/billing.admin"
>   # Switch gcloud back to your Org Admin
>   gcloud config set account "admin@yourdomain.com"
>   ```

In GCP, `roles/resourcemanager.organizationAdmin` only manages IAM policies and deliberately omits `resourcemanager.folders.create`, `resourcemanager.projects.create`, and billing admin permissions. Run `scripts/bootstrap_init.sh` once as your Org Admin—it auto-discovers your Org/Billing/GitHub repo, idempotently binds `roles/resourcemanager.folderAdmin`, `roles/resourcemanager.projectCreator`, and `roles/billing.admin` on the Org, verifies Billing Account access and ADC, populates `infra/bootstrap/terraform.tfvars`, and automatically runs `tofu init`, `tofu plan`, and `tofu apply`:

```bash
# Authenticate gcloud CLI as your Org Admin first (one time)
gcloud auth login

# Optional: preview planned IAM bindings, terraform.tfvars, and tofu commands (no mutations)
./platform_unified_data_gcp/scripts/bootstrap_init.sh --dry-run

# Run full bootstrap (prompts before applying tfplan; use --auto-approve or --skip-apply as needed)
./platform_unified_data_gcp/scripts/bootstrap_init.sh
```

> Re-running `bootstrap_init.sh` is idempotent and preserves existing `infra/bootstrap/terraform.tfvars` values as defaults. Record the printed outputs (`platform_folder_id`, `state_bucket_name`, `kms_key_id`, `wif_provider_name`, `plan_service_account_email`, `apply_service_account_email`) before moving to Phase 2.

### Phase 2: Migrate Bootstrap State to Encrypted GCS
1. Uncomment the `backend "gcs"` block in `infra/bootstrap/backend.tf` (prefix `bootstrap`).
2. Uncomment the `encryption` block in `infra/bootstrap/encryption.tf`, including the temporary `fallback { method = method.unencrypted.migrate }` block, and pass `TF_VAR_state_kms_key_id=<kms_key_id>`.
3. Migrate local state to GCS and encrypt it:
   ```bash
   export TF_VAR_state_kms_key_id="<kms_key_id>"
   tofu init -migrate-state -backend-config="bucket=<state_bucket_name>"
   ```
4. Verify the GCS state object is encrypted ciphertext (`gsutil cat gs://<state_bucket_name>/bootstrap/default.tfstate | head -c 200` shows `"meta"` + `"encrypted_data"`, not plaintext resources).
5. **Remove** the `unencrypted` `fallback` block in `infra/bootstrap/encryption.tf` so plaintext state is permanently rejected, delete local `terraform.tfstate*`, and run `tofu plan` to confirm zero diff.

## GitHub Actions Repository Variables (Managed Declaratively)

All 9 GitHub Actions repository variables below are **automatically provisioned and drift-managed by `infra/bootstrap/github_actions.tf`** using the `integrations/github` provider (`bootstrap_init.sh` automatically reads `GITHUB_TOKEN` from your environment or `gh auth token`—just run `gh auth login` once beforehand; no manual GitHub Settings UI clicks required):

| Variable | Source (`bootstrap` output / value) |
| :--- | :--- |
| `UDP_GCP_WIF_PROVIDER` | `wif_provider_name` |
| `UDP_GCP_PLAN_SA` | `plan_service_account_email` |
| `UDP_GCP_APPLY_SA` | `apply_service_account_email` |
| `UDP_GCP_STATE_BUCKET` | `state_bucket_name` |
| `UDP_GCP_STATE_KMS_KEY_ID` | `kms_key_id` |
| `UDP_GCP_PLATFORM_FOLDER_ID` | `platform_folder_id` |
| `UDP_GCP_BILLING_ACCOUNT_ID` | Your GCP Billing Account ID (`XXXXXX-XXXXXX-XXXXXX`) |
| `UDP_GCP_DEV_PROJECT_ID` | Globally unique `dev` project ID (e.g., `udp-dev-<suffix>`) |
| `UDP_GCP_BUDGET_ALERT_EMAIL` | Email address for dev billing budget alerts |

## Graduating to a Standalone Repository

`platform_unified_data_gcp/` has zero relative imports outside its directory. To promote it to its own repository:

1. Extract the subtree into a new repository:
   ```bash
   git subtree split --prefix=platform_unified_data_gcp -b graduate-udp-gcp
   ```
2. Copy `.github/workflows/udp-gcp-*.yml` into the new repository's `.github/workflows/` and set `PROJECT_DIR: "."` (and update path filters to `infra/**`).
3. Update `github_repository` in `infra/bootstrap/terraform.tfvars` and apply bootstrap to re-bind the WIF `attribute_condition` to the new repository.
