locals {
  plan_folder_roles = toset([
    "roles/viewer",
    "roles/iam.securityReviewer",
  ])

  apply_folder_roles = toset([
    "roles/resourcemanager.projectCreator",
    "roles/resourcemanager.projectDeleter",
    "roles/resourcemanager.projectIamAdmin",
    "roles/compute.networkAdmin",
    "roles/serviceusage.serviceUsageAdmin",
    "roles/monitoring.notificationChannelEditor",
  ])

  apply_billing_roles = toset([
    "roles/billing.user",
    "roles/billing.costsManager",
  ])
}

resource "google_iam_workload_identity_pool" "github" {
  project                   = google_project.seed.project_id
  workload_identity_pool_id = "github-actions-pool"
  display_name              = "GitHub Actions Pool"
  description               = "Workload Identity Pool for keyless GitHub Actions OpenTofu GitOps."

  depends_on = [google_project_service.seed_apis]
}

resource "google_iam_workload_identity_pool_provider" "github" {
  project                            = google_project.seed.project_id
  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = "github-oidc"
  display_name                       = "GitHub OIDC Provider"
  description                        = "OIDC provider restricted strictly to ${var.github_repository}."

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }

  attribute_mapping = {
    "google.subject"           = "assertion.sub"
    "attribute.actor"          = "assertion.actor"
    "attribute.repository"     = "assertion.repository"
    "attribute.ref"            = "assertion.ref"
    "attribute.repository_ref" = "assertion.repository + ':' + assertion.ref"
  }

  attribute_condition = "assertion.repository == '${var.github_repository}'"
}

resource "google_service_account" "tofu_plan" {
  project      = google_project.seed.project_id
  account_id   = "sa-tofu-plan"
  display_name = "OpenTofu PR Plan (Read-Only)"
  description  = "Read-only CI service account for GitHub Actions PR plan checks."

  depends_on = [google_project_service.seed_apis]
}

resource "google_service_account" "tofu_apply" {
  project      = google_project.seed.project_id
  account_id   = "sa-tofu-apply"
  display_name = "OpenTofu Main Apply"
  description  = "Provisioning CI service account restricted strictly to refs/heads/main."

  depends_on = [google_project_service.seed_apis]
}

# WIF binding: PRs/branches in var.github_repository can impersonate sa-tofu-plan.
resource "google_service_account_iam_member" "wif_plan" {
  service_account_id = google_service_account.tofu_plan.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.repository/${var.github_repository}"
}

# WIF binding: ONLY refs/heads/main in var.github_repository can impersonate sa-tofu-apply.
resource "google_service_account_iam_member" "wif_apply" {
  service_account_id = google_service_account.tofu_apply.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.repository_ref/${var.github_repository}:refs/heads/main"
}

# --- Read-Only Plan SA IAM (Platform Folder, State Bucket, KMS Key) ---

resource "google_folder_iam_member" "plan_folder_roles" {
  for_each = local.plan_folder_roles

  folder = google_folder.platform.name
  role   = each.value
  member = "serviceAccount:${google_service_account.tofu_plan.email}"
}

resource "google_storage_bucket_iam_member" "plan_state_viewer" {
  bucket = google_storage_bucket.state.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.tofu_plan.email}"
}

# Allow sa-tofu-plan to create/release .tflock lock objects during `tofu init` while
# strictly blocking any write/delete on .tfstate objects.
resource "google_storage_bucket_iam_member" "plan_state_lock" {
  bucket = google_storage_bucket.state.name
  role   = "roles/storage.objectUser"
  member = "serviceAccount:${google_service_account.tofu_plan.email}"

  condition {
    title       = "AllowTflockOnly"
    description = "Permit lockfile creation/deletion (*.tflock) without granting write access to *.tfstate."
    expression  = "resource.name.endsWith(\".tflock\")"
  }
}

# OpenTofu's gcp_kms key_provider wraps a fresh data key during init even on read-only plan.
# sa-tofu-plan remains strictly read-only via roles/storage.objectViewer (GCS) and roles/viewer (Folder).
resource "google_kms_crypto_key_iam_member" "plan_kms_decrypter" {
  crypto_key_id = google_kms_crypto_key.state.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:${google_service_account.tofu_plan.email}"
}

# --- Main-Only Apply SA IAM (Platform Folder, Billing Account, State Bucket, KMS Key) ---

resource "google_folder_iam_member" "apply_folder_roles" {
  for_each = local.apply_folder_roles

  folder = google_folder.platform.name
  role   = each.value
  member = "serviceAccount:${google_service_account.tofu_apply.email}"
}

resource "google_billing_account_iam_member" "apply_billing_roles" {
  for_each = local.apply_billing_roles

  billing_account_id = var.billing_account_id
  role               = each.value
  member             = "serviceAccount:${google_service_account.tofu_apply.email}"
}

resource "google_storage_bucket_iam_member" "apply_state_user" {
  bucket = google_storage_bucket.state.name
  role   = "roles/storage.objectUser"
  member = "serviceAccount:${google_service_account.tofu_apply.email}"
}

resource "google_kms_crypto_key_iam_member" "apply_kms_encrypter_decrypter" {
  crypto_key_id = google_kms_crypto_key.state.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:${google_service_account.tofu_apply.email}"
}
