# Spec 04: GCP Data Lakehouse Reference Architecture

| Field | Value |
| :--- | :--- |
| **Status** | `Draft (Pending Approval)` |
| **Owner** | Xavier Ruiz |
| **Component** | `platform_unified_data_gcp/infra/lakehouse` · `platform_unified_data_gcp/lakehouse/` |
| **Stack** | OpenTofu · Terragrunt · BigLake Managed Iceberg · `sdk-lakehouse` · BigQuery · Cloud Run · Pub/Sub |
| **Archetype / Tier** | Data Pipeline + IaC & GitOps · Full Spec (Parent of Mini-Specs `05`–`12`, `13 REQs`, `14 TCs`) |
| **Depends On** | [`x-ruiz/platform_gcp_org_bootstrap`](https://github.com/x-ruiz/platform_gcp_org_bootstrap), [Spec 02](./02_platform_and_terragrunt_envs.md), [Spec 03](./03_github_actions_cicd.md) |
| **Related** | `playground-data-engineering/maven_projects/sdk_lakehouse/specs/05_iceberg_gcp_biglake_plugin.md` (`gcp_biglake` SPI) |

---

## 1. Overview & Design

### TL;DR
Org bootstrap and Specs 02–03 deliver per-environment GCP projects, networking, budgets, and GitOps promotion, but no data layer. This architecture spec defines a **data mesh on a view-first ELT lakehouse**: each business-function domain owns its data end to end and publishes curated `gold_<domain>` products, while a 3-stage self-serve platform (`infra/lakehouse` OpenTofu → `sdk-lakehouse` BigLake REST DDL → BigQuery Silver/Gold views) enforces global CI policies and keeps idle compute at `$0/mo`.

### Architecture

#### Data Mesh Topology

```mermaid
%%{init: {"theme": "base", "themeCSS": "svg { background-color: #09090B !important; border-radius: 8px; }", "themeVariables": {"darkMode": true, "background": "#09090B", "mainBkg": "#18181B", "textColor": "#F4F4F5", "primaryColor": "#18181B", "primaryTextColor": "#F4F4F5", "primaryBorderColor": "#7C3AED", "lineColor": "#A855F7", "secondaryColor": "#16141F", "tertiaryColor": "#0F0F14", "edgeLabelBackground": "#18181B", "clusterBkg": "#0F0F14", "clusterBorder": "#52525B", "titleColor": "#D8B4FE", "fontFamily": "Inter, ui-sans-serif, system-ui, -apple-system, sans-serif", "fontSize": "13px"}, "flowchart": {"curve": "basis", "nodeSpacing": 42, "rankSpacing": 56, "padding": 14}}}%%
flowchart TB
    subgraph GOV["1. Federated Computational Governance (CI Policy Gates)"]
        POL["Global CI Governance Checks\nNaming Grammar · Bronze Metadata\nSchema Compat · Gold-Only Cross-Domain\ndomain.yaml + CODEOWNERS"]
    end

    subgraph D1["2. Domain: football (Business Function Owner)"]
        B1[("bronze.football\nGCP-Managed Iceberg")]
        S1["silver_football\nDomain-Internal BQ Views"]
        G1["gold_football\nPublished Data Product"]
        B1 ==>|"conform + dedup"| S1
        S1 ==>|"curate product"| G1
    end

    subgraph D2["3. Domain: finance (Business Function Owner)"]
        B2[("bronze.finance\nGCP-Managed Iceberg")]
        S2["silver_finance\nDomain-Internal BQ Views"]
        G2["gold_finance\nPublished Data Product"]
        B2 ==>|"conform + dedup"| S2
        S2 ==>|"curate product"| G2
    end

    subgraph PLAT["4. Self-Serve Platform (infra/lakehouse + sdk-lakehouse + CI)"]
        P["Stage 1 · OpenTofu: Catalog · Buckets · IAM\nStage 2 · sdk-lakehouse: Bronze REST DDL\nStage 3 · Spec 11: Silver / Gold Views"]
    end

    C(["Analysts / BI Consumers\nRead gold_* Only"])

    G1 -->|"cross-domain: gold views only"| G2
    G1 ==>|"authorized product read"| C
    G2 ==>|"authorized product read"| C
    PLAT -.->|"provisions project-level infra"| D1
    PLAT -.->|"provisions project-level infra"| D2
    GOV -.->|"enforces PR policies"| D1
    GOV -.->|"enforces PR policies"| D2

    classDef core fill:#2E1065,stroke:#A855F7,stroke-width:2px,color:#F5F3FF
    classDef service fill:#18181B,stroke:#7C3AED,stroke-width:1.5px,color:#F4F4F5
    classDef store fill:#09090B,stroke:#C084FC,stroke-width:1.5px,color:#EDE9FE
    classDef external fill:#27272A,stroke:#71717A,stroke-width:1.5px,color:#E4E4E7
    classDef guard fill:#3B0764,stroke:#E879F9,stroke-width:2px,stroke-dasharray:5 3,color:#FAF5FF

    class POL guard
    class P core
    class B1,B2 store
    class S1,G1,S2,G2 service
    class C external

    style GOV fill:#0F0F14,stroke:#52525B,stroke-width:1.5px,color:#D8B4FE
    style D1 fill:#16141F,stroke:#6D28D9,stroke-width:1.25px,stroke-dasharray:4 3,color:#C4B5FD
    style D2 fill:#16141F,stroke:#6D28D9,stroke-width:1.25px,stroke-dasharray:4 3,color:#C4B5FD
    style PLAT fill:#0F0F14,stroke:#52525B,stroke-width:1.5px,color:#D8B4FE
```

#### Data Flow Within One Domain

```mermaid
%%{init: {"theme": "base", "themeCSS": "svg { background-color: #09090B !important; border-radius: 8px; }", "themeVariables": {"darkMode": true, "background": "#09090B", "mainBkg": "#18181B", "textColor": "#F4F4F5", "primaryColor": "#18181B", "primaryTextColor": "#F4F4F5", "primaryBorderColor": "#7C3AED", "lineColor": "#A855F7", "secondaryColor": "#16141F", "tertiaryColor": "#0F0F14", "edgeLabelBackground": "#18181B", "clusterBkg": "#0F0F14", "clusterBorder": "#52525B", "titleColor": "#D8B4FE", "fontFamily": "Inter, ui-sans-serif, system-ui, -apple-system, sans-serif", "fontSize": "13px"}, "flowchart": {"curve": "basis", "nodeSpacing": 42, "rankSpacing": 56, "padding": 14}}}%%
flowchart LR
    subgraph IngestZone["1. Domain Ingestion (Batch Default · Opt-In Stream)"]
        SRC(["Batch Sources\nAPIs · Files"])
        CRJ["Cloud Run Job\nsa-ingest-<domain>\nZero Idle Compute"]
        LAND[("GCS Landing Zone\nlanding/<domain>/...\nImmutable · Replayable")]
        EVT(["Streaming Events\nReal-Time Producers"])
        PS(["Pub/Sub Topic\nSchema Validation + DLQ"])
    end

    subgraph BronzeZone["2. Unified Managed Iceberg Bronze"]
        BRZ[("bronze.<domain>.<entity>\nGCP-Managed Iceberg · BigLake REST\nCatalog: OpenTofu · Tables: sdk-lakehouse")]
    end

    subgraph ServeZone["3. View-First BigQuery Serving Layer"]
        SIL["silver_<domain>.<entity>\nBQ View: Conform & Dedup\nLatest _ingested_at per _event_key"]
        CUR["gold_<domain>.<kind>__<entity>__*\nCurated Data Product View\nAuthorized External Interface"]
    end

    SRC ==>|"raw payload"| CRJ
    CRJ <-->|"write raw / read replay"| LAND
    CRJ ==>|"append + metadata cols"| BRZ
    EVT -.->|"publish event"| PS
    PS -.->|"opt-in enable_streaming"| BRZ
    BRZ ==>|"pruned Iceberg read"| SIL
    SIL ==>|"domain-internal read"| CUR

    classDef core fill:#2E1065,stroke:#A855F7,stroke-width:2px,color:#F5F3FF
    classDef service fill:#18181B,stroke:#7C3AED,stroke-width:1.5px,color:#F4F4F5
    classDef store fill:#09090B,stroke:#C084FC,stroke-width:1.5px,color:#EDE9FE
    classDef external fill:#27272A,stroke:#71717A,stroke-width:1.5px,color:#E4E4E7
    classDef async fill:#1E1B2E,stroke:#6B7280,stroke-width:1.25px,stroke-dasharray:4 3,color:#D4D4D8

    class SRC,EVT external
    class CRJ,SIL service
    class PS async
    class LAND,BRZ store
    class CUR core

    style IngestZone fill:#16141F,stroke:#6D28D9,stroke-width:1.25px,stroke-dasharray:4 3,color:#C4B5FD
    style BronzeZone fill:#0F0F14,stroke:#52525B,stroke-width:1.5px,color:#D8B4FE
    style ServeZone fill:#0F0F14,stroke:#52525B,stroke-width:1.5px,color:#D8B4FE
```

### Key Design Decisions (Architecture Decision Register)

| ID | Decision | Rationale & Scope | Verify In |
| :--- | :--- | :--- | :--- |
| `ADR-01` | Data mesh by business-function domain with strictly project-level IAM inside each env project | Clean domain isolation without org/folder IAM sprawl; project-per-domain deferred | `05`, `07` |
| `ADR-02` | Separate `infra/lakehouse` stack with its own state prefix and `udp-lakehouse-v*` tag namespace | Isolates data-bearing infra from `infra/platform` blast radius | `05` |
| `ADR-03` | View-first Silver & Gold in BigQuery on Day 1; `REQ-10` materialization escape hatch | `$0` idle compute and fast iteration; multi-engine physical Iceberg Silver/Gold deferred | `11` |
| `ADR-04` | 3-stage pipeline: OpenTofu (catalog/infra) → `sdk-lakehouse` (namespaces/tables via BigLake REST) → View deploy (Mini-Spec `11`) | Zero circular dependency; `sdk-lakehouse` never owns catalog lifecycle; logical catalog `bronze` stays env-agnostic | `06`, `08`, `11` |
| `ADR-05` | Unified GCP-managed Iceberg for Bronze (BigLake REST endpoints); streaming opt-in via `enable_streaming` | Avoids operating two divergent Iceberg engines or self-managed Spark compaction | `06`, `10` |
| `ADR-06` | Defer raw passthrough (`raw__`) views from gold | Preserves analyst isolation and avoids exposing unmasked raw/PII bronze columns before policy tags exist | Future |
| `ADR-07` | Spike required before build: BQ authorized views over BigLake REST tables, namespace-scoped catalog IAM, and direct Pub/Sub → managed Iceberg delivery (fallback: Storage Write API / Cloud Run writer) | Depends on current GCP BigLake and Pub/Sub feature parity | `06`, `07`, `10` |

### Done Looks Like
- Onboarding a new domain requires only adding `lakehouse/domains/<domain>/` (with `domain.yaml`) and a `CODEOWNERS` entry so the platform provisions all project-level resources automatically.
- With `enable_streaming = false`, an environment runs zero always-on compute and stays within the Spec 02 budgets (`$50` / `$100` / `$250`).
- The reference domain (`football`) flows source → landing → bronze → silver → gold in `dev` across the 3-stage deployment pipeline with full name and lineage traceability.
- Acceptance cases `TC-001` through `TC-014` pass across Mini-Specs `05`–`12`.

---

## 2. Scope

### In Scope
- Define the data mesh operating model covering domain ownership, gold-as-data-product, self-serve platform provisioning, and federated CI governance (§4.1).
- Establish an isolated `infra/lakehouse/` Terragrunt stack per environment (`envs/<env>/lakehouse` state, `udp-lakehouse-vX.Y.Z` tags) consuming `infra/platform` outputs with strictly project-level IAM.
- Lock the 3-stage deployment boundary separating OpenTofu durable foundations (Stage 1), `sdk-lakehouse` namespace/table REST DDL (Stage 2), and Silver/Gold view deployment referencing shared table definitions (Stage 3, finalized in Mini-Spec `11`).
- Standardize a unified GCP-managed Iceberg Bronze layer over GCS Landing with batch ingestion enabled by default and Pub/Sub streaming opt-in via `enable_streaming`.
- Specify cross-cutting contracts for naming, collision-free lineage, schema compatibility, runtime data quality/alerting, selective materialization, and the Mini-Spec `05`–`12` roadmap (§4.7).

### Out of Scope (Non-Goals)
- **Org- or folder-level IAM changes:** Org and folder foundations belong exclusively in `x-ruiz/platform_gcp_org_bootstrap`; all lakehouse principals and bindings live at the environment project level.
- **Catalog lifecycle in `sdk-lakehouse`:** The SDK never creates, alters, or deletes catalogs—it manages only namespaces and tables via BigLake REST endpoints.
- **Raw passthrough (`raw__`) views in gold:** Analyst access to raw bronze (with PII controls/masking) is deferred to a future spec (`ADR-06`).
- **Non-BigQuery engines or physical Silver/Gold on Day 1:** Multi-engine physical Iceberg Silver/Gold (Spark/Trino/DuckDB readers), Spark/Dataflow pipelines, and Cloud Composer are deferred beyond the in-BigQuery `REQ-10` materialization escape hatch.
- **Per-domain GCP projects on Day 1:** Domains isolate via namespace, dataset, and project-level IAM inside each environment project.
- **Advanced governance & shared marts:** CMEK, VPC-SC, Dataplex catalog/lineage UI, column-level policy tags and PII masking, automated GDPR/CCPA purge workflows, and cross-domain shared marts (`gold_shared`) are deferred to future specs.

---

## 3. Functional Requirements

Exact storage patterns, metadata schemas, naming rules, IAM scopes, and CI policy gates live once in **Section 4**.

### Platform Stack & Domain Onboarding

| ID | What | Why | How |
| :--- | :--- | :--- | :--- |
| `REQ-01` | Separate `infra/lakehouse/` stack | Isolates data-bearing infra and state from `infra/platform` blast radius | Consumes `project_id`, `project_number`, `region`, and `subnet_id` from `infra/platform` outputs; follows Spec 03 promotion (`dev` tracks `main`; `uat`/`prod` pin `udp-lakehouse-vX.Y.Z`) |
| `REQ-02` | Self-serve domain onboarding | Lets business domains onboard with zero domain-written HCL | Each domain declares `lakehouse/domains/<domain>/domain.yaml` (§4.1) + `CODEOWNERS`; Stage 1 provisions `silver_<domain>`, `gold_<domain>`, `sa-ingest-<domain>`, owner-group IAM, and landing prefix access |

### Ingestion & Managed Iceberg Bronze

| ID | What | Why | How |
| :--- | :--- | :--- | :--- |
| `REQ-03` | Immutable GCS Landing zone | Guarantees deterministic replay and backfill from unmodified raw payloads | Batch sources land raw payloads under `landing/<domain>/<source>/ingest_date=YYYY-MM-DD/<run_id>/`; objects stay immutable within retention |
| `REQ-04` | Unified managed Iceberg Bronze | Avoids operating divergent Iceberg engines or self-managed compaction | Stage 1 provisions one BigLake Iceberg REST catalog (`bronze`), warehouse bucket, and BQ connection per env; Stage 2 (`sdk-lakehouse` `gcp_biglake`) manages namespaces and tables via REST from `table.yaml`/`table.proto`; `enable_streaming = true` adds Pub/Sub + schema + DLQ (`ADR-05`/`ADR-07`), while `false` provisions zero streaming resources |
| `REQ-05` | Ingestion-time hygiene & quarantine | Prevents silent data loss and keeps ingestion free of business logic | Every bronze row carries mandatory §4.3 metadata columns; schema failures route to `landing/_quarantine/<domain>/` (batch) or Pub/Sub DLQ (streaming) |

### View-First Serving, 3-Stage Deployment & Performance

| ID | What | Why | How |
| :--- | :--- | :--- | :--- |
| `REQ-06` | Domain-internal Silver views | Standardizes typing, conformation, and deduplication with zero idle compute | Each bronze entity has one `silver_<domain>.<entity>` BQ view deduplicating on `_event_key` (latest `_ingested_at`), unreadable outside its domain |
| `REQ-07` | Gold views as published data products | Enforces strict domain sovereignty and authorized cross-domain contracts | `gold_<domain>` is the sole published interface; reads only own domain's silver or other domains' `gold_*` views (never bronze directly or another domain's silver), authorized against upstream sources |
| `REQ-08` | 3-stage definitions as code | Eliminates drift and circular dependencies across infra, tables, and views | `table.yaml`/`table.proto` and Silver/Gold views live under `lakehouse/domains/<domain>/`, reviewed via `CODEOWNERS`, deployed by CI in strict order Stage 1 → Stage 2 → Stage 3 (tool finalized in Mini-Spec `11`); manual DDL forbidden in `uat`/`prod` |
| `REQ-09` | Pruning-friendly Bronze layout | Keeps view-first BigQuery scans fast and low-cost | Bronze Iceberg tables declare partitioning (default `day(_ingested_at)`, overridable per table) and clustering/sort order on `_event_key` where supported by managed Iceberg |
| `REQ-10` | Selective materialization escape hatch | Controls scan cost and latency on hot views without breaking consumers | Silver dedup or curated gold views exceeding measured cost/latency thresholds materialize incrementally into BQ-managed Iceberg tables via `lakehouse/materializations.yaml`, preserving exact names and labels |

### Access Control, Observability & Federated Governance

| ID | What | Why | How |
| :--- | :--- | :--- | :--- |
| `REQ-11` | Project-level least-privilege IAM | Enforces domain isolation without org/folder IAM sprawl | All principals and bindings (§4.5) scope strictly inside each env GCP project: ingest writes own domain only, CI owns DDL without catalog create/delete, domain owners read own domain, analysts read `gold_*` only |
| `REQ-12` | Managed maintenance, DQ & alerting | Protects table health and routes domain failures to the right owners | Relies on GCP-managed Iceberg compaction + retention verification (safe orphan retention `>= 72h` where configurable); runtime DQ (freshness, Silver `_event_key` uniqueness, non-null keys), ingest failures, and DLQ backlogs alert Spec 02 channel with `domain` label |
| `REQ-13` | Federated computational governance | Blocks policy violations automatically on every PR before merge | Automated CI checks enforce naming/label limits, `domain.yaml` + `CODEOWNERS`, bronze metadata/backward-compatible schemas, layer isolation, and BQ dry-run source parity (§4.6) |

---

## 4. Contract & Blueprint

### 4.1 Data Mesh Ownership & Domain Manifest

| Mesh Principle | Implementation | Owned By |
| :--- | :--- | :--- |
| Domain ownership | One business function = one folder, bronze namespace, `silver_`/`gold_` datasets, and project-level ingest SA | Domain owner group |
| Data as a product | `gold_<domain>` curated views described by `domain.yaml` and view sidecars | Domain owner group |
| Self-serve platform | Stage 1 OpenTofu (`infra/lakehouse`) → Stage 2 `sdk-lakehouse` (REST DDL) → Stage 3 view deploy (Spec `11`) | Platform owner |
| Federated computational governance | Global policies (`REQ-13`) run as automated CI checks on every PR | Platform defines; domains comply |

```yaml
# lakehouse/domains/football/domain.yaml
domain: football
business_function: "Sports performance analytics"
owner_group: football-data-owners@<org-domain>
description: "Premier League matches, teams and player stats"
```

### 4.2 Storage, Catalog & Dataset Inventory (Per Env Project, Same Region)

| Layer | Resource & Name Pattern | Stage 1 (OpenTofu) | Contents Managed By |
| :--- | :--- | :--- | :--- |
| Landing | GCS bucket (`udp-<env>-landing-<suffix>`) with per-domain prefixes | Provisioned via CFF | `sa-ingest-<domain>` |
| Bronze | GCS warehouse (`udp-<env>-bronze-<suffix>`) + BigLake managed Iceberg REST catalog `bronze` + BQ connection | Provisioned via OpenTofu | Stage 2: `sdk-lakehouse` (namespaces & tables via REST endpoints) |
| Silver / Gold | BigQuery datasets `silver_<domain>` & `gold_<domain>` | Provisioned from `domain.yaml` | Stage 3: View deployer referencing domain `table.yaml`/`table.proto` + SQL (Mini-Spec `11`) |

#### Cross-Cutting Storage Controls

| Control | Requirement |
| :--- | :--- |
| Bucket hardening | UBLA enabled, public access prevention enforced, and soft delete enabled on all buckets |
| Landing lifecycle | Nearline transition after `30d` (where retention `> 30d`) and expiry at `landing_retention_days` (`dev` `30`, `prod` `365`) |
| Mandatory labels | All Spec 02 baseline labels plus `layer` and `domain` on every lakehouse resource |

### 4.3 Bronze Row Contract (Mandatory Metadata Columns)

| Column | Type | Rule |
| :--- | :--- | :--- |
| `_ingested_at` | `timestamp` (UTC) | Set by writer at commit; default partition source (`day(_ingested_at)`) |
| `_source` | `string` | `<domain>.<source>` identifying upstream feed |
| `_batch_id` | `string` | Cloud Run execution ID or Pub/Sub message ID |
| `_source_uri` | `string` (nullable) | Landing object URI (batch only), used for replay lineage |
| `_event_key` | `string` | Declared business key for silver deduplication & clustering/sort order |

### 4.4 Naming & Lineage Convention

All object names use `snake_case`; `__` is reserved as the token separator, and `<entity>` anchors cross-layer traceability.

| Object | Pattern | Example |
| :--- | :--- | :--- |
| Bronze table (managed Iceberg) | `bronze.<domain>.<entity>` | `bronze.football.matches` |
| Silver view (1:1 per entity) | `silver_<domain>.<entity>` | `silver_football.matches` |
| Curated gold view | `gold_<domain>.<kind>__<entity>__<qualifier>` (`kind` ∈ `dim`, `fct`, `agg`, `rpt`) | `gold_football.agg__matches__team_season_standings` |

#### View Sidecar & Lineage Labels

| Artifact / Label | Requirement |
| :--- | :--- |
| View YAML sidecar | Required for every silver and gold view: `description`, `grain`, `owner`, and `sources` |
| Standard deploy labels | `domain`, `layer`, and `view_kind` applied to every deployed view |
| Collision-free lineage label | `src_<source_domain>__<entity> = "true"` validated against BigQuery limits (`<= 64` labels, `<= 63`-char keys) |
| Discovery interface | Traceable by name (`*__<entity>__*`) or via `INFORMATION_SCHEMA.TABLE_OPTIONS` |

### 4.5 Project-Level IAM & Security Principal Matrix

All service accounts and bindings below are provisioned **strictly at the environment GCP project level** (zero folder or org IAM required beyond `platform_gcp_org_bootstrap`).

| Principal | Auth / Condition | Project-Level Scope | Access |
| :--- | :--- | :--- | :--- |
| `sa-ingest-<domain>` | Cloud Run job identity | `landing/<domain>/` prefix, `bronze.<domain>` tables | Write landing; append rows; no DDL |
| Pub/Sub / streaming writer SA | Project service agent / writer SA | `bronze` streaming tables (opt-in) | Append table data only |
| `sa-lakehouse-ddl` | GitHub Actions WIF (`main` for apply) | `bronze` namespaces/tables; `silver_*` & `gold_*` views | Namespace/table/view DDL; **no** catalog create/delete |
| BigQuery connection SA | Google-managed (project-scoped) | Bronze warehouse bucket | Read / managed Iceberg storage access |
| `<domain>-data-owners` group | Google Group | Own domain's bronze, silver, gold | Read; PR approval via `CODEOWNERS` |
| `analysts` group / other domains | Google Group / authorized views | `gold_*` datasets only | Read curated data products only |

### 4.6 Federated Governance CI Policy Gates (`REQ-13`)

| Policy Gate | Scope | Reject Condition |
| :--- | :--- | :--- |
| Naming & BQ label limits | All domains & views | Violates §4.4 grammar, exceeds `64` labels, or exceeds `63`-char label keys |
| Ownership registration | `lakehouse/domains/<domain>/` | Missing `domain.yaml` or matching `CODEOWNERS` entry |
| Bronze schema & compat | `table.yaml` / `table.proto` | Missing §4.3 metadata columns or unapproved breaking change (column drop / type narrowing) |
| Layer & domain isolation | Silver & Gold SQL | Gold view reads bronze directly, or any cross-domain read of silver/bronze |
| Lineage parity | View sidecars vs BQ dry-run | Declared `sources` differ from tables reported by BigQuery dry-run |

### 4.7 Mini-Spec Roadmap

| Spec | Title | Delivers |
| :--- | :--- | :--- |
| `05` | Lakehouse stack & domain onboarding scaffold | `infra/lakehouse` Terragrunt stack, state prefix, `udp-lakehouse-v*` tags, CI routing, `domain.yaml` → project-level domain resources |
| `06` | Bronze storage & BigLake managed Iceberg catalog | Landing/bronze buckets, OpenTofu-managed BigLake REST catalog, BQ connection, lifecycle rules |
| `07` | Project-level Lakehouse IAM & domain access | §4.5 project-level principals, domain isolation, authorized-view wiring |
| `08` | Bronze namespace & table deployment (`sdk-lakehouse`) | Stage 2 CI job applying domain `table.yaml`/`table.proto` via BigLake REST endpoints + backward-compatibility check |
| `09` | Batch ingestion framework | Cloud Run job contract, landing layout, quarantine, Cloud Scheduler triggers |
| `10` | Streaming ingestion (opt-in) | Pub/Sub schemas, DLQ, managed Iceberg streaming delivery (`enable_streaming`) |
| `11` | Bronze → Silver → Gold view deployment & governance | Stage 3 deployment tool choice (Dataform/dbt/DDL runner), Silver/Gold views from shared table metadata, `REQ-13` CI checks, `REQ-10` register |
| `12` | Data quality, observability & alerting | Managed-Iceberg retention checks, runtime DQ assertions, alert policies, per-domain cost views |

---

## 5. Invariants & Failure Modes

### Key Invariants
- **Domain sovereignty:** A domain's bronze and silver are never read outside the domain; `gold_<domain>` is its sole published interface.
- **Zero idle compute by default:** With `enable_streaming = false`, no always-on compute exists.
- **Strict layering and 3-stage ordering:** Curated gold never reads bronze directly, and CI always executes Stage 1 (OpenTofu infra) → Stage 2 (`sdk-lakehouse` Bronze DDL) → Stage 3 (Silver/Gold view deploy).
- **Replayable, project-scoped, and env-agnostic:** Landing objects remain immutable within retention, all IAM is project-level, and domain definitions never hardcode project IDs, bucket names, or environment names.

### Failure Modes

| Condition | Expected Behavior | Guarantee |
| :--- | :--- | :--- |
| Domain folder lacks `domain.yaml` or `CODEOWNERS` | CI fails on PR | Zero partial domain resources provisioned |
| View breaks layer isolation, naming, label limits, or `sources` parity | CI rejects PR (`REQ-13`) | Invalid views never reach BigQuery |
| Breaking schema change (column drop / type narrowing) without override | Stage 2 CI check fails on PR (`REQ-13`) | Downstream Silver/Gold views protected |
| Malformed batch record or invalid streaming message | Routes to `_quarantine/<domain>/` or DLQ; valid rows commit; `domain`-labeled alert fires | Zero silent drops; healthy rows unaffected |
| Duplicate or late events arrive | Bronze appends every row; silver view returns latest per `_event_key` | Deterministic replayable history + clean Silver |
| Silver or gold view exceeds scan-cost or latency threshold | Recorded in `materializations.yaml` and incrementally materialized (`REQ-10`) | Same object name and labels; zero consumer breakage |
| Manual DDL executed in `uat` or `prod` | Detected as drift on next CI run and reverted (`REQ-08`) | Git remains single source of truth |

---

## 6. Acceptance & Verification (`TC-*`)

| Case | Scenario | Pass Condition |
| :--- | :--- | :--- |
| `TC-001` (`REQ-01`) | Isolated lakehouse stack & tag promotion (`05`) | Changing only `infra/lakehouse/**` and promoting `udp-lakehouse-v0.1.0` plans/applies only the lakehouse stack for `dev`, pins `uat` to the tag, and leaves `infra/platform` state untouched. |
| `TC-002` (`REQ-02`) | Zero-HCL domain onboarding (`05`) | Adding `lakehouse/domains/finance/domain.yaml` + `CODEOWNERS` provisions `silver_finance`, `gold_finance`, `sa-ingest-finance`, and project-level owner IAM with zero domain HCL. |
| `TC-003` (`REQ-04`) | Stage 1 foundation apply in `dev` (`06`) | Applying `infra/lakehouse` creates all §4.2 resources with required names, labels, UBLA, and PAP, and provisions managed Iceberg catalog `bronze` before Stage 2 runs. |
| `TC-004` (`REQ-04`) | Zero always-on compute default (`06`, `10`) | With `enable_streaming = false`, zero always-on compute and zero Pub/Sub/streaming resources exist. |
| `TC-005` (`REQ-11`) | Least-privilege project-level IAM (`07`) | `sa-ingest-football` appends only to `bronze.football` (denied `finance` and DDL); `sa-lakehouse-ddl` manages namespaces/tables but cannot create/delete catalogs; zero folder/org IAM exists. |
| `TC-006` (`REQ-06`, `REQ-07`, `REQ-11`) | Domain & analyst read isolation (`07`, `11`) | Querying as `analysts` and `finance-data-owners` succeeds on `gold_*` while direct queries to `silver_football` and `bronze.football` are denied. |
| `TC-007` (`REQ-04`, `REQ-08`, `REQ-09`, `REQ-13`) | Stage 2 `sdk-lakehouse` Bronze DDL (`08`) | Merging `football` `table.yaml` / `table.proto` creates namespace + table in existing managed Iceberg `bronze` catalog via REST endpoints; re-run is a no-op; breaking column drop fails CI. |
| `TC-008` (`REQ-03`, `REQ-05`) | Batch ingestion & metadata hygiene (`09`) | Running `football` batch ingestion lands raw payload under the `REQ-03` path and writes bronze rows carrying all §4.3 metadata columns. |
| `TC-009` (`REQ-05`, `REQ-12`) | Malformed batch quarantine & alerting (`09`, `12`) | Bad record writes to `landing/_quarantine/football/`, valid rows commit to bronze, and a `domain`-labeled alert fires. |
| `TC-010` (`REQ-04`, `REQ-05`) | Opt-in streaming ingestion & DLQ (`10`) | With `enable_streaming = true`, valid events land in managed Iceberg `bronze` and invalid events route to the DLQ. |
| `TC-011` (`REQ-06`) | Silver view deduplication (`11`) | Ingesting the same `_event_key` twice retains both rows in bronze while `silver_football.matches` returns 1 row (latest `_ingested_at`). |
| `TC-012` (`REQ-07`, `REQ-13`) | Federated governance view policy gate (`11`) | PR where `finance` gold view reads bronze directly, reads `silver_football`, breaks naming, or has undeclared sources fails CI; compliant view reading `gold_football` deploys with `domain` and `src_<domain>__<entity>` labels. |
| `TC-013` (`REQ-08`, `REQ-13`) | Collision-free cross-domain lineage (`11`) | Filtering `INFORMATION_SCHEMA.TABLE_OPTIONS` by `src_football__matches` returns every silver and gold view built on `football.matches` across domains without cross-domain label collisions. |
| `TC-014` (`REQ-12`) | Runtime DQ & failure alerting (`12`) | Forcing an ingestion failure, DLQ backlog, or Silver uniqueness DQ violation delivers an alert to the Spec 02 notification channel carrying the `domain` label. |
