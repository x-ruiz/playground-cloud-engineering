locals {
  mandatory_labels = {
    managed_by  = "opentofu"
    platform    = var.platform_name
    environment = "seed"
    cost_center = var.cost_center
  }

  bootstrap_apis = toset([
    "cloudresourcemanager.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "sts.googleapis.com",
    "serviceusage.googleapis.com",
    "cloudbilling.googleapis.com",
    "storage.googleapis.com",
    "cloudkms.googleapis.com",
    "billingbudgets.googleapis.com",
    "monitoring.googleapis.com",
  ])
}

resource "random_id" "seed_project_suffix" {
  byte_length = 2
}

resource "google_folder" "platform" {
  display_name        = var.platform_name
  parent              = "organizations/${var.org_id}"
  deletion_protection = true
}

resource "google_project" "seed" {
  name                = "UDP Seed"
  project_id          = "${var.seed_project_id}-${random_id.seed_project_suffix.hex}"
  folder_id           = google_folder.platform.folder_id
  billing_account     = var.billing_account_id
  auto_create_network = false
  deletion_policy     = "PREVENT"
  labels              = local.mandatory_labels
}

resource "google_project_service" "seed_apis" {
  for_each = local.bootstrap_apis

  project            = google_project.seed.project_id
  service            = each.value
  disable_on_destroy = false
}

resource "google_storage_bucket" "state" {
  name                        = "${google_project.seed.project_id}-tofu-state"
  project                     = google_project.seed.project_id
  location                    = var.region
  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = false
  labels                      = local.mandatory_labels

  versioning {
    enabled = true
  }

  lifecycle_rule {
    condition {
      num_newer_versions = 10
      with_state         = "ARCHIVED"
    }
    action {
      type = "Delete"
    }
  }

  lifecycle_rule {
    condition {
      days_since_noncurrent_time = 30
    }
    action {
      type = "Delete"
    }
  }

  lifecycle {
    prevent_destroy = true
  }

  depends_on = [google_project_service.seed_apis]
}

resource "google_kms_key_ring" "state" {
  name     = "${var.platform_name}-tofu-state"
  project  = google_project.seed.project_id
  location = var.region

  depends_on = [google_project_service.seed_apis]
}

resource "google_kms_crypto_key" "state" {
  name            = "tofu-state-key"
  key_ring        = google_kms_key_ring.state.id
  purpose         = "ENCRYPT_DECRYPT"
  rotation_period = "7776000s"
  labels          = local.mandatory_labels

  lifecycle {
    prevent_destroy = true
  }
}
