# Spec 02: GitHub Actions GitOps CI/CD & Tag-Based Promotion

| Field | Value |
| :--- | :--- |
| **Status** | `Approved` |
| **Owner** | Xavier Ruiz |
| **Component** | `.github/workflows/udp-gcp-{pr-check,apply,promote}.yml` |
| **Stack** | GitHub Actions · GCP WIF · OpenTofu · Terragrunt · TFLint · Trivy |
| **Archetype / Tier** | CI/CD & Trunk-Based GitOps Promotion · Full Spec (`9 REQs`, `8 TCs`) |
| **Depends On** | [`x-ruiz/platform_gcp_org_bootstrap`](https://github.com/x-ruiz/platform_gcp_org_bootstrap), [Spec 01](./01_platform_module_setup.md) |

---

## 1. Overview & Design

### TL;DR
Pointing `dev`, `uat`, and `prod` at the same mutable relative path (`../../platform//.`) couples every environment to `main` HEAD, so routine config edits in `prod` risk pulling in untested `dev` platform changes. This spec establishes **Trunk-Based GitOps with Immutable Platform Release Tags** across three path-scoped workflows (`udp-gcp-pr-check.yml`, `udp-gcp-apply.yml`, `udp-gcp-promote.yml`): `dev` tracks `main` HEAD for fast iteration while `uat` and `prod` pin immutable `udp-gcp-vX.Y.Z` tags promoted via 1-line PRs with zero static GCP credentials.

### Architecture

#### Trunk-Based Blast-Radius Isolation

```mermaid
%%{init: {"theme": "base", "themeCSS": "svg { background-color: #09090B !important; border-radius: 8px; }", "themeVariables": {"darkMode": true, "background": "#09090B", "mainBkg": "#18181B", "textColor": "#F4F4F5", "primaryColor": "#18181B", "primaryTextColor": "#F4F4F5", "primaryBorderColor": "#7C3AED", "lineColor": "#A855F7", "secondaryColor": "#16141F", "tertiaryColor": "#0F0F14", "edgeLabelBackground": "#18181B", "clusterBkg": "#0F0F14", "clusterBorder": "#52525B", "titleColor": "#D8B4FE", "fontFamily": "Inter, ui-sans-serif, system-ui, -apple-system, sans-serif", "fontSize": "13px"}, "flowchart": {"curve": "basis", "nodeSpacing": 42, "rankSpacing": 56, "padding": 14}}}%%
flowchart TB
    subgraph Repo["1. GitHub Monorepo (Single Trunk: main)"]
        Platform["infra/platform/\nmain.tf + module-versions.yaml\nAtomic Platform Definition"]
        Tag1(["Immutable Git Tag\nudp-gcp-v0.1.0"])
        Tag2(["Immutable Git Tag\nudp-gcp-v0.2.0"])
        RootHCL["infra/envs/root.hcl\nGCS Backend · KMS Encryption\nShared Provider Config"]

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

        Platform -.->|"tracks main HEAD"| DevTG
        Platform -->|"annotated release tag"| Tag1
        Platform -->|"annotated release tag"| Tag2
        Tag2 -->|"immutable ref"| UatTG
        Tag1 -->|"immutable ref"| ProdTG
        UatRel -->|"pins version"| UatTG
        ProdRel -->|"pins version"| ProdTG
        RootHCL -.->|"inherits backend/KMS"| DevTG
        RootHCL -.->|"inherits backend/KMS"| UatTG
        RootHCL -.->|"inherits backend/KMS"| ProdTG
    end

    subgraph GCP["2. GCP Platform Folder + KMS-Encrypted GCS State"]
        DevGCP[("Project: udp-dev-xxxx\nState: envs/dev/default.tfstate")]
        UatGCP[("Project: udp-uat-xxxx\nState: envs/uat/default.tfstate")]
        ProdGCP[("Project: udp-prod-xxxx\nState: envs/prod/default.tfstate")]
    end

    DevTG ==>|"apply-dev (main WIF)"| DevGCP
    UatTG ==>|"apply-uat (main WIF)"| UatGCP
    ProdTG ==>|"apply-prod (main WIF)"| ProdGCP

    classDef core fill:#2E1065,stroke:#A855F7,stroke-width:2px,color:#F5F3FF
    classDef service fill:#18181B,stroke:#7C3AED,stroke-width:1.5px,color:#F4F4F5
    classDef store fill:#09090B,stroke:#C084FC,stroke-width:1.5px,color:#EDE9FE
    classDef async fill:#1E1B2E,stroke:#6B7280,stroke-width:1.25px,stroke-dasharray:4 3,color:#D4D4D8
    classDef guard fill:#3B0764,stroke:#E879F9,stroke-width:2px,stroke-dasharray:5 3,color:#FAF5FF

    class Platform core
    class Tag1,Tag2,UatRel,ProdRel guard
    class DevTG,UatTG,ProdTG service
    class RootHCL async
    class DevGCP,UatGCP,ProdGCP store

    style Repo fill:#0F0F14,stroke:#52525B,stroke-width:1.5px,color:#D8B4FE
    style EnvDev fill:#16141F,stroke:#6D28D9,stroke-width:1.25px,stroke-dasharray:4 3,color:#C4B5FD
    style EnvUat fill:#16141F,stroke:#6D28D9,stroke-width:1.25px,stroke-dasharray:4 3,color:#C4B5FD
    style EnvProd fill:#16141F,stroke:#6D28D9,stroke-width:1.25px,stroke-dasharray:4 3,color:#C4B5FD
    style GCP fill:#0F0F14,stroke:#52525B,stroke-width:1.5px,color:#D8B4FE
```

#### Directory-Scoped CI/CD Routing (PR Check & Apply)

```mermaid
%%{init: {"theme": "base", "themeCSS": "svg { background-color: #09090B !important; border-radius: 8px; }", "themeVariables": {"darkMode": true, "background": "#09090B", "mainBkg": "#18181B", "textColor": "#F4F4F5", "primaryColor": "#18181B", "primaryTextColor": "#F4F4F5", "primaryBorderColor": "#7C3AED", "lineColor": "#A855F7", "secondaryColor": "#16141F", "tertiaryColor": "#0F0F14", "edgeLabelBackground": "#18181B", "clusterBkg": "#0F0F14", "clusterBorder": "#52525B", "titleColor": "#D8B4FE", "fontFamily": "Inter, ui-sans-serif, system-ui, -apple-system, sans-serif", "fontSize": "13px"}, "flowchart": {"curve": "basis", "nodeSpacing": 42, "rankSpacing": 56, "padding": 14}}}%%
flowchart LR
    subgraph Routing["1. Deterministic Path-Filter Routing"]
        Diff(["Git Diff\nPR or Push to main"])
        Detect["Job: detect-changes\nPath-Filter Matrix\nChecks release.yaml != unreleased"]
        TargetDev["Target: dev"]
        TargetUat["Target: uat"]
        TargetProd["Target: prod"]
        TargetAll["Target: dev + released envs"]
        TargetNone["Target: none\nStatic Checks Only"]

        Diff ==>|"changed files"| Detect
        Detect -->|"infra/platform/** or\ninfra/envs/dev/**"| TargetDev
        Detect -->|"infra/envs/uat/**\n(released only)"| TargetUat
        Detect -->|"infra/envs/prod/**\n(released only)"| TargetProd
        Detect -->|"infra/envs/root.hcl"| TargetAll
        Detect -.->|"scripts/**, specs/**,\ndocs only"| TargetNone
    end

    subgraph PR["2. udp-gcp-pr-check.yml (sa-tofu-plan, Read-Only WIF)"]
        Static["static-checks\nfmt · validate · tflint\ntrivy · schema & unit tests"]
        PlanMatrix["Dynamic Matrix Plan\nAffected Envs Only · -lock=false\nEphemeral State on Day 0"]
        PRComment["Upsert Scoped PR Comments\nDedicated Per-Env Plan"]

        Static ==>|"gate passed"| PlanMatrix
        PlanMatrix -->|"upsert comment"| PRComment
    end

    subgraph CD["3. udp-gcp-apply.yml (sa-tofu-apply, main-Only WIF)"]
        ApplyDev["apply-dev\nconcurrency: udp-gcp-dev-apply\nGCS .tflock"]
        ApplyUat["apply-uat\nconcurrency: udp-gcp-uat-apply\nGCS .tflock"]
        ApplyProd["apply-prod\nconcurrency: udp-gcp-prod-apply\nGCS .tflock"]
    end

    TargetDev -->|"PR plan"| PR
    TargetUat -->|"PR plan"| PR
    TargetProd -->|"PR plan"| PR
    TargetAll -->|"PR plan"| PR
    TargetNone -.->|"skip GCP plan"| Static

    TargetDev ==>|"push main"| ApplyDev
    TargetUat ==>|"push main"| ApplyUat
    TargetProd ==>|"push main"| ApplyProd

    classDef core fill:#2E1065,stroke:#A855F7,stroke-width:2px,color:#F5F3FF
    classDef service fill:#18181B,stroke:#7C3AED,stroke-width:1.5px,color:#F4F4F5
    classDef external fill:#27272A,stroke:#71717A,stroke-width:1.5px,color:#E4E4E7
    classDef async fill:#1E1B2E,stroke:#6B7280,stroke-width:1.25px,stroke-dasharray:4 3,color:#D4D4D8
    classDef guard fill:#3B0764,stroke:#E879F9,stroke-width:2px,stroke-dasharray:5 3,color:#FAF5FF

    class Diff external
    class Detect core
    class Static guard
    class TargetDev,TargetUat,TargetProd,TargetAll,PlanMatrix,PRComment,ApplyDev,ApplyUat,ApplyProd service
    class TargetNone async

    style Routing fill:#16141F,stroke:#6D28D9,stroke-width:1.25px,stroke-dasharray:4 3,color:#C4B5FD
    style PR fill:#0F0F14,stroke:#52525B,stroke-width:1.5px,color:#D8B4FE
    style CD fill:#0F0F14,stroke:#52525B,stroke-width:1.5px,color:#D8B4FE
```

#### End-to-End Promotion & Rollback Lifecycle

```mermaid
%%{init: {"theme": "base", "themeCSS": "svg { background-color: #09090B !important; border-radius: 8px; }", "themeVariables": {"darkMode": true, "background": "#09090B", "mainBkg": "#18181B", "textColor": "#F4F4F5", "primaryColor": "#18181B", "primaryTextColor": "#F4F4F5", "primaryBorderColor": "#7C3AED", "lineColor": "#A855F7", "actorBkg": "#18181B", "actorBorder": "#7C3AED", "actorTextColor": "#F4F4F5", "actorLineColor": "#52525B", "signalColor": "#A855F7", "signalTextColor": "#E4E4E7", "labelBoxBkgColor": "#2E1065", "labelBoxBorderColor": "#A855F7", "labelTextColor": "#F5F3FF", "loopTextColor": "#D8B4FE", "noteBkgColor": "#1E1B2E", "noteBorderColor": "#6D28D9", "noteTextColor": "#EDE9FE", "activationBkgColor": "#4C1D95", "activationBorderColor": "#C084FC", "sequenceNumberColor": "#FAF5FF", "fontFamily": "Inter, ui-sans-serif, system-ui, -apple-system, sans-serif", "fontSize": "13px"}}}%%
sequenceDiagram
    autonumber
    actor Eng as Engineer
    participant PR as GitHub PR (to main)
    participant CI as udp-gcp-pr-check.yml
    participant CD as udp-gcp-apply.yml
    participant Promo as udp-gcp-promote.yml
    participant GCP as GCP (WIF: plan / apply)

    Note over Eng,GCP: Phase 1 — Feature Development (dev only)
    Eng->>PR: Open feature PR editing infra/platform/**
    PR->>+CI: detect-changes -> affected: [dev]
    CI->>GCP: WIF sa-tofu-plan -> plan dev only
    CI-->>-PR: Post dev plan comment
    Eng->>PR: Review & Merge to main
    PR->>+CD: detect-changes -> affected: [dev]
    CD->>GCP: WIF sa-tofu-apply -> apply dev only
    deactivate CD

    Note over Eng,GCP: Phase 2 — Promote dev -> uat
    Eng->>+Promo: workflow_dispatch (dev-to-uat, bump=minor)
    Promo->>Promo: Cut annotated tag udp-gcp-v0.1.0 on main HEAD
    Promo->>-PR: Open 1-line PR updating envs/uat/release.yaml
    PR->>+CI: detect-changes -> affected: [uat]
    CI->>GCP: WIF sa-tofu-plan -> fetch tag v0.1.0, plan uat only
    CI-->>-PR: Post uat plan comment + commit changelog
    Eng->>PR: Review uat plan & Merge to main
    PR->>+CD: detect-changes -> affected: [uat]
    CD->>GCP: WIF sa-tofu-apply -> apply uat only (tag v0.1.0)
    deactivate CD

    Note over Eng,GCP: Phase 3 — Promote uat -> prod
    Eng->>+Promo: workflow_dispatch (uat-to-prod)
    Promo->>Promo: Read uat/release.yaml (udp-gcp-v0.1.0)
    Promo->>-PR: Open 1-line PR updating envs/prod/release.yaml
    PR->>+CI: detect-changes -> affected: [prod]
    CI->>GCP: WIF sa-tofu-plan -> fetch tag v0.1.0, plan prod only
    CI-->>-PR: Post prod plan comment + commit changelog
    Eng->>PR: Review prod plan & Merge to main
    PR->>+CD: detect-changes -> affected: [prod]
    CD->>GCP: WIF sa-tofu-apply -> apply prod only (tag v0.1.0)
    deactivate CD

    Note over Eng,GCP: Rollback — Revert 1-line prod/release.yaml PR
    Eng->>PR: git revert prod Promotion PR
    PR->>CI: Plan prod rollback to previous tag
    Eng->>PR: Merge -> CD restores previous tag in prod only
```

### Key Design Decisions
- **Single trunk over environment branches:** Keeps `main` as the sole trunk with `sa-tofu-apply` locked server-side to `refs/heads/main`, avoiding hotfix divergence, squash-merge conflicts, and monorepo cross-project bleed.
- **Immutable annotated platform tags:** Moving `module-versions.yaml` inside `infra/platform/` ensures every `udp-gcp-vX.Y.Z` tag freezes both platform HCL and upstream CFF / Project Factory versions atomically.
- **Promotion PRs as the approval gate:** Opening 1-line PRs against `infra/envs/<env>/release.yaml` provides an auditable review gate natively on GitHub Free private repos while staying compatible with `CODEOWNERS` and GitHub Environments.
- **Keyless OIDC authentication:** Zero static GCP credentials live in GitHub Secrets; all GCP access uses short-lived OIDC WIF tokens (`id-token: write`).

### Done Looks Like
- Merging a feature PR touching `infra/platform/**` plans and deploys **`dev` only**, leaving `uat` and `prod` completely unaffected until promoted.
- Promoting `dev -> uat` cuts an immutable `udp-gcp-vX.Y.Z` tag on `main` and opens a 1-line Promotion PR that plans and deploys **`uat` only**.
- Promoting `uat -> prod` opens a 1-line Promotion PR pinning `prod` to the exact `uat` tag, planning and deploying **`prod` only**.
- Zero static GCP credentials exist in GitHub Secrets, and acceptance cases `TC-001` through `TC-008` pass cleanly.

---

## 2. Scope

### In Scope
- Align Spec 01 platform/Terragrunt layout for tagging by moving `module-versions.yaml` inside `infra/platform/`, adding `release.yaml` pins for `uat`/`prod`, and switching `uat`/`prod` Terragrunt sources to tagged Git refs with an offline-test fallback.
- Implement `<repo-root>/.github/workflows/udp-gcp-pr-check.yml` with path-scoped change detection, fail-fast static/security/unit-test gates, and a read-only WIF dynamic-matrix plan job that upserts per-environment PR comments.
- Implement `<repo-root>/.github/workflows/udp-gcp-apply.yml` with path-scoped change detection and independent, serialized `main`-only WIF apply jobs (`apply-dev`, `apply-uat`, `apply-prod`) using full GCS `.tflock` locking.
- Implement `<repo-root>/.github/workflows/udp-gcp-promote.yml` supporting `dev-to-uat` tag cutting and `uat-to-prod` tag parity promotion via rich 1-line Promotion PRs with changelogs, diff stats, and collapsible HCL diffs.

### Out of Scope (Non-Goals)
- **Long-lived environment Git branches (`uat`, `prod`):** Explicitly rejected to prevent merge-conflict drift and cross-project monorepo bleed.
- **Duplicating `.tf` files across environment directories:** Explicitly rejected to preserve DRY Terragrunt wrappers.
- **Scheduled drift detection cron workflow:** Deferred to a future Spec 03+ iteration.
- **Automated FinOps / Infracost PR comments:** Deferred to a future enhancement.
- **Self-hosted runners, Atlantis, or HCP Terraform:** Uses GitHub-hosted `ubuntu-latest` runners with GCP WIF only.

---

## 3. Functional Requirements

Exact workflow triggers, permissions, routing paths, validation regexes, and repository variables live once in **Section 4**.

### Triggers, Tooling & Change Detection

| ID | What | Why | How |
| :--- | :--- | :--- | :--- |
| `REQ-01` | Path-scoped triggers & least privilege | Prevents cross-project monorepo triggers and limits token blast radius | Workflows live in `.github/workflows/`, declare root `permissions: {}` with minimal job permissions (§4.1–§4.2), and trigger only on `platform_unified_data_gcp/**` and `.github/workflows/udp-gcp-*.yml` |
| `REQ-02` | Pinned CI tools & scoped private tag fetch | Guarantees reproducible runs without breaking anonymous public module clones | Pins OpenTofu, Terragrunt, TFLint, and Trivy Action; sets `TG_TF_PATH=tofu`; scopes Git HTTPS `insteadOf` credentials strictly to `${GITHUB_REPOSITORY}` (§4.3) |
| `REQ-03` | Deterministic change detection (`detect-changes`) | Isolates plan and apply blast radius strictly to changed environments | Both `pr-check` and `apply` map diff paths to affected environments (§4.4), skipping `uat`/`prod` while their `release.yaml` is `"unreleased"` |

### PR Validation, Planning & Main-Branch Apply

| ID | What | Why | How |
| :--- | :--- | :--- | :--- |
| `REQ-04` | Fail-fast static, security & pin gate (`static-checks`) | Catches formatting, schema, security, and layout violations before touching GCP | `udp-gcp-pr-check.yml` executes all formatting, layout, schema, lint, Trivy, and mocked unit-test gates (§4.5) before authenticating to GCP |
| `REQ-05` | Read-only scoped PR plan (`plan`) | Shows exact per-environment impact without ever granting state write access on PRs | Dynamic matrix (`fail-fast: false`) over affected released envs using WIF `sa-tofu-plan`, Day-0 `UDP_GCP_EPHEMERAL_PLAN_STATE=true` fallback, `terragrunt plan -lock=false -no-color`, and 60,000-char truncated upsert PR comments |
| `REQ-06` | Main-branch scoped apply (`udp-gcp-apply.yml`) | Enforces serialized, locked, single-trunk deployments strictly for affected environments | On `push` to `main` or `workflow_dispatch` (`target_env`), runs only affected jobs via `sa-tofu-apply` (`refs/heads/main` WIF), per-env concurrency groups (`cancel-in-progress: false`), GCS `.tflock` (`init` → `plan -out=tfplan` → `apply -auto-approve tfplan`), ordered `dev` → `uat` → `prod` on `root.hcl` changes |

### Tag Promotion, Portability & Hygiene

| ID | What | Why | How |
| :--- | :--- | :--- | :--- |
| `REQ-07` | Immutable tag promotion (`udp-gcp-promote.yml`) | Delivers auditable `dev -> uat -> prod` promotion with exact code-and-plan visibility | `workflow_dispatch` on `main` only: `dev-to-uat` cuts/reuses `udp-gcp-vX.Y.Z` (starting at `udp-gcp-v0.1.0`) and opens `promote/uat-<tag>`; `uat-to-prod` copies exact `uat` tag into `promote/prod-<tag>` (fail-closed); populates rich PR diff body (§4.6); supports `UDP_GCP_PROMOTE_TOKEN` with `github.token` fallback |
| `REQ-08` | Standalone graduation portability | Allows extracting the platform out of the monorepo with minimal edits | Parameterizes `PROJECT_DIR` (`"platform_unified_data_gcp"`) and `UDP_GCP_PLATFORM_REPO` across workflow paths and tagged module URLs |
| `REQ-09` | Conventional Commit & PR hygiene | Keeps auto-generated Promotion PR changelogs structured and auditable | Enforces Conventional Commit prefixes (`feat`, `fix`, `update`, `docs`, `chore`, `refactor` with `(<scope>):`) across commits and Promotion PRs |

---

## 4. Contract & Blueprint

### 4.1 Workflow Inventory & Triggers

| Workflow | Triggers | Auth Principal | Concurrency & Scope |
| :--- | :--- | :--- | :--- |
| `.github/workflows/udp-gcp-pr-check.yml` | `pull_request` on `platform_unified_data_gcp/**`, `.github/workflows/udp-gcp-*.yml`; optional `workflow_dispatch` | `sa-tofu-plan` via WIF | Dynamic matrix of affected released envs (`fail-fast: false`), `-lock=false`, ephemeral state if pre-first-apply |
| `.github/workflows/udp-gcp-apply.yml` | `push` (`main`) on `infra/platform/**`, `infra/envs/**`, `.github/workflows/udp-gcp-apply.yml`; `workflow_dispatch` | `sa-tofu-apply` via WIF (`main`-only) | Runs affected released env jobs only; per-env `udp-gcp-<env>-apply` (`cancel-in-progress: false`) |
| `.github/workflows/udp-gcp-promote.yml` | `workflow_dispatch` on `main` only | `GITHUB_TOKEN` or optional `UDP_GCP_PROMOTE_TOKEN` (zero GCP access) | Concurrency `udp-gcp-promote` (`cancel-in-progress: false`); cuts single-train tag & opens 1-line Promotion PR |

#### Workflow Dispatch Inputs

| Workflow | Input | Allowed Values | Behavior |
| :--- | :--- | :--- | :--- |
| `udp-gcp-apply.yml` | `target_env` | `dev`, `uat`, `prod` | Targets a single released environment for manual apply |
| `udp-gcp-promote.yml` | `promotion` | `dev-to-uat`, `uat-to-prod` | Selects tag-cut promotion (`dev -> uat`) or tag-parity promotion (`uat -> prod`) |
| `udp-gcp-promote.yml` | `bump` | `patch`, `minor`, `major` | Semver increment for `dev-to-uat` when cutting a new tag (starts at `udp-gcp-v0.1.0`) |

### 4.2 Least-Privilege Permissions

All three workflows declare top-level `permissions: {}` and grant only the job-level scopes below.

| Workflow | Job | Granted Scopes | Purpose |
| :--- | :--- | :--- | :--- |
| `udp-gcp-pr-check.yml` | `detect-changes` | `contents: read` | Compute affected environments from PR diff |
| `udp-gcp-pr-check.yml` | `static-checks` | `contents: read` | Run offline lint, security, schema, and mocked tests |
| `udp-gcp-pr-check.yml` | `plan` | `contents: read`, `id-token: write`, `pull-requests: write` | WIF plan auth, private tag fetch, and PR comment upsert |
| `udp-gcp-apply.yml` | `detect-changes` | `contents: read` | Map `main` diff or `target_env` to apply flags |
| `udp-gcp-apply.yml` | `apply-{dev,uat,prod}` | `contents: read`, `id-token: write` | `main`-only WIF apply auth and private tag fetch |
| `udp-gcp-promote.yml` | `promote` | `contents: write`, `pull-requests: write` | Push annotated tag and open Promotion PR |

### 4.3 Companion Platform Alignment & Release Pin Contract

| Path | Role | Contract |
| :--- | :--- | :--- |
| `infra/platform/module-versions.yaml` | Atomic upstream pins | Relocated from `infra/`; read via OpenTofu 1.8+ Early Variable Evaluation (`yamldecode(file("${path.module}/module-versions.yaml"))`) so upstream CFF and Project Factory versions freeze inside each `udp-gcp-vX.Y.Z` tag |
| `infra/envs/dev/terragrunt.hcl` | `dev` wrapper | Keeps `source = "../../platform//."` to track `main` HEAD |
| `infra/envs/uat/release.yaml` | `uat` pin file | Machine-promoted version pin (`"unreleased"` on Day 0, then `"udp-gcp-vX.Y.Z"`) |
| `infra/envs/prod/release.yaml` | `prod` pin file | Machine-promoted version pin (`"unreleased"` on Day 0, then `"udp-gcp-vX.Y.Z"`) |
| `infra/envs/{uat,prod}/terragrunt.hcl` | Tagged env wrappers | Resolves `terraform.source` to `${include.root.locals.platform_git_source}?ref=${local.platform_version}`; falls back to `../../platform//.` only when `UDP_GCP_OFFLINE_TEST=true` |

```yaml
# infra/envs/{uat,prod}/release.yaml (Managed by .github/workflows/udp-gcp-promote.yml)
# Allowed values: "unreleased" (Day-0 pre-promotion) or "udp-gcp-vX.Y.Z"
platform_version: "unreleased"
```

#### Validation Patterns, Git Auth & Portability Constants

| Rule / Constant | Pattern or Value |
| :--- | :--- |
| `release.yaml` (`platform_version`) | `^(unreleased\|udp-gcp-v[0-9]+\.[0-9]+\.[0-9]+)$` |
| `PROJECT_DIR` | `"platform_unified_data_gcp"` |
| `UDP_GCP_PLATFORM_REPO` | Repository slug parameterizing tagged `terraform.source` URLs |
| Private repo Git HTTPS auth | `git config --global "url.https://x-access-token:${GITHUB_TOKEN}@github.com/${GITHUB_REPOSITORY}.insteadOf" "https://github.com/${GITHUB_REPOSITORY}"` |
| Public upstream modules | `cloud-foundation-fabric` and `terraform-google-project-factory` continue cloning anonymously over HTTPS |

### 4.4 Change-Detection Routing Matrix

| Changed Path Pattern | Target Envs | Behavior |
| :--- | :--- | :--- |
| `infra/platform/**` (incl. `module-versions.yaml`) | `dev` | `uat` and `prod` pin immutable tags; zero blast radius outside `dev` |
| `infra/envs/dev/**` | `dev` | Dev-only wrapper or input edits |
| `infra/envs/uat/**` (incl. `uat/release.yaml`) | `uat` (if released) | UAT promotion PR or UAT-only config edit |
| `infra/envs/prod/**` (incl. `prod/release.yaml`) | `prod` (if released) | Prod promotion PR, rollback PR, or Prod-only config edit |
| `infra/envs/root.hcl` | `dev` + released `uat`/`prod` | Shared backend/provider/KMS edits apply in `dev` → `uat` → `prod` order |
| `.github/workflows/udp-gcp-{pr-check,apply}.yml` | `dev` | Exercises CI/CD pipeline changes safely against `dev` only |
| `scripts/**`, `specs/**`, `README.md`, `udp-gcp-promote.yml` | *none* | `static-checks` runs on PR; zero GCP plans or applies triggered |

### 4.5 Static Quality & Security Gate (`static-checks`)

| Gate | Command / Tool | Enforced Invariant |
| :--- | :--- | :--- |
| Formatting | `tofu fmt` · `terragrunt hcl fmt` | Canonical HCL formatting across platform and envs |
| Layout invariants | Custom repo check | Zero `.tf` files under `infra/envs/`; absence of `infra/modules/` |
| Tag-pinning & schemas | Schema check | Zero hardcoded `?ref=v...` literals in `infra/platform/*.tf`; valid `module-versions.yaml` semver and `release.yaml` regex |
| Render & validation | `terragrunt render` · `validate` | Valid Terragrunt generation and OpenTofu schema across envs |
| Lint & security | `tflint --recursive` · `trivy config` (`HIGH,CRITICAL`) | Zero lint defects and zero high/critical IaC misconfigurations |
| Script & IaC unit tests | `scripts/test_detect_affected_envs.sh` · mocked `tofu test` / `terragrunt test` | Verified change-detection routing and mocked resource contracts |

### 4.6 Promotion PR Body Contract (`udp-gcp-promote.yml`)

Every Promotion PR automatically includes all four sections below, pairing exact HCL changes with the live `terragrunt plan` comment from `udp-gcp-pr-check.yml`.

| Section | Source / Command | Constraint |
| :--- | :--- | :--- |
| Release metadata | `source_env -> target_env`, `prev_tag -> target_tag`, tagged commit SHA, GitHub compare link | Always present at top of PR body |
| Commit changelog | `git log --oneline <prev_tag>..<target_tag> -- platform_unified_data_gcp/infra/platform` | Structured via Conventional Commit prefixes (`REQ-09`) |
| Changed file stats | `git diff --stat <prev_tag>..<target_tag> -- platform_unified_data_gcp/infra/platform` | Summarizes OpenTofu and `module-versions.yaml` changes |
| Collapsible HCL diff | `<details>` wrapping `git diff <prev_tag>..<target_tag> -- platform_unified_data_gcp/infra/platform` | Truncated safely below GitHub's `65,536`-char limit with compare link |

### 4.7 Consumed GitHub Actions Variables & Optional Secrets

The 7 org-owned variables (`WIF_PROVIDER`, `PLAN_SA`, `APPLY_SA`, `STATE_BUCKET`, `STATE_KMS_KEY_ID`, `PLATFORM_FOLDER_ID`, `BILLING_ACCOUNT_ID`) are synced by [`x-ruiz/platform_gcp_org_bootstrap`](https://github.com/x-ruiz/platform_gcp_org_bootstrap); project ID prefixes and `UDP_GCP_BUDGET_ALERT_EMAIL` are owned by this repository.

#### Repository Variables

| Variable | Required | Workflows | Purpose |
| :--- | :---: | :--- | :--- |
| `UDP_GCP_WIF_PROVIDER` | Yes | `pr-check`, `apply` | GCP Workload Identity Provider resource name |
| `UDP_GCP_PLAN_SA` | Yes | `pr-check` | Read-only plan Service Account |
| `UDP_GCP_APPLY_SA` | Yes | `apply` | `main`-only apply Service Account |
| `UDP_GCP_STATE_BUCKET` | Yes | `pr-check`, `apply` | Versioned GCS state bucket |
| `UDP_GCP_STATE_KMS_KEY_ID` | Yes | `pr-check`, `apply` | Cloud KMS key for OpenTofu state/plan encryption |
| `UDP_GCP_PLATFORM_FOLDER_ID` | Yes | `pr-check`, `apply` | Target GCP Platform Folder |
| `UDP_GCP_BILLING_ACCOUNT_ID` | Yes | `pr-check`, `apply` | GCP Billing Account ID |
| `UDP_GCP_BUDGET_ALERT_EMAIL` | Yes | `pr-check`, `apply` | Billing alert recipient email |
| `UDP_GCP_DEV_PROJECT_ID` | Yes | `pr-check`, `apply` | Base project ID prefix for `dev` |
| `UDP_GCP_UAT_PROJECT_ID` | Optional | `pr-check`, `apply` | Base project ID prefix for `uat` (default `udp-uat`) |
| `UDP_GCP_PROD_PROJECT_ID` | Optional | `pr-check`, `apply` | Base project ID prefix for `prod` (default `udp-prod`) |

#### Optional Repository Secrets

| Secret | Required | Workflows | Purpose |
| :--- | :---: | :--- | :--- |
| `UDP_GCP_PROMOTE_TOKEN` | Optional | `promote` | Fine-grained PAT (`contents: write`, `pull-requests: write` on this repo) so bot-opened Promotion PRs auto-trigger `udp-gcp-pr-check.yml` |

---

## 5. Invariants & Failure Modes

### Key Invariants
- **Strict blast-radius isolation:** Merging changes to `infra/platform/**` never mutates or plans `uat` or `prod` until an explicit Promotion PR updates `infra/envs/<env>/release.yaml`.
- **Atomic platform and upstream versions:** Storing `module-versions.yaml` inside `infra/platform/` freezes platform HCL and upstream CFF / Project Factory versions together under each `udp-gcp-vX.Y.Z` tag.
- **Immutable artifact parity (`uat -> prod`):** `udp-gcp-promote.yml` for `uat-to-prod` never cuts a new tag; it promotes only the exact `udp-gcp-vX.Y.Z` tag currently verified in `infra/envs/uat/release.yaml`.
- **Server-side single-trunk security:** `sa-tofu-apply` stays bound strictly to `refs/heads/main` in GCP WIF, and `udp-gcp-promote.yml` holds zero GCP permissions.
- **True read-only PR plans (including Day 0):** `sa-tofu-plan` never writes `default.tfstate`; when remote state does not yet exist, `udp-gcp-pr-check.yml` sets `UDP_GCP_EPHEMERAL_PLAN_STATE=true` while authenticating against real GCP.
- **Instant declarative rollback:** Reverting a `prod` Promotion PR reverts 1 line in `infra/envs/prod/release.yaml`, automatically planning the rollback on PR and restoring the prior tag in `prod` only on merge.

### Release-Train & Feature-Flag Discipline
- **Always-releasable `main`:** Changes merge into `main` only when ready to join the single linear semver tag train (`udp-gcp-vX.Y.Z`).
- **Opt-in feature flags:** Every new infrastructure capability ships behind a boolean input defaulting to `false` (matching `enable_cloud_nat` and `enable_flow_logs`), enabled first in `dev` and flipped per environment in `uat`/`prod` after tag promotion.
- **Expand-and-contract mutations:** Non-additive edits to live resources introduce the new resource behind a flag, migrate, and remove the old resource in a later tag (or hold in a PR until ready).

### Failure Modes

| Condition | Expected Behavior | Guarantee |
| :--- | :--- | :--- |
| `udp-gcp-promote.yml` triggered off `main` | Fails immediately at branch guard (`github.ref != 'refs/heads/main'`) | Blocks cutting tags from unreviewed branches |
| `uat-to-prod` while `uat` is `"unreleased"` or equals `prod` | Exits non-zero with clear message; no PR opened | Enforces `dev -> uat -> prod` order; zero no-op PRs |
| `dev-to-uat` when `main` HEAD is already tagged or zero `infra/platform/**` changes since latest tag | Reuses existing `udp-gcp-vX.Y.Z` tag (fails non-zero if `uat` already pins it) | Prevents duplicate or empty semver tags |
| `UDP_GCP_PROMOTE_TOKEN` secret not configured | Creates PR via `GITHUB_TOKEN` with explicit banner explaining manual PR-check trigger | Transparent handling of GitHub's anti-recursion rule |
| PR edits `infra/envs/uat/terragrunt.hcl` while `uat` is `"unreleased"` | `static-checks` runs; `plan (uat)` skips with clear log note | Prevents `git clone ?ref=unreleased` on Day 0 |
| Pinned tag in `release.yaml` missing from Git | `terragrunt init` fails during PR plan before merge | Blocks tag typos from ever reaching `main` |
| Non-`main` PR attempts to impersonate `sa-tofu-apply` | GCP STS rejects with `403 PERMISSION_DENIED` | Server-side WIF IAM condition enforcement |
| Two rapid merges to `main` target same env | Second apply queues (`cancel-in-progress: false`) + GCS `.tflock` | Prevents concurrent state corruption |

---

## 6. Acceptance & Verification (`TC-*`)

| Case | Scenario | Pass Condition |
| :--- | :--- | :--- |
| `TC-001` (`REQ-01`, `REQ-04`, `REQ-08`) | PR static, schema & release-pin gate | PR touching `platform_unified_data_gcp/**` passes formatting, zero `.tf` in `envs/`, zero `infra/modules/`, `module-versions.yaml` semver, `release.yaml` schema, `terragrunt render`, `validate`, `tflint`, `trivy`, `test_detect_affected_envs.sh`, and mocked tests. |
| `TC-002` (`REQ-03`, `REQ-05`) | Feature PR scoped to `dev` only | PR editing `infra/platform/**` only yields `detect-changes` output `["dev"]`; PR Check plans and comments **only for `dev`**, leaving `uat` and `prod` untouched. |
| `TC-003` (`REQ-03`, `REQ-06`) | Main merge deploys `dev` only | Merging an `infra/platform/**` feature PR to `main` runs `apply-dev` only under `sa-tofu-apply`; `apply-uat` and `apply-prod` are skipped. |
| `TC-004` (`REQ-07`, `REQ-09`) | Promote `dev -> uat` with TF diff | Running `udp-gcp-promote.yml` (`promotion=dev-to-uat`, `bump=minor` on `main`) cuts annotated tag `udp-gcp-v0.1.0` on `main` HEAD and opens a Promotion PR updating `infra/envs/uat/release.yaml` with changelog, diff stats, and collapsible HCL diff. |
| `TC-005` (`REQ-02`, `REQ-05`, `REQ-06`) | UAT Promotion PR plans & deploys `uat` only | Opening `promote/uat-udp-gcp-v0.1.0` detects `["uat"]`, fetches private tag `udp-gcp-v0.1.0`, and plans/comments **only `uat`**; merging runs `apply-uat` only. |
| `TC-006` (`REQ-06`, `REQ-07`) | Promote `uat -> prod` immutable parity | Running `udp-gcp-promote.yml` (`promotion=uat-to-prod` on `main`) reads `udp-gcp-v0.1.0` from `uat/release.yaml` (no new tag), opens a Promotion PR for `prod/release.yaml`, plans **only `prod`**, and runs `apply-prod` only on merge. |
| `TC-007` (`REQ-03`, `REQ-05`, `REQ-06`) | Independent `prod` config edit | PR modifying `infra/envs/prod/terragrunt.hcl` (e.g., `monthly_budget_usd`) while newer untagged commits exist in `infra/platform/` plans and applies **only `prod`** against its pinned `udp-gcp-v0.1.0` tag with zero untested code bleed. |
| `TC-008` (`REQ-01`, `REQ-06`, `REQ-07`) | Negative guards (branch & unreleased gate) | Triggering `promote` off `main` or `uat-to-prod` while `uat` is `"unreleased"` fails closed with zero tag/PR created; attempting `sa-tofu-apply` on a PR fails with GCP WIF `403 PERMISSION_DENIED`. |
