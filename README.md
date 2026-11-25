# Playground: Cloud Engineering

Incubator monorepo for prototyping cloud infrastructure-as-code, GitOps patterns, and platform foundations before graduating mature projects into their own standalone repositories.

## Repository Layout

```text
playground-cloud-engineering/
├── .github/
│   └── workflows/
│       ├── udp-gcp-pr-check.yml       # PR static checks, mocked tests, and read-only plan
│       └── udp-gcp-apply-dev.yml      # Serialized main-branch apply for dev
├── platform_unified_data_gcp/         # OpenTofu + GCP Unified Data Platform foundation
│   ├── README.md
│   ├── specs/
│   └── infra/
│       ├── bootstrap/                 # One-time Org Folder, Seed project, GCS state, KMS, WIF
│       ├── modules/                   # Reusable OpenTofu modules + mocked tofu tests
│       └── envs/dev/                  # Dev environment composition + mocked tofu tests
└── README.md
```

## Projects

| Project | Cloud | IaC Stack | Docs | Description |
| :--- | :--- | :--- | :--- | :--- |
| [platform_unified_data_gcp](./platform_unified_data_gcp/README.md) | GCP | OpenTofu + GitHub Actions (WIF) | [Spec 01](./platform_unified_data_gcp/specs/01_gcp_foundation_and_gitops.md) | GCP Organization Project Factory, KMS-encrypted GCS state, dual plan/apply WIF GitOps, `$0/mo` baseline custom VPC, and Billing Budget guardrails. |

## Graduation Convention

Each project directory is strictly self-contained (zero cross-project relative imports) so it can be extracted into a dedicated repository via `git subtree split` alongside its path-scoped workflows in `.github/workflows/`.
