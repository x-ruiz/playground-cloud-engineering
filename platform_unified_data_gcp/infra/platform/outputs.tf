output "project_id" {
  description = "Provisioned environment GCP Project ID (with random suffix)."
  value       = module.project.project_id
}

output "project_number" {
  description = "Provisioned numeric GCP Project number."
  value       = module.project.number
}

output "vpc_id" {
  description = "ID of the environment custom-mode VPC."
  value       = module.vpc.id
}

output "subnet_id" {
  description = "ID of the environment primary regional subnet."
  value       = module.vpc.subnet_ids[local.primary_subnet_key]
}

output "nat_enabled" {
  description = "Whether Cloud NAT is enabled in this environment."
  value       = var.enable_cloud_nat
}

output "budget_id" {
  description = "Resource name/ID of the environment Billing Budget."
  value       = module.budget.name
}

output "notification_channel_id" {
  description = "Resource ID of the Cloud Monitoring email notification channel."
  value       = google_monitoring_notification_channel.budget_email.id
}
