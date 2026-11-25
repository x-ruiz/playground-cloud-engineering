output "budget_id" {
  description = "Resource ID of the GCP Billing Budget."
  value       = google_billing_budget.this.id
}

output "notification_channel_id" {
  description = "Resource ID of the Cloud Monitoring email notification channel."
  value       = google_monitoring_notification_channel.budget_email.id
}
