# Feature Spec: GitHub Actions GitOps CI/CD Pipelines (`udp-gcp-*`)

- **Status:** Approved
- **Module / Component:** `<repo-root>/.github/workflows/udp-gcp-pr-check.yml` + `<repo-root>/.github/workflows/udp-gcp-apply.yml` (GitHub Actions + GCP WIF + OpenTofu + Terragrunt)
- **Archetype:** CI/CD & GitOps Automation Contract
- **Tier:** Full Spec
- **Owner:** Xavier Ruiz
- **Depends On:** `specs/01_gcp_bootstrap_and_wif.md`, `specs/03_platform_and_terragrunt_envs.md`

---

## 1. Goal & Context

### Problem Statement
With Org bootstrap/WIF (Spec 01) and the DRY tag-pinned platform + Terragrunt environment wrappers (Spec 03) in place, `platform_unified_data_gcp` needs a dedicated, extensible CI/CD specification governing PR verification, supply-chain guardrails, read-only multi-environment plans, serialized applies, and `dev` → `uat` → `prod` promotion gates—kept separate from infrastructure module specs so CI/CD capabilities (e.g., drift detection, cost estimation, policy gates) can evolve independently.

### Success Metrics
- Pull requests run all static quality, security, tag-pinning, and mocked test gates before touching GCP, then post per-environment read-only `terragrunt plan -lock=false` summaries (`dev`, `uat`, `prod`) under `sa-tofu-plan`.
- Merges to `main` automatically apply `dev` under `sa-tofu-apply` with serialized concurrency, and gate `uat` and `prod` behind GitHub Environment manual approvals.
- Zero static GCP credentials exist in GitHub Secrets; all GCP access uses short-lived OIDC WIF tokens (`id-token: write`).
- Workflows remain strictly path-scoped to `platform_unified_data_gcp/**` at `<repo-root>/.github/workflows/` (required by GitHub Actions discovery) while remaining cleanly portable upon standalone repository graduation.
- Full verification coverage of `TC-001` through `TC-006`.

---

## 2. Scope & Explicit Non-Goals

### In Scope
- `<repo-root>/.github/workflows/udp-gcp-pr-check.yml`:
  - **Job 1 (`static-checks`):** Formatting (`tofu fmt -check -recursive`, `terragrunt hcl fmt --check`), layout invariants (zero `.tf` under `infra/envs/`, zero local `infra/modules/`, zero hardcoded `?ref=` in `infra/platform/*.tf`), `infra/module-versions.yaml` schema & semver tag validation, `terragrunt render` verification across `dev`/`uat`/`prod`, `tofu validate` (`bootstrap`) + `terragrunt validate` (`envs/dev` offline), `tflint` (Google ruleset), `trivy config` (HIGH/CRITICAL gate), `scripts/test_bootstrap_init.sh`, and offline mocked tests (`tofu test` on `bootstrap` + `terragrunt test` on `envs/dev`).
  - **Job 2 (`plan`, matrix `[dev, uat, prod]`, gated on Job 1):** Keyless WIF auth as `sa-tofu-plan`, `TG_TF_PATH=tofu terragrunt init` + `terragrunt plan -lock=false -no-color`, and upserted per-environment PR comments (`<!-- udp-gcp-<env>-plan -->`).
- `<repo-root>/.github/workflows/udp-gcp-apply.yml`:
  - Triggers on pushes to `main` touching `infra/platform/**`, `infra/envs/**`, or `.github/workflows/udp-gcp-apply.yml`, plus manual `workflow_dispatch` targeting a single chosen environment (`dev | uat | prod`).
  - Three isolated jobs (`apply-dev`, `apply-uat`, `apply-prod`) authenticating via WIF as `sa-tofu-apply`, each with its own concurrency group (`udp-gcp-<env>-apply`, `cancel-in-progress: false`).
  - `apply-dev` runs automatically on merge to `main`; `apply-uat` and `apply-prod` require manual approval via GitHub Environments (`uat`, `prod`).
- Explicit least-privilege `permissions` declarations (`permissions: {}` at workflow root, minimal grants per job).

### Non-Goals (Do Not Implement Yet — Future CI/CD Iterations)
- **Scheduled drift detection cron workflow** (future Spec 05+ enhancement).
- **Automated FinOps / Infracost PR comments** (future enhancement).
- **Self-hosted runners, Atlantis, or HCP Terraform** (GitHub-hosted `ubuntu-latest` + WIF only).
- **Workflows nested inside `platform_unified_data_gcp/.github/workflows/`** (unsupported by GitHub Actions discovery; workflows stay at `<repo-root>/.github/workflows/` until repo graduation).

---

## 3. Functional Requirements

- `REQ-01`: **Path-Scoped Triggers & Least-Privilege Permissions** — Both workflows shall live at `<repo-root>/.github/workflows/`, declare top-level `permissions: {}` with minimal job-level permissions, and restrict triggers strictly to `platform_unified_data_gcp/**` and `.github/workflows/udp-gcp-*.yml` so sibling projects in `playground-cloud-engineering` are unaffected.
- `REQ-02`: **Pinned CI Tooling & OpenTofu Binding** — Both workflows shall pin explicit versions of OpenTofu, Terragrunt, TFLint, and Trivy Action, and export `TG_TF_PATH=tofu` so Terragrunt always invokes OpenTofu.
- `REQ-03`: **PR Static Quality, Security & Hygiene Gate (`static-checks`)** — `udp-gcp-pr-check.yml` shall fail fast before authenticating to GCP if any of the following fail:
  - `tofu fmt -check -recursive` and `terragrunt hcl fmt --check`
  - Structural invariants: zero `.tf` files inside `infra/envs/`, absence of `infra/modules/`, and zero hardcoded `?ref=v...` tag literals in `infra/platform/*.tf` (all upstream sources use `?ref=${var.*}`)
  - Supply-chain & DRY manifest invariant: validate `infra/module-versions.yaml` (every `version` matches `^v[0-9]+\.[0-9]+\.[0-9]+$`) and verify `terragrunt render --json` across `dev`/`uat`/`prod` passes `cff_version` & `project_factory_version` from `infra/module-versions.yaml`
  - `tofu init -backend=false && tofu validate` on `bootstrap` + `terragrunt init -backend=false && terragrunt validate` on `envs/dev` (offline mode)
  - `tflint --recursive` (Google ruleset) and `trivy config --severity HIGH,CRITICAL --exit-code 1` (skipping `.terraform` / `.terragrunt-cache` vendor directories)
  - `bash -n` + `scripts/test_bootstrap_init.sh` + mocked `tofu test` (`bootstrap`) + mocked `terragrunt test` (`envs/dev` offline mode)
- `REQ-04`: **PR Read-Only Multi-Environment Plan (`plan`)** — Gated on `static-checks`, `udp-gcp-pr-check.yml` shall run a matrix over `[dev, uat, prod]` (`fail-fast: false`), authenticate via WIF as `sa-tofu-plan`, run `terragrunt plan --non-interactive -lock=false -input=false -no-color`, and create or update a dedicated PR comment per environment (truncating safely below GitHub's 65,536-char comment limit) before failing the job if plan errored.
- `REQ-05`: **Main-Branch Serialized Apply & Promotion Gates (`udp-gcp-apply.yml`)** — On push to `main` touching `infra/platform/**`, `infra/envs/**`, or `.github/workflows/udp-gcp-apply.yml` (or `workflow_dispatch` with `target_env` in `dev | uat | prod`):
  - Authenticate via WIF as `sa-tofu-apply` (enforced server-side by GCP WIF to `refs/heads/main`).
  - Run `terragrunt init` → `terragrunt plan -out=tfplan` → `terragrunt apply -auto-approve tfplan` with full GCS locking.
  - Enforce isolated concurrency groups `udp-gcp-dev-apply`, `udp-gcp-uat-apply`, `udp-gcp-prod-apply` with `cancel-in-progress: false`.
  - Gate `apply-uat` on `environment: uat` and `apply-prod` on `environment: prod`; ensure `workflow_dispatch` targeting `uat` or `prod` executes even when upstream jobs are skipped.
- `REQ-06`: **Standalone Graduation Portability** — All paths in workflows shall parameterize the project root via `env.PROJECT_DIR` (`"platform_unified_data_gcp"`) so graduating to a standalone repository requires only moving the two workflow files and setting `PROJECT_DIR: "."`.

---

## 4. Interface & Data Contract

### 4.1 Workflow Matrix

| Workflow File | Triggers | Top-Level / Job Permissions | Auth Principal | Concurrency & Gating |
| :--- | :--- | :--- | :--- | :--- |
| `.github/workflows/udp-gcp-pr-check.yml` | `pull_request` on `platform_unified_data_gcp/**`, `.github/workflows/udp-gcp-*.yml` | Root: `{}`; `static-checks`: `contents: read`; `plan`: `contents: read`, `id-token: write`, `pull-requests: write` | `sa-tofu-plan` via WIF | Matrix `[dev, uat, prod]` (`fail-fast: false`), `-lock=false`, idempotent PR comment upsert per env. |
| `.github/workflows/udp-gcp-apply.yml` | `push` (`main`) on `infra/platform/**`, `infra/envs/**`, `.github/workflows/udp-gcp-apply.yml`; `workflow_dispatch` (`target_env`) | Root: `{}`; each apply job: `contents: read`, `id-token: write` | `sa-tofu-apply` via WIF | Per-env `udp-gcp-<env>-apply` (`cancel-in-progress: false`); `dev` auto-apply; `uat` & `prod` gated by GitHub Environments. |

### 4.2 Consumed GitHub Actions Repository Variables

| Variable | Required | Provisioned By | Consumed By |
| :--- | :--- | :--- | :--- |
| `UDP_GCP_WIF_PROVIDER` | Yes | `infra/bootstrap/github_actions.tf` | Both workflows (WIF OIDC auth) |
| `UDP_GCP_PLAN_SA` | Yes | `infra/bootstrap/github_actions.tf` | `udp-gcp-pr-check.yml` |
| `UDP_GCP_APPLY_SA` | Yes | `infra/bootstrap/github_actions.tf` | `udp-gcp-apply.yml` |
| `UDP_GCP_STATE_BUCKET` | Yes | `infra/bootstrap/github_actions.tf` | `root.hcl` (`backend.tf`) |
| `UDP_GCP_STATE_KMS_KEY_ID` | Yes | `infra/bootstrap/github_actions.tf` | `root.hcl` (`encryption.tf`) |
| `UDP_GCP_PLATFORM_FOLDER_ID` | Yes | `infra/bootstrap/github_actions.tf` | `root.hcl` inputs |
| `UDP_GCP_BILLING_ACCOUNT_ID` | Yes | `infra/bootstrap/github_actions.tf` | `root.hcl` inputs |
| `UDP_GCP_BUDGET_ALERT_EMAIL` | Yes | `infra/bootstrap/github_actions.tf` | `root.hcl` inputs |
| `UDP_GCP_DEV_PROJECT_ID` | Yes | `infra/bootstrap/github_actions.tf` | `infra/envs/dev/terragrunt.hcl` |
| `UDP_GCP_UAT_PROJECT_ID` | Optional (default `udp-uat`) | Optional repo var override | `infra/envs/uat/terragrunt.hcl` |
| `UDP_GCP_PROD_PROJECT_ID` | Optional (default `udp-prod`) | Optional repo var override | `infra/envs/prod/terragrunt.hcl` |

---

## 5. Invariants, Edge Cases & Failure Modes

### Key Invariants
1. **True Read-Only PR Execution:** `udp-gcp-pr-check.yml` never authenticates as `sa-tofu-apply`, never acquires a state lock (`-lock=false`), and never mutates GCP or GCS state.
2. **Server-Side Branch Enforcement:** Even if a PR modifies workflow YAML to request `sa-tofu-apply`, GCP WIF rejects the token exchange (`403 PERMISSION_DENIED`) because `sa-tofu-apply` is bound strictly to `refs/heads/main`.
3. **Serialized State Mutations:** `cancel-in-progress: false` per environment plus GCS `.tflock` locking prevent concurrent applies from racing or tearing state.
4. **Zero Static Secrets:** No GCP JSON keys or long-lived tokens are stored in GitHub Secrets.
5. **Comment-Size Resilience:** PR plan comments truncate safely at 60,000 characters so large plans never fail the GitHub API `422` body-length limit.

### Failure Mode Matrix

| Failure Condition | Expected Error / Status | Notes |
| :--- | :--- | :--- |
| Any static check (`fmt`, `tflint`, `trivy`, tag-pin check, `tofu test`) fails on PR | `static-checks` fails; `plan` matrix skipped | Blocks bad or insecure config before authenticating to GCP. |
| PR from a non-`main` branch attempts to impersonate `sa-tofu-apply` | GCP STS `403 PERMISSION_DENIED` | Enforced server-side by GCP WIF IAM binding. |
| `terragrunt plan` fails in one environment (e.g., `prod`) | Plan comment still posted with **Failed** status; job exits `1`; other matrix envs still report (`fail-fast: false`) | Ensures full diagnostic visibility across all environments on the PR. |
| Two merges to `main` occur rapidly | Second `apply-dev` queues behind first (`cancel-in-progress: false`) | GCS `.tflock` serves as secondary lock. |
| `workflow_dispatch` targets `uat` or `prod` directly | Upstream `apply-dev` is skipped, targeted job still evaluates `true` and waits for GitHub Environment approval | Requires explicit `needs.*.result` + `workflow_dispatch` `if:` expression. |

---

## 6. Acceptance Criteria & Verification Matrix

| Case ID | Scenario | Input / Precondition | Expected Outcome |
| :--- | :--- | :--- | :--- |
| `TC-001` | PR Static & Hygiene Gate | Open PR touching `platform_unified_data_gcp/**` | `static-checks` verifies `tofu fmt`, `terragrunt hcl fmt`, zero `.tf` in `envs/`, zero `infra/modules/`, `infra/module-versions.yaml` semver tag schema, `terragrunt render` across `dev`/`uat`/`prod`, `validate`, `tflint`, `trivy`, `test_bootstrap_init.sh`, and mocked `tofu test` / `terragrunt test`. |
| `TC-002` | PR Read-Only Multi-Env Plan | Valid PR after `static-checks` passes | `plan` matrix runs for `dev`, `uat`, `prod` under `sa-tofu-plan` with `-lock=false` and upserts 3 distinct PR plan comments with zero GCP/state mutation. |
| `TC-003` | Branch Security Boundary (Negative) | Attempt WIF auth as `sa-tofu-apply` on a non-`main` branch | GCP STS rejects with `403 PERMISSION_DENIED`. |
| `TC-004` | Main-Branch Apply & Promotion Gates | Merge PR to `main` | `apply-dev` auto-applies `dev` idempotently under `sa-tofu-apply`; `apply-uat` and `apply-prod` pause at GitHub Environment approval gates. |
| `TC-005` | Manual Dispatch Targeting `uat` / `prod` | Trigger `workflow_dispatch` with `target_env = uat` | `apply-dev` is skipped; `apply-uat` runs (after `uat` approval) without being skipped by `needs`. |
| `TC-006` | Concurrent Merge Serialization | Two rapid pushes to `main` | Second `apply-dev` queues cleanly (`cancel-in-progress: false`); state remains consistent. |
