# Feature Spec: GitHub Actions GitOps CI/CD & Tag-Based Environment Promotion (`udp-gcp-*`)

- **Status:** Draft (Redesign — Pending Approval)
- **Module / Component:** `<repo-root>/.github/workflows/udp-gcp-pr-check.yml`, `<repo-root>/.github/workflows/udp-gcp-apply.yml`, `<repo-root>/.github/workflows/udp-gcp-promote.yml` (GitHub Actions + GCP WIF + OpenTofu + Terragrunt)
- **Archetype:** CI/CD & Trunk-Based GitOps Promotion Contract
- **Tier:** Full Spec
- **Owner:** Xavier Ruiz
- **Depends On:** `specs/01_gcp_bootstrap_and_wif.md`, `specs/03_platform_and_terragrunt_envs.md`

---

## 1. Goal & Context

### Problem Statement
Pointing `dev`, `uat`, and `prod` at the same mutable relative path (`../../platform//.`) couples all three environments to `main` HEAD: every merge to `infra/platform/` shifts the desired state of `prod`, and a routine config edit in `envs/prod/terragrunt.hcl` risks dragging in untested `dev` platform changes. At the same time, copying `.tf` files across environment directories violates DRY, while long-lived Git environment branches (`main` → `uat` → `prod`) introduce hotfix divergence, squash-merge conflicts, and cross-project bleed inside the `playground-cloud-engineering` monorepo.

This spec redesigns CI/CD around **Trunk-Based GitOps with Immutable Platform Release Tags**:
- `main` remains the **single trunk** and `sa-tofu-apply` remains locked server-side strictly to `refs/heads/main`.
- `infra/platform/` (including its atomic `module-versions.yaml`) is versioned via immutable annotated Git tags (`udp-gcp-vX.Y.Z`).
- `dev` tracks `../../platform//.` on `main` for fast iteration, while `uat` and `prod` pin an immutable tag in `infra/envs/<env>/release.yaml`.
- A dedicated **Promotion Workflow (`udp-gcp-promote.yml`)** cuts release tags and opens 1-line Promotion PRs into `main`.
- Both PR planning (`udp-gcp-pr-check.yml`) and CD deployment (`udp-gcp-apply.yml`) are **path-scoped**: they plan and deploy **only the environment directories actually affected by the diff**.

### Success Metrics
- Merging a feature PR touching `infra/platform/**` plans and deploys **`dev` only**; `uat` and `prod` remain completely unaffected until explicitly promoted.
- Promoting `dev → uat` cuts an immutable semver tag (`udp-gcp-vX.Y.Z`) on `main` and opens a 1-line Promotion PR updating `infra/envs/uat/release.yaml`; PR Check plans **`uat` only**, and merging deploys **`uat` only**.
- Promoting `uat → prod` opens a 1-line Promotion PR setting `infra/envs/prod/release.yaml` to the exact tag currently running in `uat`; PR Check plans **`prod` only**, and merging deploys **`prod` only**.
- Promotion PRs serve as the auditable approval gate (works natively on GitHub Free private repos without requiring GitHub Pro Environment reviewers, while remaining compatible with `CODEOWNERS` and GitHub Environments).
- Zero static GCP credentials exist in GitHub Secrets; all GCP access uses short-lived OIDC WIF tokens (`id-token: write`).
- Full verification coverage of `TC-001` through `TC-008`.

---

## 2. Visual Architecture & Pipeline Flow

### 2.1 Trunk-Based Architecture & Blast-Radius Isolation

```mermaid
flowchart TB
    subgraph Repo["GitHub Monorepo (Single Trunk: main)"]
        Platform["infra/platform/\nmain.tf + module-versions.yaml"]
        Tag1["Immutable Git Tag\nudp-gcp-v0.1.0"]
        Tag2["Immutable Git Tag\nudp-gcp-v0.2.0"]
        RootHCL["infra/envs/root.hcl\nbackend + KMS encryption + provider"]

        subgraph EnvDev["infra/envs/dev/"]
            DevTG["terragrunt.hcl\nsource: ../../platform//."]
        end

        subgraph EnvUat["infra/envs/uat/"]
            UatRel["release.yaml\nplatform_version: udp-gcp-v0.2.0"]
            UatTG["terragrunt.hcl\nsource: git::...//infra/platform?ref=v0.2.0"]
        end

        subgraph EnvProd["infra/envs/prod/"]
            ProdRel["release.yaml\nplatform_version: udp-gcp-v0.1.0"]
            ProdTG["terragrunt.hcl\nsource: git::...//infra/platform?ref=v0.1.0"]
        end

        Platform -. "tracks HEAD" .-> DevTG
        Platform --> Tag1
        Platform --> Tag2
        Tag2 --> UatTG
        Tag1 --> ProdTG
        UatRel --> UatTG
        ProdRel --> ProdTG
        RootHCL --> DevTG
        RootHCL --> UatTG
        RootHCL --> ProdTG
    end

    subgraph GCP["GCP Platform Folder + KMS-Encrypted GCS State"]
        DevGCP["Project: udp-dev-xxxx\nState: envs/dev/default.tfstate"]
        UatGCP["Project: udp-uat-xxxx\nState: envs/uat/default.tfstate"]
        ProdGCP["Project: udp-prod-xxxx\nState: envs/prod/default.tfstate"]
    end

    DevTG ==> DevGCP
    UatTG ==> UatGCP
    ProdTG ==> ProdGCP
```

### 2.2 Directory-Scoped CI/CD Routing (PR Check & Apply)

```mermaid
flowchart LR
    Diff["Git Diff\nPR or Push to main"] --> Detect["Job: detect-changes\nPath-Filter Matrix"]

    Detect -->|"infra/platform/** or\ninfra/envs/dev/**"| TargetDev["Target: dev"]
    Detect -->|"infra/envs/uat/**\n(and release != unreleased)"| TargetUat["Target: uat"]
    Detect -->|"infra/envs/prod/**\n(and release != unreleased)"| TargetProd["Target: prod"]
    Detect -->|"infra/envs/root.hcl"| TargetAll["Target: dev + all released envs"]
    Detect -->|"infra/bootstrap/** or\nscripts/** only"| TargetNone["Target: none (Static Checks Only)"]

    subgraph PR["udp-gcp-pr-check.yml (sa-tofu-plan, Read-Only WIF)"]
        Static["static-checks\nfmt, validate, tflint, trivy, unit tests"]
        PlanMatrix["Dynamic Matrix Plan\nAffected Envs Only (-lock=false)"]
        PRComment["Upsert Scoped PR Plan Comments"]
        Static --> PlanMatrix --> PRComment
    end

    subgraph CD["udp-gcp-apply.yml (sa-tofu-apply, main-Only WIF)"]
        ApplyDev["apply-dev\nconcurrency: udp-gcp-dev-apply"]
        ApplyUat["apply-uat\nconcurrency: udp-gcp-uat-apply"]
        ApplyProd["apply-prod\nconcurrency: udp-gcp-prod-apply"]
    end

    TargetDev --> PR
    TargetUat --> PR
    TargetProd --> PR
    TargetAll --> PR
    TargetNone --> Static

    TargetDev --> ApplyDev
    TargetUat --> ApplyUat
    TargetProd --> ApplyProd
```

### 2.3 End-to-End Promotion & Rollback Lifecycle

```mermaid
sequenceDiagram
    actor Eng as Engineer
    participant PR as GitHub PR (to main)
    participant CI as udp-gcp-pr-check.yml
    participant CD as udp-gcp-apply.yml
    participant Promo as udp-gcp-promote.yml
    participant GCP as GCP (WIF: plan / apply)

    Note over Eng,GCP: Phase 1 — Feature Development (dev only)
    Eng->>PR: Open feature PR editing infra/platform/**
    PR->>CI: detect-changes -> affected: [dev]
    CI->>GCP: WIF sa-tofu-plan -> plan dev only
    CI-->>PR: Post dev plan comment
    Eng->>PR: Review & Merge to main
    PR->>CD: detect-changes -> affected: [dev]
    CD->>GCP: WIF sa-tofu-apply -> apply dev only

    Note over Eng,GCP: Phase 2 — Promote dev -> uat
    Eng->>Promo: workflow_dispatch (dev-to-uat, bump=minor)
    Promo->>Promo: Cut annotated tag udp-gcp-v0.1.0 on main HEAD
    Promo->>PR: Open 1-line PR updating envs/uat/release.yaml
    PR->>CI: detect-changes -> affected: [uat]
    CI->>GCP: WIF sa-tofu-plan -> fetch tag v0.1.0, plan uat only
    CI-->>PR: Post uat plan comment + commit changelog
    Eng->>PR: Review uat plan & Merge to main
    PR->>CD: detect-changes -> affected: [uat]
    CD->>GCP: WIF sa-tofu-apply -> apply uat only (tag v0.1.0)

    Note over Eng,GCP: Phase 3 — Promote uat -> prod
    Eng->>Promo: workflow_dispatch (uat-to-prod)
    Promo->>Promo: Read uat/release.yaml (udp-gcp-v0.1.0)
    Promo->>PR: Open 1-line PR updating envs/prod/release.yaml
    PR->>CI: detect-changes -> affected: [prod]
    CI->>GCP: WIF sa-tofu-plan -> fetch tag v0.1.0, plan prod only
    CI-->>PR: Post prod plan comment + commit changelog
    Eng->>PR: Review prod plan & Merge to main
    PR->>CD: detect-changes -> affected: [prod]
    CD->>GCP: WIF sa-tofu-apply -> apply prod only (tag v0.1.0)

    Note over Eng,GCP: Rollback — Revert 1-line prod/release.yaml PR
    Eng->>PR: git revert prod Promotion PR
    PR->>CI: Plan prod rollback to previous tag
    Eng->>PR: Merge -> CD restores previous tag in prod only
```

---

## 3. Scope & Explicit Non-Goals

### In Scope
- **Spec 03 Alignment (Companion Platform/Terragrunt Updates Required for Tagging):**
  - Move `infra/module-versions.yaml` → `infra/platform/module-versions.yaml`, read directly inside `infra/platform/` via OpenTofu 1.8+ Early Variable Evaluation (`yamldecode(file("${path.module}/module-versions.yaml"))`) so upstream CFF / Project Factory tags travel atomically inside each `udp-gcp-vX.Y.Z` Git tag.
  - Add machine-promoted `infra/envs/uat/release.yaml` and `infra/envs/prod/release.yaml` (`platform_version: "unreleased"` on Day 0, then `"udp-gcp-vX.Y.Z"` once promoted).
  - Keep `infra/envs/dev/terragrunt.hcl` on `source = "../../platform//."`; update `infra/envs/uat/terragrunt.hcl` and `infra/envs/prod/terragrunt.hcl` to resolve `terraform.source` to the tagged repo URL `${include.root.locals.platform_git_source}?ref=${local.platform_version}` (falling back to `../../platform//.` only under `UDP_GCP_OFFLINE_TEST=true`).
- **`<repo-root>/.github/workflows/udp-gcp-pr-check.yml`:**
  - `detect-changes` job calculating exact affected environments (`dev`, `uat`, `prod`) and skipping any environment whose `release.yaml` is `"unreleased"`.
  - `static-checks` job running formatting, layout/tag-pinning/schema invariants (including `release.yaml` format validation), `terragrunt render`, `validate`, `tflint`, `trivy config`, `test_bootstrap_init.sh`, and mocked `tofu test` / `terragrunt test`.
  - Dynamic-matrix `plan` job authenticating via WIF (`sa-tofu-plan`), configuring Git HTTPS auth with `GITHUB_TOKEN` for private-repo tag fetching, checking remote state existence (`UDP_GCP_EPHEMERAL_PLAN_STATE` pre-first-apply), running `terragrunt plan -lock=false`, and upserting PR comments only for affected environments.
- **`<repo-root>/.github/workflows/udp-gcp-apply.yml`:**
  - `detect-changes` job mapping `push` to `main` diffs (or manual `workflow_dispatch` `target_env`) to exact target environment flags (`apply_dev`, `apply_uat`, `apply_prod`).
  - Independent, path-gated jobs (`apply-dev`, `apply-uat`, `apply-prod`) authenticating via WIF (`sa-tofu-apply`, locked strictly to `refs/heads/main`), each with its own serialized concurrency group (`udp-gcp-<env>-apply`, `cancel-in-progress: false`) and full GCS `.tflock` locking.
- **`<repo-root>/.github/workflows/udp-gcp-promote.yml`:**
  - Manual `workflow_dispatch` workflow supporting `dev-to-uat` (cuts next semver annotated tag `udp-gcp-vX.Y.Z` on `main` HEAD—or reuses an existing tag on HEAD—and opens Promotion PR updating `infra/envs/uat/release.yaml`) and `uat-to-prod` (reads exact tag from `infra/envs/uat/release.yaml` and opens Promotion PR updating `infra/envs/prod/release.yaml`), plus an optional `target_tag` escape hatch for cherry-picked patch releases (`udp-gcp-vX.Y.Z`).
  - Auto-generates a rich Promotion PR description containing: release metadata (`prev_tag -> target_tag`, commit SHA), commit changelog, changed OpenTofu/module files summary (`git diff --stat`), and a collapsible HCL/module-version diff (`git diff`) over `infra/platform/**` so reviewers inspect both exact Terraform code changes and the live `terragrunt plan` output.

### Non-Goals (Do Not Implement Yet — Future CI/CD Iterations)
- **Long-lived environment Git branches (`uat`, `prod`)** — explicitly rejected to prevent merge-conflict drift and cross-project monorepo bleed.
- **Copying `.tf` files across environment directories** — explicitly rejected to preserve DRY Terragrunt wrappers.
- **Scheduled drift detection cron workflow** (future Spec 05+ enhancement).
- **Automated FinOps / Infracost PR comments** (future enhancement).
- **Self-hosted runners, Atlantis, or HCP Terraform** (GitHub-hosted `ubuntu-latest` + WIF only).

---

## 4. Functional Requirements

- `REQ-01`: **Path-Scoped Triggers & Least-Privilege Permissions** — All three workflows shall live at `<repo-root>/.github/workflows/`, declare top-level `permissions: {}` with minimal job-level permissions, and scope triggers strictly to `platform_unified_data_gcp/**` and `.github/workflows/udp-gcp-*.yml`.
- `REQ-02`: **Pinned CI Tooling, OpenTofu Binding & Private Tag Fetch** — All workflows shall pin explicit versions of OpenTofu, Terragrunt, TFLint, and Trivy Action, export `TG_TF_PATH=tofu`, and configure ephemeral Git credentials (`url."https://x-access-token:${GITHUB_TOKEN}@github.com/".insteadOf`) whenever Terragrunt fetches tagged `infra/platform` refs from the private repository.
- `REQ-03`: **Deterministic Change Detection (`detect-changes`)** — Both `udp-gcp-pr-check.yml` and `udp-gcp-apply.yml` shall compute affected environments strictly from changed paths:
  - `infra/platform/**` → `dev` only
  - `infra/envs/dev/**` → `dev` only
  - `infra/envs/uat/**` → `uat` only (if `uat/release.yaml` != `"unreleased"`)
  - `infra/envs/prod/**` → `prod` only (if `prod/release.yaml` != `"unreleased"`)
  - `infra/envs/root.hcl` → `dev` + any of `uat`/`prod` whose `release.yaml` != `"unreleased"`
  - `infra/bootstrap/**`, `scripts/**`, `specs/**`, docs only → empty env list (static checks only; zero plans/applies)
- `REQ-04`: **PR Static Quality, Security & Release-Pin Gate (`static-checks`)** — `udp-gcp-pr-check.yml` shall fail fast before authenticating to GCP if any check fails: `tofu fmt`, `terragrunt hcl fmt`, zero `.tf` under `infra/envs/`, absence of `infra/modules/`, zero hardcoded `?ref=v...` literals in `infra/platform/*.tf`, `infra/platform/module-versions.yaml` semver validation, `infra/envs/{uat,prod}/release.yaml` schema validation (`^(unreleased|udp-gcp-v[0-9]+\.[0-9]+\.[0-9]+)$`), `terragrunt render`, `validate`, `tflint --recursive`, `trivy config` (`HIGH,CRITICAL`), `scripts/test_bootstrap_init.sh`, and mocked `tofu test` / `terragrunt test`.
- `REQ-05`: **PR Read-Only Scoped Plan (`plan`)** — Gated on `static-checks` and skipped cleanly when `detect-changes` produces an empty matrix, `udp-gcp-pr-check.yml` shall run a dynamic matrix over only affected released environments (`fail-fast: false`), authenticate via WIF as `sa-tofu-plan`, detect whether `envs/<env>/default.tfstate` exists in GCS (falling back to `UDP_GCP_EPHEMERAL_PLAN_STATE=true` prior to first apply so `sa-tofu-plan` never needs state write permission), run `terragrunt plan -lock=false -no-color`, and upsert a dedicated PR comment per planned environment (truncated safely at 60,000 chars).
- `REQ-06`: **Main-Branch Directory-Scoped Apply (`udp-gcp-apply.yml`)** — On push to `main` (or `workflow_dispatch` targeting a single released `target_env`), `udp-gcp-apply.yml` shall run ONLY the affected environment apply job(s) under `sa-tofu-apply` (server-side WIF restricted to `refs/heads/main`), with isolated concurrency groups `udp-gcp-dev-apply`, `udp-gcp-uat-apply`, `udp-gcp-prod-apply` (`cancel-in-progress: false`), executing `terragrunt init` → `terragrunt plan -out=tfplan` → `terragrunt apply -auto-approve tfplan` with GCS `.tflock` locking. When `root.hcl` triggers multiple environments, execution shall order `dev` → `uat` → `prod`.
- `REQ-07`: **Immutable Tag Promotion Workflow (`udp-gcp-promote.yml`)** — Triggered via `workflow_dispatch` on `main` only:
  - `dev-to-uat`: Computes next semantic tag `udp-gcp-vX.Y.Z` (based on `bump: patch | minor | major`, starting at `udp-gcp-v0.1.0`, or reusing an existing `udp-gcp-v*` tag already pointing at `main` HEAD; optionally accepts an explicit existing `target_tag` for out-of-order cherry-pick/patch releases), pushes an annotated tag to `origin` when newly cut, updates `infra/envs/uat/release.yaml`, and opens a Promotion PR (`promote/uat-<tag>` → `main`).
  - `uat-to-prod`: Reads `platform_version` from `infra/envs/uat/release.yaml`, fails closed if `"unreleased"`, tag missing, or identical to `prod/release.yaml`, updates `infra/envs/prod/release.yaml`, and opens a Promotion PR (`promote/prod-<tag>` → `main`).
  - **Thorough Terraform Change Summary in Promotion PR Body:** Every Promotion PR shall automatically include:
    1. Release metadata (`source_env -> target_env`, `prev_tag -> target_tag`, tagged commit SHA, and GitHub compare link).
    2. Commit changelog (`git log --oneline <prev_tag>..<target_tag> -- platform_unified_data_gcp/infra/platform`).
    3. Changed OpenTofu & module-version files summary (`git diff --stat <prev_tag>..<target_tag> -- platform_unified_data_gcp/infra/platform`).
    4. Collapsible Terraform / HCL code diff (`<details>` containing `git diff <prev_tag>..<target_tag> -- platform_unified_data_gcp/infra/platform`, safely truncated below GitHub's 65,536-char limit with link to full compare view) — pairing exact HCL changes with the live `terragrunt plan` comment from `udp-gcp-pr-check.yml`.
  - **PR Trigger Token Support:** Uses `secrets.UDP_GCP_PROMOTE_TOKEN` when configured (fine-grained PAT with `contents: write` & `pull-requests: write` on this repo so the Promotion PR automatically triggers `udp-gcp-pr-check.yml`), falling back cleanly to `github.token` with an explicit PR note instructing the reviewer to trigger/re-run PR checks if no PAT is configured.
- `REQ-08`: **Standalone Graduation Portability** — All workflow paths and tagged module URLs shall parameterize `PROJECT_DIR` (`"platform_unified_data_gcp"`) and `UDP_GCP_PLATFORM_REPO` so graduating to a standalone repository requires only moving the three workflows and updating those two values.
- `REQ-09`: **Commit & PR Hygiene Convention** — All commits and automated Promotion PRs shall follow Conventional Commit prefixes (`feat(<scope>):`, `fix(<scope>):`, `update(<scope>):`, `docs(<scope>):`, `chore(<scope>):`, `refactor(<scope>):`) so Promotion PR changelogs remain structured and auditable.

---

## 5. Interface & Data Contract

### 5.1 Workflow Matrix

| Workflow File | Triggers | Top-Level / Job Permissions | Auth Principal | Scope & Concurrency |
| :--- | :--- | :--- | :--- | :--- |
| `.github/workflows/udp-gcp-pr-check.yml` | `pull_request` on `platform_unified_data_gcp/**`, `.github/workflows/udp-gcp-*.yml`; optional `workflow_dispatch` | Root: `{}`; `detect-changes` & `static-checks`: `contents: read`; `plan`: `contents: read`, `id-token: write`, `pull-requests: write` | `sa-tofu-plan` via WIF | Dynamic matrix of **affected released envs only** (`fail-fast: false`), `-lock=false`, ephemeral state if pre-first-apply. |
| `.github/workflows/udp-gcp-apply.yml` | `push` (`main`) on `infra/platform/**`, `infra/envs/**`, `.github/workflows/udp-gcp-apply.yml`; `workflow_dispatch` (`target_env`) | Root: `{}`; `detect-changes`: `contents: read`; each apply job: `contents: read`, `id-token: write` | `sa-tofu-apply` via WIF (`main`-only) | Runs **affected released env jobs only**; per-env `udp-gcp-<env>-apply` (`cancel-in-progress: false`). |
| `.github/workflows/udp-gcp-promote.yml` | `workflow_dispatch` (`promotion: dev-to-uat \| uat-to-prod`, `bump: patch \| minor \| major`, optional `target_tag`) on `main` only | Root: `{}`; `promote`: `contents: write`, `pull-requests: write` | GitHub Token / optional `UDP_GCP_PROMOTE_TOKEN` (zero GCP access) | Concurrency `udp-gcp-promote` (`cancel-in-progress: false`); cuts/uses tag & opens 1-line Promotion PR with Terraform diff & changelog. |

### 5.2 Per-Environment Release Pin Contract (`infra/envs/{uat,prod}/release.yaml`)

```yaml
# Managed by .github/workflows/udp-gcp-promote.yml
# Allowed values: "unreleased" (Day-0 pre-promotion) or "udp-gcp-vX.Y.Z"
platform_version: "unreleased"
```

### 5.3 Change-Detection Routing Matrix

| Changed File Pattern | `dev` | `uat` (if released) | `prod` (if released) | Notes |
| :--- | :---: | :---: | :---: | :--- |
| `infra/platform/**` (incl. `module-versions.yaml`) | Run | Skip | Skip | `uat`/`prod` are pinned to immutable tags; zero blast radius outside `dev`. |
| `infra/envs/dev/**` | Run | Skip | Skip | Dev-only wrapper/input edits. |
| `infra/envs/uat/**` (incl. `uat/release.yaml`) | Skip | Run | Skip | UAT promotion PR or UAT-only config edit. |
| `infra/envs/prod/**` (incl. `prod/release.yaml`) | Skip | Skip | Run | Prod promotion PR, rollback PR, or Prod-only config edit. |
| `infra/envs/root.hcl` | Run | Run | Run | Shared root backend/provider/encryption changes apply in `dev` → `uat` → `prod` order. |
| `infra/bootstrap/**`, `scripts/**`, `specs/**`, `README.md` | Skip | Skip | Skip | `static-checks` still runs on PR; zero env plans or applies triggered. |

### 5.4 Consumed GitHub Actions Variables & Optional Secrets

| Kind | Name | Required | Consumed By | Purpose |
| :--- | :--- | :---: | :--- | :--- |
| Repo Var | `UDP_GCP_WIF_PROVIDER` | Yes | `pr-check`, `apply` | GCP Workload Identity Provider resource name |
| Repo Var | `UDP_GCP_PLAN_SA` | Yes | `pr-check` | Read-only plan Service Account |
| Repo Var | `UDP_GCP_APPLY_SA` | Yes | `apply` | `main`-only apply Service Account |
| Repo Var | `UDP_GCP_STATE_BUCKET` | Yes | `pr-check`, `apply` | Versioned GCS state bucket |
| Repo Var | `UDP_GCP_STATE_KMS_KEY_ID` | Yes | `pr-check`, `apply` | Cloud KMS key for OpenTofu state/plan encryption |
| Repo Var | `UDP_GCP_PLATFORM_FOLDER_ID` | Yes | `pr-check`, `apply` | Target GCP Platform Folder |
| Repo Var | `UDP_GCP_BILLING_ACCOUNT_ID` | Yes | `pr-check`, `apply` | GCP Billing Account ID |
| Repo Var | `UDP_GCP_BUDGET_ALERT_EMAIL` | Yes | `pr-check`, `apply` | Billing alert recipient email |
| Repo Var | `UDP_GCP_DEV_PROJECT_ID` | Yes | `pr-check`, `apply` | Base project ID prefix for `dev` |
| Repo Var | `UDP_GCP_UAT_PROJECT_ID` | Optional | `pr-check`, `apply` | Base project ID prefix for `uat` (default `udp-uat`) |
| Repo Var | `UDP_GCP_PROD_PROJECT_ID` | Optional | `pr-check`, `apply` | Base project ID prefix for `prod` (default `udp-prod`) |
| Repo Secret | `UDP_GCP_PROMOTE_TOKEN` | Optional | `promote` | Fine-grained PAT (`contents: write`, `pull-requests: write` on this repo) so bot-opened Promotion PRs automatically trigger `udp-gcp-pr-check.yml`. |

---

## 6. Invariants, Edge Cases & Failure Modes

### Key Invariants
1. **Strict Blast-Radius Isolation:** Merging changes to `infra/platform/**` can never mutate or even plan `uat` or `prod` until an explicit Promotion PR updates `infra/envs/<env>/release.yaml`.
2. **Atomic Platform + Upstream Versions:** Because `module-versions.yaml` lives inside `infra/platform/`, each `udp-gcp-vX.Y.Z` tag freezes both the platform HCL and its upstream `cloud-foundation-fabric` / `terraform-google-project-factory` versions together.
3. **Immutable Artifact Parity (`uat` → `prod`):** `udp-gcp-promote.yml` for `uat-to-prod` never cuts a new tag; it can only promote the exact `udp-gcp-vX.Y.Z` tag currently verified in `infra/envs/uat/release.yaml`.
4. **Server-Side Single-Trunk Security:** `sa-tofu-apply` remains bound strictly to `refs/heads/main` in GCP WIF; `udp-gcp-promote.yml` holds zero GCP permissions.
5. **True Read-Only PR Plans (Including Day-0 Pre-State):** `sa-tofu-plan` never writes `default.tfstate`; if remote state does not yet exist for an environment, `udp-gcp-pr-check.yml` sets `UDP_GCP_EPHEMERAL_PLAN_STATE=true` to plan cleanly against empty ephemeral state while still authenticating to real GCP.
6. **Instant Declarative Rollback:** Reverting a `prod` Promotion PR reverts 1 line in `infra/envs/prod/release.yaml`, automatically planning the rollback on PR and executing it for `prod` only on merge.

### Multi-Developer & Out-of-Order Promotion Strategy
When multiple engineers merge changes into `dev` (`main`) within the same platform module and Developer B is ready to promote while Developer A's earlier commit is not, three layered controls prevent release-train blocking:

1. **Feature Toggles (Primary Trunk-Based Control):** Incomplete or experimental infrastructure merges behind opt-in input variables defaulting to `false` (enabled only in `infra/envs/dev/terragrunt.hcl`, matching the existing `enable_cloud_nat` and `enable_flow_logs` pattern). Cutting a tag from `main` HEAD safely ships Developer B's change to `uat`/`prod` while Developer A's resources stay inert (`count = 0`).
2. **Domain-Split Stacks (Structural Scaling Control):** As new data-platform domains are added (BigQuery, GCS medallion, Dataproc, Composer), each domain lives in its own stack with an independent tag namespace (e.g., `udp-foundation-v*`, `udp-bigquery-v*`, `udp-composer-v*`) so teams promote independently without sharing a single release train.
3. **Out-of-Order Cherry-Pick Patch Tag (Escape Hatch):** If an unflagged, unready commit *did* land on `main` ahead of an urgent change:
   - *Preferred:* Revert Developer A's unready commit on `main`, cut & promote Developer B's tag cleanly, then re-land Developer A's PR.
   - *Patch Branch Alternative:* Branch off the tag currently running in `uat` (`release/udp-gcp-vX.Y.x`), `git cherry-pick <dev-b-sha>`, push an annotated patch tag (`udp-gcp-vX.Y.(Z+1)`), and pass `target_tag=udp-gcp-vX.Y.(Z+1)` to `udp-gcp-promote.yml` (`dev-to-uat`, then `uat-to-prod`).

### Failure Mode Matrix

| Failure Condition | Expected Error / Status | Notes |
| :--- | :--- | :--- |
| `udp-gcp-promote.yml` triggered from a non-`main` branch | Workflow fails immediately at branch guard (`github.ref != 'refs/heads/main'`) | Prevents cutting release tags from unreviewed feature branches. |
| `uat-to-prod` triggered while `uat/release.yaml` is `"unreleased"` or equals `prod/release.yaml` | Workflow exits non-zero with clear message; no PR opened | Enforces `dev` → `uat` → `prod` promotion order and prevents empty no-op PRs. |
| `dev-to-uat` triggered twice on the same `main` HEAD commit | Reuses existing `udp-gcp-vX.Y.Z` tag on HEAD; updates/reuses open promotion branch | Prevents duplicate semver tags pointing to identical commits. |
| `UDP_GCP_PROMOTE_TOKEN` secret is not configured | Promotion PR is still created via `GITHUB_TOKEN`, with a banner noting that GitHub's anti-recursion rule requires closing/reopening or pushing a commit (or adding `UDP_GCP_PROMOTE_TOKEN`) to auto-fire `udp-gcp-pr-check.yml` | Explicit, transparent handling of GitHub Actions' `GITHUB_TOKEN` PR-event limitation. |
| PR touches `infra/envs/uat/terragrunt.hcl` while `uat/release.yaml` is `"unreleased"` | `static-checks` runs; `plan (uat)` is skipped with clear log note | Prevents attempting to `git clone ?ref=unreleased` on Day 0. |
| Pinned tag in `release.yaml` does not exist in Git | `terragrunt init` fails during PR plan before merge | Blocks broken tag typos from ever reaching `main`. |
| PR from a non-`main` branch attempts to impersonate `sa-tofu-apply` | GCP STS `403 PERMISSION_DENIED` | Enforced server-side by GCP WIF IAM condition. |
| Two rapid merges to `main` target the same environment | Second apply queues behind first (`cancel-in-progress: false`) + GCS `.tflock` | Prevents state corruption. |

---

## 7. Acceptance Criteria & Verification Matrix

| Case ID | Scenario | Input / Precondition | Expected Outcome |
| :--- | :--- | :--- | :--- |
| `TC-001` | PR Static, Schema & Release-Pin Gate | Open PR touching `platform_unified_data_gcp/**` | `static-checks` validates formatting, zero `.tf` in `envs/`, zero `infra/modules/`, `infra/platform/module-versions.yaml` semver schema, `release.yaml` schema, `terragrunt render`, `validate`, `tflint`, `trivy`, `test_bootstrap_init.sh`, and mocked tests. |
| `TC-002` | Feature PR Scoped to `dev` Only | PR modifies `infra/platform/**` only | `detect-changes` outputs `["dev"]`; PR Check plans and comments **only for `dev`**; `uat` and `prod` are untouched. |
| `TC-003` | Main Merge Deploys `dev` Only | Merge feature PR (`infra/platform/**`) to `main` | `udp-gcp-apply.yml` runs `apply-dev` only under `sa-tofu-apply`; `apply-uat` and `apply-prod` are skipped. |
| `TC-004` | Promote `dev` → `uat` (Tag + Promotion PR with TF Diff) | Run `udp-gcp-promote.yml` with `promotion=dev-to-uat`, `bump=minor` on `main` | Creates annotated tag `udp-gcp-v0.1.0` on `main` HEAD and opens Promotion PR updating `infra/envs/uat/release.yaml`, with PR body containing commit changelog, changed Terraform file stats, and collapsible HCL diff. |
| `TC-005` | UAT Promotion PR Plans & Deploys `uat` Only | Open & merge `promote/uat-udp-gcp-v0.1.0` PR | PR Check detects `["uat"]`, fetches private tag `udp-gcp-v0.1.0`, plans & comments **only `uat`**; merging runs `apply-uat` only. |
| `TC-006` | Promote `uat` → `prod` (Immutable Parity) | Run `udp-gcp-promote.yml` with `promotion=uat-to-prod` on `main` | Reads `udp-gcp-v0.1.0` from `uat/release.yaml` (creates no new tag), opens Promotion PR updating `prod/release.yaml`; PR plans **only `prod`**; merge runs `apply-prod` only. |
| `TC-007` | Independent `prod` Config Edit (Zero Untested Code Bleed) | PR modifies `infra/envs/prod/terragrunt.hcl` (e.g., `monthly_budget_usd`) while newer untagged commits exist in `infra/platform/` | Plans & applies **only `prod`** using its pinned `udp-gcp-v0.1.0` tag — newer `main` `infra/platform/` changes are NOT pulled into `prod`. |
| `TC-008` | Negative Guards (Branch Security & Unreleased Gate) | (a) Trigger `promote` from non-`main` or `uat-to-prod` while `uat` is `unreleased`; (b) Attempt `sa-tofu-apply` on PR | (a) Promote workflow fails closed with zero tag/PR created; (b) GCP WIF rejects with `403 PERMISSION_DENIED`. |
