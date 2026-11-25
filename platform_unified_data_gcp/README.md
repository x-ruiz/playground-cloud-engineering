# Unified Data Platform — GCP Foundation (`platform_unified_data_gcp`)

OpenTofu + Terragrunt GCP foundation and GitOps platform governed by lifecycle-scoped specs:
- [Spec 01: GCP Org Bootstrap, KMS State & Keyless WIF](./specs/01_gcp_bootstrap_and_wif.md)
- [Spec 02: Reusable GCP Core Modules](./specs/02_gcp_core_modules.md) *(Superseded by Spec 03)*
- [Spec 03: Tag-Pinned Platform Module & DRY Terragrunt Environments (`dev`/`uat`/`prod`)](./specs/03_platform_and_terragrunt_envs.md)
- [Spec 04: GitHub Actions GitOps CI/CD & Tag-Based Environment Promotion](./specs/04_github_actions_cicd.md)

## Architecture Overview

- **IaC Engine:** OpenTofu (`>= 1.12.2`, `hashicorp/google ~> 8.10`, `hashicorp/google-beta ~> 8.10`, `hashicorp/random ~> 3.6`) + **Terragrunt** (`TG_TF_PATH=tofu`) for DRY `dev` / `uat` / `prod` environment wrappers around a single `infra/platform/` root module.
- **Zero Local Module Duplication:** `infra/platform/` sources official public GitHub GCP modules directly by immutable release tag (`GoogleCloudPlatform/cloud-foundation-fabric` `v60.0.0` for `project`, `net-vpc`, `net-vpc-firewall`, opt-in `net-cloudnat`; `terraform-google-modules/terraform-google-project-factory` `v18.4.0` for `budget`).
- **Org & Project Topology:** One-time `infra/bootstrap/` creates a dedicated **Platform Folder** under your GCP Organization, a **Seed Project** (GCS versioned state bucket + Cloud KMS state encryption key + GitHub Actions WIF Pool/Provider), **dual CI Service Accounts** scoped strictly to the Platform Folder (zero Org-wide roles), and declarative GitHub Actions repository variables via `integrations/github`.
- **Keyless GitOps (GitHub Actions + WIF):**
  - `sa-tofu-plan`: Read-only on Folder/Projects/GCS/KMS; runs `terragrunt plan -lock=false` on PRs for **only the environments affected by the diff**.
  - `sa-tofu-apply`: Restricted server-side via WIF attribute condition to `refs/heads/main`; on merge applies **only the affected environment(s)**.
- **Trunk-Based Tag Promotion:** `infra/platform/` (with its atomic `module-versions.yaml`) is released as immutable annotated Git tags `udp-gcp-vX.Y.Z`. `dev` tracks `main` HEAD; `uat` and `prod` each pin a tag in `infra/envs/<env>/release.yaml`, so merges to `infra/platform/**` never touch `uat`/`prod` until promoted via a 1-line Promotion PR.
- **DRY Terragrunt Wrappers (`infra/envs/{root.hcl, dev, uat, prod}`):**
  - `infra/envs/root.hcl` exposes `platform_git_source` and dynamically generates `backend.tf` (`envs/<env>` prefix), `encryption.tf` (Cloud KMS), and `provider.tf` (`google` + `google-beta`) with zero `.tf` files inside `infra/envs/`.

## Local Prerequisites

```bash
brew install opentofu terragrunt trivy terraform-linters/tap/tflint
# Plus gcloud CLI and gh CLI for one-time bootstrap:
gcloud auth login && gcloud auth application-default login
gh auth login
```

## Quality & Offline Verification

All static checks, security scans, and mocked unit tests run locally with zero GCP credentials or cost:

```bash
# Formatting (OpenTofu + Terragrunt)
tofu fmt -check -recursive platform_unified_data_gcp/infra
terragrunt hcl fmt --check --working-dir platform_unified_data_gcp/infra/envs

# Validate Bootstrap & Platform (OpenTofu) and envs (Terragrunt native generation, offline mode)
tofu -chdir="platform_unified_data_gcp/infra/bootstrap" init -backend=false
tofu -chdir="platform_unified_data_gcp/infra/bootstrap" validate
tofu -chdir="platform_unified_data_gcp/infra/platform" init -backend=false
tofu -chdir="platform_unified_data_gcp/infra/platform" validate
UDP_GCP_OFFLINE_TEST=true terragrunt init --non-interactive --working-dir platform_unified_data_gcp/infra/envs/dev -backend=false
UDP_GCP_OFFLINE_TEST=true terragrunt validate --non-interactive --working-dir platform_unified_data_gcp/infra/envs/dev

# TFLint (Google ruleset)
(cd platform_unified_data_gcp && tflint --init --config="$(pwd)/.tflint.hcl" && tflint --recursive --config="$(pwd)/.tflint.hcl" --chdir=infra)

# Trivy IaC security scan (excluding downloaded .terraform / .terragrunt-cache vendor dirs)
trivy config --severity HIGH,CRITICAL --exit-code 1 --skip-dirs '**/.terraform' --skip-dirs '**/.terragrunt-cache' platform_unified_data_gcp/infra

# Mocked unit tests (Bootstrap + Platform direct & via Terragrunt + Preflight & CI change-detection scripts)
./platform_unified_data_gcp/scripts/test_bootstrap_init.sh
./platform_unified_data_gcp/scripts/test_detect_affected_envs.sh
tofu -chdir="platform_unified_data_gcp/infra/bootstrap" test -verbose
tofu -chdir="platform_unified_data_gcp/infra/platform" test -verbose
UDP_GCP_OFFLINE_TEST=true terragrunt test --non-interactive --working-dir platform_unified_data_gcp/infra/envs/dev -verbose
```

## Updating Upstream Module Versions (DRY — Zero Sync Scripts)

Edit the pinned semantic release tag once in [`infra/platform/module-versions.yaml`](./infra/platform/module-versions.yaml). [`infra/platform/main.tf`](./infra/platform/main.tf) reads it natively via `yamldecode(file("${path.module}/module-versions.yaml"))` into early-evaluated `locals` and interpolates `?ref=${local.cff_version}` / `?ref=${local.project_factory_version}` in `module.source` (OpenTofu 1.8+ Early Evaluation)—no sync scripts or generated module files needed. Because the manifest lives inside `infra/platform/`, an upstream bump rolls out to `dev` only and reaches `uat`/`prod` inside the next promoted `udp-gcp-vX.Y.Z` tag.

## Environment Promotion (`dev` → `uat` → `prod`)

| Change | PR Check plans | Merge applies |
| :--- | :--- | :--- |
| `infra/platform/**` (incl. `module-versions.yaml`), `infra/envs/dev/**` | `dev` | `dev` |
| `infra/envs/uat/**` (incl. `release.yaml`) | `uat` (if released) | `uat` |
| `infra/envs/prod/**` (incl. `release.yaml`) | `prod` (if released) | `prod` |
| `infra/envs/root.hcl` | `dev` + released `uat`/`prod` | `dev` → `uat` → `prod` |
| `infra/bootstrap/**`, `scripts/**`, `specs/**`, docs | none (static checks only) | none |

1. **Develop:** merge feature PRs to `main`; they plan and deploy `dev` only. Ship new capabilities behind opt-in `enable_*` flags defaulting to `false`.
2. **Promote `dev` → `uat`:** run **Actions → UDP GCP — Promote Platform Release** with `promotion=dev-to-uat` and a `bump` (`patch | minor | major`; the first release is always `udp-gcp-v0.1.0`). It cuts an annotated tag on `main` HEAD (or reuses one already there) and opens a Promotion PR bumping `infra/envs/uat/release.yaml`, including the commit changelog, file stats and the HCL diff. Review the `uat` plan comment and merge to deploy `uat` only.
3. **Promote `uat` → `prod`:** run the same workflow with `promotion=uat-to-prod`. It never cuts a new tag — it promotes the exact tag in `uat/release.yaml` — and opens a Promotion PR for `prod`.
4. **Rollback:** revert the Promotion PR; the 1-line `release.yaml` revert plans and applies the previous tag for that environment only.

> **Promotion PR checks:** PRs opened with the default `GITHUB_TOKEN` do not trigger `udp-gcp-pr-check.yml` (GitHub anti-recursion rule). Add an optional `UDP_GCP_PROMOTE_TOKEN` repository secret (fine-grained PAT, `contents: write` + `pull-requests: write` on this repo) so Promotion PRs are planned automatically; otherwise close & reopen the PR.
>
> **Local `uat`/`prod` runs:** Terragrunt fetches `${platform_git_source}?ref=<tag>` over HTTPS from this private repository—run `gh auth setup-git` once, or export `UDP_GCP_PLATFORM_REPO` with an SSH URL (e.g. `git@github.com:<owner>/<repo>.git`). While `release.yaml` is `"unreleased"`, `uat`/`prod` cannot be planned (CI skips them).

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
2. Uncomment `variable "state_kms_key_id"` and the `encryption` block in `infra/bootstrap/encryption.tf`. Keep `enforced = false` together with the temporary `method "unencrypted" "migrate"` and `fallback` blocks so OpenTofu can read your plaintext local `terraform.tfstate` during the one-time migration.
3. Grant your local operator user KMS encrypt/decrypt access on the state key (project `roles/owner` deliberately excludes KMS data-plane access), then migrate local state to GCS and encrypt it (note the required `bucket=` key inside `-backend-config`):
   ```bash
   cd platform_unified_data_gcp/infra/bootstrap

   # Read outputs before migrating (if not already recorded)
   STATE_BUCKET="$(tofu output -raw state_bucket_name)"
   export TF_VAR_state_kms_key_id="$(tofu output -raw kms_key_id)"

   # Ensure your local Org Admin can encrypt/decrypt the bootstrap state via Cloud KMS
   gcloud kms keys add-iam-policy-binding "${TF_VAR_state_kms_key_id}" \
     --member="user:$(gcloud config get-value account)" \
     --role="roles/cloudkms.cryptoKeyEncrypterDecrypter"

   # Migrate local plaintext state to encrypted GCS state
   tofu init -migrate-state -backend-config="bucket=${STATE_BUCKET}"
   ```
4. Verify the GCS state object is encrypted ciphertext (`gcloud storage cat "gs://${STATE_BUCKET}/bootstrap/default.tfstate" | head -c 200` shows `"meta"` + `"encrypted_data"`, not plaintext resources).
5. **Lock down encryption:** Remove the `method "unencrypted" "migrate"` and `fallback` blocks in `infra/bootstrap/encryption.tf`, set `enforced = true` so plaintext state is permanently rejected, delete local `terraform.tfstate*`, and run `tofu plan` to confirm zero diff.

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
2. Copy `.github/workflows/udp-gcp-*.yml` (`pr-check`, `apply`, `promote`) into the new repository's `.github/workflows/` and set `PROJECT_DIR: "."` (and update path filters to `infra/**`). `UDP_GCP_PLATFORM_REPO` is derived from `github.repository` in CI, and `root.hcl` derives the `infra/platform` subpath from the Git root, so tagged sources follow automatically (override `UDP_GCP_PLATFORM_REPO` locally if needed). Push the existing `udp-gcp-v*` tags to the new repository so `release.yaml` pins keep resolving.
3. Update `github_repository` in `infra/bootstrap/terraform.tfvars` and apply bootstrap to re-bind the WIF `attribute_condition` to the new repository.
