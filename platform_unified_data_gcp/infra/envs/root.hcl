# Shared Terragrunt root for platform_unified_data_gcp environments (dev, uat, prod).
# Drives OpenTofu, reads upstream module tags from infra/module-versions.yaml and passes
# them as OpenTofu input variables (Early Variable Evaluation in module.source), and
# generates backend.tf, encryption.tf, and provider.tf.

terraform_binary = "tofu"

locals {
  offline_test     = get_env("UDP_GCP_OFFLINE_TEST", "false") == "true"
  region           = get_env("UDP_GCP_REGION", "us-central1")
  state_bucket     = local.offline_test ? "offline-placeholder-bucket" : get_env("UDP_GCP_STATE_BUCKET")
  state_kms_key_id = local.offline_test ? "offline-placeholder-kms-key" : get_env("UDP_GCP_STATE_KMS_KEY_ID")
  env_rel_path     = path_relative_to_include()

  module_versions = yamldecode(file("${get_parent_terragrunt_dir()}/../module-versions.yaml")).modules
}

generate "backend" {
  path      = "backend.tf"
  if_exists = "overwrite_terragrunt"
  disable   = local.offline_test
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
  disable   = local.offline_test
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
    provider "google" {
      region = "${local.region}"
    }

    provider "google-beta" {
      region = "${local.region}"
    }
  EOF
}

inputs = {
  cff_version             = local.module_versions["cloud-foundation-fabric"].version
  project_factory_version = local.module_versions["terraform-google-project-factory"].version
  platform_folder_id      = local.offline_test ? "folders/123456789012" : get_env("UDP_GCP_PLATFORM_FOLDER_ID")
  billing_account_id      = local.offline_test ? "01ABCD-23EFGH-45IJKL" : get_env("UDP_GCP_BILLING_ACCOUNT_ID")
  budget_alert_email      = local.offline_test ? "alerts@example.com" : get_env("UDP_GCP_BUDGET_ALERT_EMAIL")
  region                  = local.region
  platform_name           = "unified-data-platform"
  cost_center             = "engineering-playground"
  deletion_policy         = "PREVENT"
}
