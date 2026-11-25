output "platform_folder_id" {
  description = "Resource ID of the created Platform Folder (folders/<id>)."
  value       = google_folder.platform.name
}

output "seed_project_id" {
  description = "Created Seed GCP Project ID."
  value       = google_project.seed.project_id
}

output "state_bucket_name" {
  description = "GCS bucket name for OpenTofu remote state."
  value       = google_storage_bucket.state.name
}

output "kms_key_id" {
  description = "Fully qualified Cloud KMS CryptoKey ID for OpenTofu gcp_kms state encryption."
  value       = google_kms_crypto_key.state.id
}

output "wif_provider_name" {
  description = "Full WIF provider resource path for google-github-actions/auth."
  value       = google_iam_workload_identity_pool_provider.github.name
}

output "plan_service_account_email" {
  description = "Email address of the read-only sa-tofu-plan service account."
  value       = google_service_account.tofu_plan.email
}

output "apply_service_account_email" {
  description = "Email address of the main-only sa-tofu-apply service account."
  value       = google_service_account.tofu_apply.email
}
