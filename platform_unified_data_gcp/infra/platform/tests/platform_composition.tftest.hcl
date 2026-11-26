mock_provider "random" {
  mock_resource "random_id" {
    defaults = {
      hex = "e5f6"
    }
  }
}

mock_provider "google" {
  mock_resource "google_project" {
    defaults = {
      number = "987654321098"
    }
  }

  mock_data "google_project" {
    defaults = {
      number = "987654321098"
    }
  }
}

mock_provider "google-beta" {
  mock_resource "google_project" {
    defaults = {
      number = "987654321098"
    }
  }

  mock_data "google_project" {
    defaults = {
      number = "987654321098"
    }
  }
}

variables {
  environment        = "dev"
  platform_folder_id = "folders/123456789012"
  billing_account_id = "01ABCD-23EFGH-45IJKL"
  project_id         = "udp-dev-test"
  project_name       = "UDP Dev"
  region             = "us-central1"
  subnet_cidr        = "10.10.0.0/20"
  monthly_budget_usd = 50
  budget_alert_email = "alerts@example.com"
}

# TC-005 (dev): Default $0/mo baseline with tag-pinned upstream CFF & PF budget modules
run "dev_platform_composition" {
  command = plan

  assert {
    condition     = module.project.project_id == "udp-dev-test-e5f6"
    error_message = "Dev platform must append 4-char hex suffix to project_id."
  }

  assert {
    condition     = module.vpc.name == "udp-dev-vpc" && length(module.cloud_nat) == 0 && output.nat_enabled == false
    error_message = "Dev platform must create udp-dev-vpc with 0 Cloud NAT modules when enable_cloud_nat is false."
  }

  assert {
    condition     = google_monitoring_notification_channel.budget_email.labels["email_address"] == "alerts@example.com"
    error_message = "Monitoring email channel must target var.budget_alert_email."
  }

  assert {
    condition = alltrue([
      for m in values(local.module_versions) : can(regex("^v[0-9]+\\.[0-9]+\\.[0-9]+$", m.version))
    ]) && local.cff_version == local.module_versions["cloud-foundation-fabric"].version && local.project_factory_version == local.module_versions["terraform-google-project-factory"].version
    error_message = "Upstream module tags must be early-evaluated from module-versions.yaml as immutable vX.Y.Z releases."
  }
}

# TC-005 (uat): Parameterized UAT composition
run "uat_platform_composition" {
  command = plan

  variables {
    environment        = "uat"
    project_id         = "udp-uat-test"
    project_name       = "UDP UAT"
    subnet_cidr        = "10.20.0.0/20"
    monthly_budget_usd = 100
  }

  assert {
    condition     = module.project.project_id == "udp-uat-test-e5f6" && module.vpc.name == "udp-uat-vpc" && length(module.cloud_nat) == 0
    error_message = "UAT platform must wire environment = uat across upstream modules."
  }
}

# TC-005 (prod + opt-in NAT): Parameterized Prod composition with flow logs and Cloud NAT
run "prod_platform_with_opt_in_nat" {
  command = plan

  variables {
    environment        = "prod"
    project_id         = "udp-prod-test"
    project_name       = "UDP Prod"
    subnet_cidr        = "10.30.0.0/20"
    enable_flow_logs   = true
    enable_cloud_nat   = true
    monthly_budget_usd = 250
  }

  assert {
    condition     = module.project.project_id == "udp-prod-test-e5f6" && module.vpc.name == "udp-prod-vpc" && length(module.cloud_nat) == 1 && output.nat_enabled == true
    error_message = "Prod platform must enable Cloud NAT when enable_cloud_nat is true."
  }
}

# TC-005 (negative): Reject unsupported environment enum, invalid CIDR, and zero budget
run "reject_invalid_environment" {
  command = plan

  variables {
    environment = "staging"
  }

  expect_failures = [var.environment]
}

run "reject_invalid_cidr" {
  command = plan

  variables {
    subnet_cidr = "not-a-cidr"
  }

  expect_failures = [var.subnet_cidr]
}

run "reject_zero_budget" {
  command = plan

  variables {
    monthly_budget_usd = 0
  }

  expect_failures = [var.monthly_budget_usd]
}

# Spec 04 TC-002: lakehouse APIs enabled on the environment project.
run "lakehouse_apis_enabled" {
  command = plan

  assert {
    condition = alltrue([
      for api in ["storage.googleapis.com", "biglake.googleapis.com", "bigquery.googleapis.com", "bigqueryconnection.googleapis.com"] :
      contains(module.project.services, api)
    ])
    error_message = "Project must enable storage, biglake, bigquery, and bigqueryconnection APIs."
  }
}

# Spec 04 TC-003: catalog root bucket naming, hardening, and labels.
run "catalog_root_bucket_hardening" {
  command = plan

  assert {
    condition     = module.catalog_root_bucket.name == "udp-dev-bronze-catalog-e5f6"
    error_message = "Catalog root bucket must be named udp-<env>-bronze-catalog-<project suffix>."
  }

  assert {
    condition = (
      upper(module.catalog_root_bucket.bucket.location) == "US-CENTRAL1" &&
      module.catalog_root_bucket.bucket.storage_class == "STANDARD" &&
      module.catalog_root_bucket.bucket.uniform_bucket_level_access == true &&
      module.catalog_root_bucket.bucket.public_access_prevention == "enforced" &&
      module.catalog_root_bucket.bucket.versioning[0].enabled == true &&
      module.catalog_root_bucket.bucket.soft_delete_policy[0].retention_duration_seconds == 604800 &&
      module.catalog_root_bucket.bucket.force_destroy == false
    )
    error_message = "Catalog root bucket must be regional STANDARD with UBLA, enforced PAP, versioning, 7d soft delete, and force_destroy = false."
  }

  assert {
    condition = (
      module.catalog_root_bucket.bucket.labels["managed_by"] == "opentofu" &&
      module.catalog_root_bucket.bucket.labels["platform"] == "unified-data-platform" &&
      module.catalog_root_bucket.bucket.labels["environment"] == "dev" &&
      module.catalog_root_bucket.bucket.labels["cost_center"] == "engineering-playground" &&
      module.catalog_root_bucket.bucket.labels["layer"] == "bronze" &&
      module.catalog_root_bucket.bucket.labels["domain"] == "platform"
    )
    error_message = "Catalog root bucket must carry mandatory labels plus layer = bronze and domain = platform."
  }
}

# Spec 04 TC-005 (partial): reject soft delete below 7 days.
run "reject_soft_delete_below_minimum" {
  command = plan

  variables {
    soft_delete_retention_seconds = 86400
  }

  expect_failures = [var.soft_delete_retention_seconds]
}

# Spec 04 TC-004 / TC-006: catalog, connection, and shared outputs.
# Computed values (service accounts, connection ID) need a mocked apply; nothing real is created.
# Top-level attributes are overridden with fixed values. OpenTofu cannot set nested blocks such as
# cloud_resource through overrides or mock defaults, so the connection SA output is checked for
# wiring to the resource attribute instead of an exact value.
run "catalog_connection_and_outputs" {
  command = apply

  override_resource {
    target = google_biglake_iceberg_catalog.bronze
    values = {
      biglake_service_account = "service-987654321098@gcp-sa-biglake.iam.gserviceaccount.com"
    }
  }

  override_resource {
    target = google_bigquery_connection.bronze
    values = {
      id = "projects/udp-dev-test-e5f6/locations/us-central1/connections/udp-dev-bronze-conn"
    }
  }

  assert {
    condition = (
      google_biglake_iceberg_catalog.bronze.name == "bronze" &&
      google_biglake_iceberg_catalog.bronze.catalog_type == "CATALOG_TYPE_BIGLAKE" &&
      google_biglake_iceberg_catalog.bronze.default_location == "gs://udp-dev-bronze-catalog-e5f6" &&
      google_biglake_iceberg_catalog.bronze.credential_mode == "CREDENTIAL_MODE_VENDED_CREDENTIALS" &&
      google_biglake_iceberg_catalog.bronze.deletion_policy == "PREVENT"
    )
    error_message = "Catalog must be bronze, CATALOG_TYPE_BIGLAKE, rooted at the catalog root bucket, with vended credentials and PREVENT."
  }

  assert {
    condition = (
      google_bigquery_connection.bronze.connection_id == "udp-dev-bronze-conn" &&
      google_bigquery_connection.bronze.location == "us-central1" &&
      length(google_bigquery_connection.bronze.cloud_resource) == 1
    )
    error_message = "BigQuery connection must be udp-<env>-bronze-conn, regional, and of type cloud_resource."
  }

  assert {
    condition = (
      output.catalog_root_bucket_name == "udp-dev-bronze-catalog-e5f6" &&
      output.catalog_root_bucket_uri == "gs://udp-dev-bronze-catalog-e5f6" &&
      output.biglake_catalog_name == "bronze" &&
      output.biglake_warehouse_uri == "bl://projects/udp-dev-test-e5f6/catalogs/bronze" &&
      output.biglake_rest_uri == "https://biglake.googleapis.com/iceberg/v1/restcatalog" &&
      output.biglake_service_account == "service-987654321098@gcp-sa-biglake.iam.gserviceaccount.com" &&
      output.bigquery_connection_id == "projects/udp-dev-test-e5f6/locations/us-central1/connections/udp-dev-bronze-conn" &&
      output.bigquery_connection_sa == google_bigquery_connection.bronze.cloud_resource[0].service_account_id &&
      length(output.bigquery_connection_sa) > 0
    )
    error_message = "All 8 Spec 04 §4.5 outputs must be exported with the documented formats."
  }
}

# Spec 04 TC-005: reject invalid catalog inputs.
run "reject_invalid_catalog_name" {
  command = plan

  variables {
    catalog_name = "Bronze Layer"
  }

  expect_failures = [var.catalog_name]
}

run "reject_invalid_catalog_deletion_policy" {
  command = plan

  variables {
    catalog_deletion_policy = "KEEP"
  }

  expect_failures = [var.catalog_deletion_policy]
}

# Spec 04 TC-004: the catalog root bucket is an empty anchor with no IAM. The CFF gcs module exposes
# no IAM outputs, so this guards the configuration itself: no storage IAM resources anywhere in the
# platform stack, and no iam* inputs passed to the catalog_root_bucket module.
run "catalog_root_bucket_has_no_iam" {
  command = plan

  assert {
    condition = (
      module.catalog_root_bucket.name == "udp-dev-bronze-catalog-e5f6" &&
      length(regexall("google_storage_bucket_iam", join("\n", [for f in fileset(".", "*.tf") : file(f)]))) == 0 &&
      length(regexall("(?m)^\\s*iam[a-z_]*\\s*=", regex("module \"catalog_root_bucket\" \\{[\\s\\S]*?\\n\\}", file("main.tf")))) == 0
    )
    error_message = "The catalog root bucket must exist with no IAM: no google_storage_bucket_iam_* resources and no iam* module inputs."
  }
}

# Spec 04 TC-005 edges: soft delete above 90 days and a catalog_name ending in a separator.
run "reject_soft_delete_above_maximum" {
  command = plan

  variables {
    soft_delete_retention_seconds = 7776001
  }

  expect_failures = [var.soft_delete_retention_seconds]
}

run "reject_catalog_name_trailing_separator" {
  command = plan

  variables {
    catalog_name = "bronze-"
  }

  expect_failures = [var.catalog_name]
}
