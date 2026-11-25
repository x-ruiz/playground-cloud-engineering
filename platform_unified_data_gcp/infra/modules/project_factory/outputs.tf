output "project_id" {
  description = "Provisioned GCP Project ID."
  value       = google_project.this.project_id
}

output "project_number" {
  description = "Provisioned numeric GCP Project number."
  value       = google_project.this.number
}

output "enabled_apis" {
  description = "Set of activated GCP service APIs."
  value       = toset([for s in google_project_service.apis : s.service])
}
