# Shared Terragrunt root for platform_unified_data_gcp environments (dev, uat, prod).
# Drives OpenTofu, exposes `platform_git_source` (the tagged Git URL of infra/platform used by
# uat/prod release pins), and generates backend.tf, encryption.tf, and provider.tf.
# Upstream module tags are NOT read here: infra/platform/main.tf reads its own
# infra/platform/module-versions.yaml so they freeze atomically inside each udp-gcp-vX.Y.Z tag.

terraform_binary = "tofu"

locals {
  offline_test         = get_env("UDP_GCP_OFFLINE_TEST", "false") == "true"
  ephemeral_plan_state = get_env("UDP_GCP_EPHEMERAL_PLAN_STATE", "false") == "true"
  disable_remote_state = local.offline_test || local.ephemeral_plan_state
  region               = get_env("UDP_GCP_REGION", "us-central1")
  state_bucket         = local.disable_remote_state ? "offline-placeholder-bucket" : get_env("UDP_GCP_STATE_BUCKET")
  state_kms_key_id     = local.disable_remote_state ? "offline-placeholder-kms-key" : get_env("UDP_GCP_STATE_KMS_KEY_ID")
  env_rel_path         = path_relative_to_include()

  # Tagged platform source for uat/prod (`${platform_git_source}?ref=udp-gcp-vX.Y.Z`).
  # Graduation portability: override UDP_GCP_PLATFORM_REPO for a new repository; the in-repo
  # subdirectory of infra/platform is derived from this file's location relative to the Git root
  # (`platform_unified_data_gcp/infra/platform` here, `infra/platform` once graduated).
  platform_repo         = get_env("UDP_GCP_PLATFORM_REPO", "https://github.com/x-ruiz/playground-cloud-engineering.git")
  platform_repo_subpath = trimprefix(trimprefix(abspath("${get_parent_terragrunt_dir()}/../platform"), get_repo_root()), "/")
  platform_git_source   = "git::${local.platform_repo}//${local.platform_repo_subpath}"
}

generate "backend" {
  path      = "backend.tf"
  if_exists = "overwrite_terragrunt"
  disable   = local.disable_remote_state
  contents  = <<-EOF
    terraform {
      backend "gcs" {
        bucket = "${local.state_bucket}"
        prefix = "envs/${local.env_rel_path}"
      }
    }
  EOF
}

generate "encryption" {
  path      = "encryption.tf"
  if_exists = "overwrite_terragrunt"
  disable   = local.disable_remote_state
  contents  = <<-EOF
    terraform {
      encryption {
        key_provider "gcp_kms" "state" {
          kms_encryption_key = "${local.state_kms_key_id}"
          key_length         = 32
        }

        method "aes_gcm" "state" {
          keys = key_provider.gcp_kms.state
        }

        state {
          method   = method.aes_gcm.state
          enforced = true
        }

        plan {
          method   = method.aes_gcm.state
          enforced = true
        }
      }
    }
  EOF
}

generate "provider" {
  path      = "provider.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<-EOF
    # user_project_override: bill API quota to the env project each resource targets, not the
    # CI identity's seed project (Spec 01 §4.6). Workload APIs live only on env projects.
    provider "google" {
      region                = "${local.region}"
      user_project_override = true
    }

    provider "google-beta" {
      region                = "${local.region}"
      user_project_override = true
    }
  EOF
}

inputs = {
  platform_folder_id = local.offline_test ? "folders/123456789012" : get_env("UDP_GCP_PLATFORM_FOLDER_ID")
  billing_account_id = local.offline_test ? "01ABCD-23EFGH-45IJKL" : get_env("UDP_GCP_BILLING_ACCOUNT_ID")
  budget_alert_email = local.offline_test ? "alerts@example.com" : get_env("UDP_GCP_BUDGET_ALERT_EMAIL")
  region             = local.region
  platform_name      = "unified-data-platform"
  cost_center        = "engineering-playground"
  deletion_policy    = "PREVENT"
  platform_apis      = [
      "compute.googleapis.com",
      "iam.googleapis.com",
      "serviceusage.googleapis.com",
      "monitoring.googleapis.com",
      "billingbudgets.googleapis.com",
      # Lakehouse (Spec 04): catalog root & domain buckets, BigLake REST catalog, BigQuery + connection.
      "storage.googleapis.com",
      "biglake.googleapis.com",
      "bigquery.googleapis.com",
      "bigqueryconnection.googleapis.com",
  ]
}
