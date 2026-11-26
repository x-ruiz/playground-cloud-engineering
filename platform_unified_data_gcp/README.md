# Unified Data Platform — GCP Foundation (`platform_unified_data_gcp`)

OpenTofu + Terragrunt GCP foundation and GitOps platform governed by lifecycle-scoped specs *(Org bootstrap graduated to [x-ruiz/platform_gcp_org_bootstrap](https://github.com/x-ruiz/platform_gcp_org_bootstrap))*:
- [Spec 01: Platform Module Setup & Ownership Model](./specs/01_platform_module_setup.md)
- [Spec 02: GitHub Actions GitOps CI/CD & Tag-Based Environment Promotion](./specs/02_github_actions_cicd.md)
- [Spec 03: GCP Data Lakehouse Reference Architecture](./specs/03_data_lakehouse_architecture.md) *(Draft)*
- [Spec 04: Domain Manifest, Bronze Storage & BigLake Catalog](./specs/04_bronze_storage_and_catalog.md)

## Architecture Overview

- **IaC Engine:** OpenTofu (`>= 1.12.2`, `hashicorp/google ~> 8.10`, `hashicorp/google-beta ~> 8.10`, `hashicorp/random ~> 3.6`) + **Terragrunt** (`TG_TF_PATH=tofu`) for DRY `dev` / `uat` / `prod` environment wrappers around a single `infra/platform/` root module.
- **Zero Local Module Duplication:** `infra/platform/` sources official public GitHub GCP modules directly by immutable release tag (`GoogleCloudPlatform/cloud-foundation-fabric` `v60.0.0` for `project`, `net-vpc`, `net-vpc-firewall`, opt-in `net-cloudnat`; `terraform-google-modules/terraform-google-project-factory` `v18.4.0` for `budget`).
- **Org & Folder Foundation (Graduated):** One-time Org bootstrap (Platform Folder, Seed Project, Cloud KMS-encrypted GCS state bucket, keyless GitHub Actions WIF, and Org/Folder policies) graduated into its own standalone repository: **[x-ruiz/platform_gcp_org_bootstrap](https://github.com/x-ruiz/platform_gcp_org_bootstrap)**. This repository strictly owns the platform module (`infra/platform/`) and environment compositions (`infra/envs/{dev,uat,prod}`, including `udp-dev` and billing budgets).
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

# Validate Platform (OpenTofu) and envs (Terragrunt native generation, offline mode)
tofu -chdir="platform_unified_data_gcp/infra/platform" init -backend=false
tofu -chdir="platform_unified_data_gcp/infra/platform" validate
UDP_GCP_OFFLINE_TEST=true terragrunt init --non-interactive --working-dir platform_unified_data_gcp/infra/envs/dev -backend=false
UDP_GCP_OFFLINE_TEST=true terragrunt validate --non-interactive --working-dir platform_unified_data_gcp/infra/envs/dev

# TFLint (Google ruleset)
(cd platform_unified_data_gcp && tflint --init --config="$(pwd)/.tflint.hcl" && tflint --recursive --config="$(pwd)/.tflint.hcl" --chdir=infra)

# Trivy IaC security scan (excluding downloaded .terraform / .terragrunt-cache vendor dirs)
trivy config --severity HIGH,CRITICAL --exit-code 1 --skip-dirs '**/.terraform' --skip-dirs '**/.terragrunt-cache' platform_unified_data_gcp/infra

# Mocked unit tests (Platform direct & via Terragrunt + CI change-detection scripts)
./platform_unified_data_gcp/scripts/test_detect_affected_envs.sh
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

## One-Time Org Bootstrap & GitHub Actions Variables

One-time GCP Organization bootstrap (Platform Folder, Seed Project, GCS remote state, Cloud KMS encryption key, keyless WIF, and Org/Folder policies) now lives in **[x-ruiz/platform_gcp_org_bootstrap](https://github.com/x-ruiz/platform_gcp_org_bootstrap)**.

The 7 org-owned GitHub Actions repository variables below are provisioned declaratively by `platform_gcp_org_bootstrap` for the `unified-data-platform` folder, while the 2 platform/environment-owned variables (`UDP_GCP_DEV_PROJECT_ID`, `UDP_GCP_BUDGET_ALERT_EMAIL`) belong to this repository:

| Variable | Owner | Source |
| :--- | :--- | :--- |
| `UDP_GCP_WIF_PROVIDER` | Org Bootstrap | `platform_gcp_org_bootstrap` (`wif_provider_name`) |
| `UDP_GCP_PLAN_SA` | Org Bootstrap | `platform_gcp_org_bootstrap` (`folder_ci_identities["unified-data-platform"].plan_service_account_email`) |
| `UDP_GCP_APPLY_SA` | Org Bootstrap | `platform_gcp_org_bootstrap` (`folder_ci_identities["unified-data-platform"].apply_service_account_email`) |
| `UDP_GCP_STATE_BUCKET` | Org Bootstrap | `platform_gcp_org_bootstrap` (`state_bucket_name`) |
| `UDP_GCP_STATE_KMS_KEY_ID` | Org Bootstrap | `platform_gcp_org_bootstrap` (`kms_key_id`) |
| `UDP_GCP_PLATFORM_FOLDER_ID` | Org Bootstrap | `platform_gcp_org_bootstrap` (`folder_ids["unified-data-platform"]`) |
| `UDP_GCP_BILLING_ACCOUNT_ID` | Org Bootstrap | `platform_gcp_org_bootstrap` (`billing_account_id`) |
| `UDP_GCP_DEV_PROJECT_ID` | Platform Repo | Globally unique `dev` project ID prefix (e.g., `udp-dev-<suffix>`) |
| `UDP_GCP_BUDGET_ALERT_EMAIL` | Platform Repo | Email address for environment billing budget alerts |

## Graduating to a Standalone Repository

`platform_unified_data_gcp/` has zero relative imports outside its directory. To promote it to its own repository:

1. Extract the subtree into a new repository:
   ```bash
   git subtree split --prefix=platform_unified_data_gcp -b graduate-udp-gcp
   ```
2. Copy `.github/workflows/udp-gcp-*.yml` (`pr-check`, `apply`, `promote`) into the new repository's `.github/workflows/` and set `PROJECT_DIR: "."` (and update path filters to `infra/**`). `UDP_GCP_PLATFORM_REPO` is derived from `github.repository` in CI, and `root.hcl` derives the `infra/platform` subpath from the Git root, so tagged sources follow automatically (override `UDP_GCP_PLATFORM_REPO` locally if needed). Push the existing `udp-gcp-v*` tags to the new repository so `release.yaml` pins keep resolving.
3. Update `folders["unified-data-platform"].ci.github_repository` in [`platform_gcp_org_bootstrap`](https://github.com/x-ruiz/platform_gcp_org_bootstrap) and apply to re-bind WIF and sync the 7 org-owned GitHub Actions variables to the new repository.
