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

# Spec 04 §4.5: shared lakehouse outputs consumed by infra/domains (Spec 05) and sdk-lakehouse.
output "catalog_root_bucket_name" {
  description = "Catalog root bucket name (default_location anchor; holds no data)."
  value       = module.catalog_root_bucket.name
}

output "catalog_root_bucket_uri" {
  description = "Catalog root bucket URI used as the BigLake catalog default_location."
  value       = "gs://${module.catalog_root_bucket.name}"
}

output "biglake_catalog_name" {
  description = "Env-agnostic BigLake Iceberg REST catalog name."
  value       = google_biglake_iceberg_catalog.bronze.name
}

output "biglake_warehouse_uri" {
  description = "sdk-lakehouse warehouse URI for the Bronze catalog."
  value       = "bl://projects/${module.project.project_id}/catalogs/${google_biglake_iceberg_catalog.bronze.name}"
}

output "biglake_rest_uri" {
  description = "BigLake Iceberg REST catalog endpoint."
  value       = "https://biglake.googleapis.com/iceberg/v1/restcatalog"
}

output "biglake_service_account" {
  description = "Google-managed BigLake service account used for vended credentials (granted on domain buckets in Spec 05)."
  value       = google_biglake_iceberg_catalog.bronze.biglake_service_account
}

output "bigquery_connection_id" {
  description = "Regional BigQuery Cloud Resource connection ID (projects/<project>/locations/<region>/connections/<id>)."
  value       = google_bigquery_connection.bronze.id
}

output "bigquery_connection_sa" {
  description = "Google-managed BigQuery connection service account (granted on domain buckets in Spec 05)."
  value       = google_bigquery_connection.bronze.cloud_resource[0].service_account_id
}
