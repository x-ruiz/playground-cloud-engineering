locals {
  github_repo_name = split("/", var.github_repository)[1]

  github_actions_variables = {
    UDP_GCP_WIF_PROVIDER       = google_iam_workload_identity_pool_provider.github.name
    UDP_GCP_PLAN_SA            = google_service_account.tofu_plan.email
    UDP_GCP_APPLY_SA           = google_service_account.tofu_apply.email
    UDP_GCP_STATE_BUCKET       = google_storage_bucket.state.name
    UDP_GCP_STATE_KMS_KEY_ID   = google_kms_crypto_key.state.id
    UDP_GCP_PLATFORM_FOLDER_ID = google_folder.platform.name
    UDP_GCP_BILLING_ACCOUNT_ID = var.billing_account_id
    UDP_GCP_DEV_PROJECT_ID     = var.dev_project_id
    UDP_GCP_BUDGET_ALERT_EMAIL = var.budget_alert_email
  }
}

resource "github_actions_variable" "udp_gcp" {
  for_each = local.github_actions_variables

  repository    = local.github_repo_name
  variable_name = each.key
  value         = each.value
}
