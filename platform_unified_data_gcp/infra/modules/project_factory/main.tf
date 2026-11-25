locals {
  normalized_folder_id = trimprefix(var.folder_id, "folders/")

  mandatory_labels = {
    managed_by  = "opentofu"
    platform    = var.platform_name
    environment = var.environment
    cost_center = var.cost_center
  }

  # Mandatory labels are merged last so callers cannot drop or override governance invariants.
  merged_labels = merge(var.labels, local.mandatory_labels)
}

resource "random_id" "project_suffix" {
  byte_length = 2
}

resource "google_project" "this" {
  name                = var.project_name
  project_id          = "${var.project_id}-${random_id.project_suffix.hex}"
  folder_id           = local.normalized_folder_id
  billing_account     = var.billing_account_id
  auto_create_network = false
  deletion_policy     = var.deletion_policy
  labels              = local.merged_labels
}

resource "google_project_service" "apis" {
  for_each = var.activate_apis

  project            = google_project.this.project_id
  service            = each.value
  disable_on_destroy = false
}
