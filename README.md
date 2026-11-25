# Playground: Cloud Engineering

Incubator monorepo for prototyping cloud infrastructure-as-code, GitOps patterns, and platform foundations before graduating mature projects into their own standalone repositories.

## Repository Layout

```text
playground-cloud-engineering/
├── .github/
│   └── workflows/
│       ├── udp-gcp-pr-check.yml       # PR static checks, mocked tests, and read-only multi-env plan
│       └── udp-gcp-apply.yml          # Serialized main-branch apply (dev auto; uat/prod gated)
├── platform_unified_data_gcp/         # OpenTofu + Terragrunt + GCP Unified Data Platform foundation
│   ├── README.md
│   ├── specs/                         # Spec 01 (Bootstrap), Spec 03 (Platform/Terragrunt), Spec 04 (CI/CD)
│   ├── scripts/                       # Automated Phase 0+1 bootstrap script & offline mocked tests
│   └── infra/
│       ├── bootstrap/                 # One-time Org Folder, Seed project, GCS state, KMS, WIF, GitHub vars
│       ├── platform/                  # Single OpenTofu platform root sourcing tag-pinned public GitHub modules
│       └── envs/                      # Thin DRY Terragrunt wrappers (root.hcl + dev / uat / prod)
└── README.md
```

## Projects

| Project | Cloud | IaC Stack | Docs | Description |
| :--- | :--- | :--- | :--- | :--- |
| [platform_unified_data_gcp](./platform_unified_data_gcp/README.md) | GCP | OpenTofu + Terragrunt + GitHub Actions (WIF) | [Spec 01](./platform_unified_data_gcp/specs/01_gcp_bootstrap_and_wif.md) · [Spec 03](./platform_unified_data_gcp/specs/03_platform_and_terragrunt_envs.md) · [Spec 04](./platform_unified_data_gcp/specs/04_github_actions_cicd.md) | GCP Org bootstrap, KMS-encrypted GCS state, dual plan/apply WIF GitOps, tag-pinned Cloud Foundation Fabric platform composition, and DRY Terragrunt `dev`/`uat`/`prod` wrappers. |

## Graduation Convention

Each project directory is strictly self-contained (zero cross-project relative imports) so it can be extracted into a dedicated repository via `git subtree split` alongside its path-scoped workflows in `.github/workflows/`.
