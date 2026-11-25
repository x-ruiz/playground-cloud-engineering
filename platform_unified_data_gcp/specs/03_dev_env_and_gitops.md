# Feature Spec: `envs/dev` Composition & GitHub Actions GitOps Workflows

- **Status:** Approved
- **Module / Component:** `platform_unified_data_gcp/infra/envs/dev` + `.github/workflows/udp-gcp-*.yml` (OpenTofu `>= 1.8`, GitHub Actions + WIF)
- **Archetype:** Infrastructure-as-Code & GitOps Contract (Environment & CI/CD)
- **Tier:** Mini-Spec
- **Owner:** Xavier Ruiz
- **Depends On:** `specs/01_gcp_bootstrap_and_wif.md`, `specs/02_gcp_core_modules.md`

---

## 1. Goal & Context

### Problem Statement
With one-time Org bootstrap (Spec 01) and reusable GCP modules (Spec 02) in place, `platform_unified_data_gcp` needs a continuous, keyless GitOps delivery loop for the `dev` environment. Pull requests must run full static quality/security checks and read-only `tofu plan` diffs under `sa-tofu-plan`, while merges to `main` must execute serialized, KMS-encrypted applies under `sa-tofu-apply`—while keeping the project self-contained enough to graduate from `playground-cloud-engineering` into its own standalone repository.

### Success Metrics
- `envs/dev` passes `tofu fmt`, `tofu validate`, `tflint`, `trivy config`, and offline `dev_composition.tftest.hcl`.
- Opening a PR posts a clean read-only `tofu plan` summary without mutating GCP or GCS state; merging to `main` applies `envs/dev` idempotently.
- Zero relative file references (`../`) escape `platform_unified_data_gcp/`.
- Full verification coverage of `TC-001` through `TC-006`.

---

## 2. Scope & Explicit Non-Goals

### In Scope
- Environment root `platform_unified_data_gcp/infra/envs/dev/` composing `project_factory`, `vpc_network`, and `budget_guardrail` with GCS backend (`prefix = "envs/dev"`), Cloud KMS state encryption (`gcp_kms` + `aes_gcm`), committed `.terraform.lock.hcl`, and `tests/dev_composition.tftest.hcl`.
- Path-scoped GitHub Actions workflows at `<repo-root>/.github/workflows/`:
  - `udp-gcp-pr-check.yml`: Static checks (`fmt`, `validate`, `tflint`, `trivy`, `tofu test`) + read-only WIF `plan` comment on PRs.
  - `udp-gcp-apply-dev.yml`: Serialized WIF `apply` on pushes to `main` (plus optional `workflow_dispatch`).
- Self-contained monorepo layout (`README.md`, `.tflint.hcl`, optional `.trivyignore`) ready for `git subtree split` graduation.

### Non-Goals (Do Not Implement)
- **No `envs/staging` or `envs/prod` yet:** Structure must allow adding them later without refactoring `modules/`.
- **No wrapper orchestrators or Kubernetes GitOps:** No Terragrunt, Atlantis, HCP Terraform, Argo CD, or Config Connector.
- **No static GCP credentials in GitHub Secrets:** Authentication uses WIF OIDC tokens (`id-token: write`) exclusively.

---

## 3. Functional Requirements

- `REQ-01`: **Repository Isolation & Path Filtering** — All project files under `platform_unified_data_gcp/` shall contain zero relative paths escaping that directory. Both GitHub Actions workflows shall scope triggers strictly to `platform_unified_data_gcp/**` (and `.github/workflows/udp-gcp-*.yml`).
- `REQ-02`: **Environment Composition (`infra/envs/dev`)** — Compose `project_factory`, `vpc_network`, and `budget_guardrail`, wiring `project_id` and `project_number` outputs across modules, defaulting `region = "us-central1"`, `enable_cloud_nat = false`, `enable_flow_logs = false`, and `deletion_policy = "PREVENT"`.
- `REQ-03`: **Encrypted Remote State Backend** — Configure `backend "gcs"` (`prefix = "envs/dev"`) and OpenTofu native `encryption` (`gcp_kms` + `aes_gcm`) with zero plaintext fallback so state reads/writes fail closed if KMS access is missing.
- `REQ-04`: **PR Quality & Read-Only Plan Workflow** — `udp-gcp-pr-check.yml` shall run Job 1 (`static-checks`: `tofu fmt -check -recursive`, `tofu validate`, `tflint`, `trivy config` failing on HIGH/CRITICAL, `tofu test`) and Job 2 (`plan-dev`, gated on Job 1): authenticate via WIF as `sa-tofu-plan`, run `tofu plan -lock=false -no-color` against `envs/dev`, and upsert a concise plan comment on the PR.
- `REQ-05`: **Serialized Main Apply Workflow** — `udp-gcp-apply-dev.yml` shall trigger on pushes to `main` touching `platform_unified_data_gcp/infra/**` (and `workflow_dispatch`), enforce `concurrency: { group: "udp-gcp-dev-apply", cancel-in-progress: false }`, authenticate via WIF as `sa-tofu-apply`, and run `tofu init` → `tofu plan -out=tfplan` → `tofu apply -auto-approve tfplan` with GCS locking enabled.
- `REQ-06`: **Offline Composition Test** — `infra/envs/dev/tests/dev_composition.tftest.hcl` shall validate module wiring, default `$0/mo` NAT setting, and label propagation offline via `mock_provider`.

---

## 4. Interface & Data Contract

### 4.1 GitHub Actions Workflow Contract

| Workflow File | Triggers | Permissions | Auth Principal | Steps & Concurrency |
| :--- | :--- | :--- | :--- | :--- |
| `.github/workflows/udp-gcp-pr-check.yml` | `pull_request` on `platform_unified_data_gcp/**` and `.github/workflows/udp-gcp-*.yml` | `contents: read`, `id-token: write`, `pull-requests: write` | `sa-tofu-plan` via WIF | Job 1 (`static-checks`): `fmt`, `validate`, `tflint`, `trivy`, `tofu test`. Job 2 (`plan-dev`): WIF auth, `tofu init`, `tofu plan -lock=false -no-color`, upsert PR comment. |
| `.github/workflows/udp-gcp-apply-dev.yml` | `push` to `main` on `platform_unified_data_gcp/infra/**` (plus `workflow_dispatch`) | `contents: read`, `id-token: write` | `sa-tofu-apply` via WIF | `concurrency: { group: "udp-gcp-dev-apply", cancel-in-progress: false }`. WIF auth, `tofu init`, `tofu plan -out=tfplan`, `tofu apply -auto-approve tfplan`. |

### 4.2 Consumed GitHub Actions Repository Variables
Workflows consume the 9 `UDP_GCP_*` variables provisioned by Spec 01 (`WIF_PROVIDER`, `PLAN_SA`, `APPLY_SA`, `STATE_BUCKET`, `STATE_KMS_KEY_ID`, `PLATFORM_FOLDER_ID`, `BILLING_ACCOUNT_ID`, `DEV_PROJECT_ID`, `BUDGET_ALERT_EMAIL`).

### 4.3 External Input Payload Example (`envs/dev/terraform.tfvars.json`)

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

---

## 5. Invariants, Edge Cases & Failure Modes

### Key Invariants
1. **True Read-Only PR Execution:** `udp-gcp-pr-check.yml` never authenticates as `sa-tofu-apply`, never acquires a state lock (`-lock=false`), and never mutates GCP or GCS state.
2. **Serialized State Mutations:** `cancel-in-progress: false` in `udp-gcp-apply-dev.yml` plus GCS `.tflock` locking guarantee two rapid merges to `main` never race or tear state.
3. **Fail-Closed Encrypted State:** `envs/dev` requires valid KMS key access for every state operation; plaintext state is never accepted.
4. **Standalone Graduation:** Zero relative paths escape `platform_unified_data_gcp/`, and `.terraform.lock.hcl` is committed.

### Failure Mode Matrix

| Failure Condition | Expected Error / Status | Notes |
| :--- | :--- | :--- |
| Static check (`fmt`, `tflint`, `trivy`, `tofu test`) fails on PR | Job 1 fails; Job 2 (`plan-dev`) skipped | Prevents broken or insecure HCL from running against GCP. |
| Two merges to `main` occur back-to-back | Second run queues behind first (`cancel-in-progress: false`) | GCS `.tflock` serves as secondary lock. |
| Wrong or inaccessible `UDP_GCP_STATE_KMS_KEY_ID` | OpenTofu `Failed to decrypt state` | Fail-closed before plan/apply proceeds. |
| Accidental `tofu destroy` on default `envs/dev` | `deletion_policy = "PREVENT"` error | Requires explicit variable change to `"DELETE"` for intentional teardown. |

---

## 6. Acceptance Criteria & Verification Matrix

| Case ID | Scenario | Input / Precondition | Expected Outcome |
| :--- | :--- | :--- | :--- |
| `TC-001` | `envs/dev` static checks & security scan | `infra/envs/dev/` tree | `tofu fmt -check`, `tofu validate`, `tflint`, and `trivy config` exit `0`. |
| `TC-002` | `envs/dev` mocked composition test | `tofu test` on `infra/envs/dev/` | Composes `project_factory`, `vpc_network`, and `budget_guardrail`; wires `project_id`/`project_number`; `enable_cloud_nat == false`. |
| `TC-003` | PR workflow read-only enforcement | Open PR modifying `platform_unified_data_gcp/infra/envs/dev/` | `static-checks` passes; `plan-dev` authenticates as `sa-tofu-plan`, runs `tofu plan -lock=false`, and posts/updates PR comment with zero state/GCP mutation. |
| `TC-004` | Main branch apply & idempotency | Merge PR to `main` | `udp-gcp-apply-dev.yml` authenticates as `sa-tofu-apply`, provisions `dev` project + VPC + budget; re-run yields `No changes`. |
| `TC-005` | Concurrent merge serialization | Two rapid pushes to `main` | Workflow concurrency queues the second run without canceling the first; state remains consistent. |
| `TC-006` | Monorepo graduation readiness | Inspect all paths inside `platform_unified_data_gcp/` | Zero relative paths escaping `platform_unified_data_gcp/`; `.terraform.lock.hcl` committed; `README.md` documents standalone extraction steps. |
