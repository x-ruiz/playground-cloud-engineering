# Playground: Cloud Engineering

Incubator monorepo for prototyping cloud infrastructure-as-code, GitOps patterns, and platform foundations before graduating mature projects into their own standalone repositories.

## Repository Layout

```text
playground-cloud-engineering/
├── .github/
│   └── workflows/
│       ├── udp-gcp-pr-check.yml       # PR static checks, mocked tests, and read-only multi-env plan
│       ├── udp-gcp-apply.yml          # Serialized main-branch apply (dev auto; uat/prod gated)
│       └── udp-gcp-promote.yml        # Tag-based release promotion (dev -> uat -> prod)
├── platform_unified_data_gcp/         # OpenTofu + Terragrunt + GCP Unified Data Platform foundation
│   ├── README.md
│   ├── specs/                         # Spec 01 (Platform/Terragrunt), Spec 02 (CI/CD), Spec 03 (Data Lakehouse)
│   ├── scripts/                       # CI change-detection script & offline mocked tests
│   └── infra/
│       ├── platform/                  # Single OpenTofu platform root sourcing tag-pinned public GitHub modules
│       └── envs/                      # Thin DRY Terragrunt wrappers (root.hcl + dev / uat / prod)
└── README.md
```

## Projects

| Project | Cloud | IaC Stack | Docs | Description |
| :--- | :--- | :--- | :--- | :--- |
| [platform_unified_data_gcp](./platform_unified_data_gcp/README.md) | GCP | OpenTofu + Terragrunt + GitHub Actions (WIF) | [Spec 01](./platform_unified_data_gcp/specs/01_platform_module_setup.md) · [Spec 02](./platform_unified_data_gcp/specs/02_github_actions_cicd.md) · [Spec 03](./platform_unified_data_gcp/specs/03_data_lakehouse_architecture.md) | Tag-pinned Cloud Foundation Fabric platform composition and DRY Terragrunt `dev`/`uat`/`prod` wrappers (consumes Org/Folder foundation from [`platform_gcp_org_bootstrap`](https://github.com/x-ruiz/platform_gcp_org_bootstrap)). |

## Graduated Projects

| Project | Standalone Repository | Graduated | Notes |
| :--- | :--- | :--- | :--- |
| `platform_unified_data_gcp/infra/bootstrap` | [x-ruiz/platform_gcp_org_bootstrap](https://github.com/x-ruiz/platform_gcp_org_bootstrap) | 2026-11-25 | Generalized GCP Org bootstrap: Seed project, Cloud KMS-encrypted state, multi-folder & Org Policies, and per-folder keyless GitHub Actions WIF. |

## Graduation Convention

Each project directory is strictly self-contained (zero cross-project relative imports) so it can be extracted into a dedicated repository via `git subtree split` alongside its path-scoped workflows in `.github/workflows/`.
