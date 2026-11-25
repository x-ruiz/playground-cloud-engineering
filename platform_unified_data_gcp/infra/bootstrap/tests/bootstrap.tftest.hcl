mock_provider "random" {
  mock_resource "random_id" {
    defaults = {
      hex = "a1b2"
    }
  }
}

mock_provider "github" {}

mock_provider "google" {
  mock_resource "google_folder" {
    defaults = {
      name      = "folders/123456789012"
      folder_id = "123456789012"
    }
  }

  mock_resource "google_iam_workload_identity_pool" {
    defaults = {
      name = "projects/111111111111/locations/global/workloadIdentityPools/github-actions-pool"
    }
  }

  mock_resource "google_service_account" {
    defaults = {
      name  = "projects/udp-seed-test-001/serviceAccounts/sa-tofu-mock@udp-seed-test-001.iam.gserviceaccount.com"
      email = "sa-tofu-mock@udp-seed-test-001.iam.gserviceaccount.com"
    }
  }

  mock_resource "google_kms_crypto_key" {
    defaults = {
      id = "projects/udp-seed-test-001/locations/us-central1/keyRings/unified-data-platform-tofu-state/cryptoKeys/tofu-state-key"
    }
  }
}

variables {
  org_id             = "999888777666"
  billing_account_id = "01ABCD-23EFGH-45IJKL"
  github_repository  = "x-ruiz/playground-cloud-engineering"
  seed_project_id    = "udp-seed-test-001"
  dev_project_id     = "udp-dev-test-001"
  budget_alert_email = "alerts@example.com"
  state_kms_key_id   = "projects/udp-seed-test-001/locations/us-central1/keyRings/unified-data-platform-tofu-state/cryptoKeys/tofu-state-key"
}

# TC-009: Bootstrap hardening, WIF least privilege, and Folder-scoped IAM invariants
run "bootstrap_hardening_and_wif_invariants" {
  command = plan

  assert {
    condition     = google_folder.platform.parent == "organizations/999888777666" && google_folder.platform.deletion_protection == true
    error_message = "Platform folder must sit under org_id with deletion_protection enabled."
  }

  assert {
    condition     = google_project.seed.project_id == "udp-seed-test-001-a1b2" && google_project.seed.auto_create_network == false && google_project.seed.deletion_policy == "PREVENT"
    error_message = "Seed project must append 4-char hex suffix, disable auto_create_network, and enforce deletion_policy = PREVENT."
  }

  assert {
    condition     = google_storage_bucket.state.uniform_bucket_level_access == true && google_storage_bucket.state.public_access_prevention == "enforced" && google_storage_bucket.state.force_destroy == false && google_storage_bucket.state.versioning[0].enabled == true
    error_message = "State bucket must enforce UBLA, PAP, versioning, and force_destroy = false."
  }

  assert {
    condition     = google_kms_crypto_key.state.rotation_period == "7776000s"
    error_message = "Cloud KMS state encryption key must configure 90-day automatic rotation."
  }

  assert {
    condition     = google_iam_workload_identity_pool_provider.github.attribute_condition == "assertion.repository == 'x-ruiz/playground-cloud-engineering'"
    error_message = "WIF OIDC provider must restrict federation strictly to github_repository."
  }

  assert {
    condition     = endswith(google_service_account_iam_member.wif_apply.member, "/attribute.repository_ref/x-ruiz/playground-cloud-engineering:refs/heads/main")
    error_message = "sa-tofu-apply WIF binding must be restricted strictly to refs/heads/main."
  }

  assert {
    condition     = google_storage_bucket_iam_member.plan_state_viewer.role == "roles/storage.objectViewer" && google_storage_bucket_iam_member.plan_state_lock.condition[0].expression == "resource.name.endsWith(\".tflock\")" && google_kms_crypto_key_iam_member.plan_kms_decrypter.role == "roles/cloudkms.cryptoKeyEncrypterDecrypter"
    error_message = "sa-tofu-plan must have read-only GCS objectViewer, .tflock-only conditional lock permission, and KMS encrypter/decrypter."
  }

  assert {
    condition     = length(github_actions_variable.udp_gcp) == 9 && github_actions_variable.udp_gcp["UDP_GCP_DEV_PROJECT_ID"].repository == "playground-cloud-engineering" && github_actions_variable.udp_gcp["UDP_GCP_DEV_PROJECT_ID"].value == "udp-dev-test-001" && github_actions_variable.udp_gcp["UDP_GCP_BUDGET_ALERT_EMAIL"].value == "alerts@example.com"
    error_message = "Bootstrap must declaratively manage all 9 UDP_GCP_* GitHub Actions repository variables."
  }
}

run "reject_non_numeric_org_id" {
  command = plan

  variables {
    org_id = "org-invalid"
  }

  expect_failures = [var.org_id]
}
