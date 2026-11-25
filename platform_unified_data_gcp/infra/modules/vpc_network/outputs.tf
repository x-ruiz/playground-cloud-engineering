output "vpc_id" {
  description = "ID of the custom-mode VPC network."
  value       = google_compute_network.this.id
}

output "vpc_name" {
  description = "Name of the custom-mode VPC network."
  value       = google_compute_network.this.name
}

output "subnet_id" {
  description = "ID of the primary regional subnetwork."
  value       = google_compute_subnetwork.primary.id
}

output "nat_enabled" {
  description = "Indicates whether Cloud Router and Cloud NAT were provisioned."
  value       = var.enable_cloud_nat
}
