mock_provider "random" {
  mock_resource "random_id" {
    defaults = {
      hex = "c3d4"
    }
  }
}

mock_provider "google" {}

variables {
  project_id         = "udp-dev-test-001"
  project_name       = "UDP Dev Test"
  folder_id          = "folders/123456789012"
  billing_account_id = "01ABCD-23EFGH-45IJKL"
  environment        = "dev"
  activate_apis = [
    "compute.googleapis.com",
    "monitoring.googleapis.com",
  ]
  labels = {
    team       = "data-platform"
    managed_by = "attempt-override"
  }
}

# TC-003: Happy path — auto_create_network=false, PREVENT default, mandatory labels preserved, disable_on_destroy=false
run "happy_path_project_and_apis" {
  command = plan

  assert {
    condition     = google_project.this.project_id == "udp-dev-test-001-c3d4" && google_project.this.auto_create_network == false
    error_message = "Project ID must append 4-char hex suffix and disable default VPC auto-creation."
  }

  assert {
    condition     = google_project.this.deletion_policy == "PREVENT"
    error_message = "deletion_policy must default to PREVENT."
  }

  assert {
    condition     = google_project.this.folder_id == "123456789012"
    error_message = "folder_id must strip the folders/ prefix cleanly."
  }

  assert {
    condition     = google_project.this.labels["managed_by"] == "opentofu"
    error_message = "Mandatory managed_by label must not be overridable by callers."
  }

  assert {
    condition     = google_project.this.labels["platform"] == "unified-data-platform" && google_project.this.labels["environment"] == "dev" && google_project.this.labels["cost_center"] == "engineering-playground"
    error_message = "All mandatory governance labels must be present."
  }

  assert {
    condition     = google_project.this.labels["team"] == "data-platform"
    error_message = "Custom caller labels must be preserved alongside mandatory labels."
  }

  assert {
    condition     = length(google_project_service.apis) == 2 && alltrue([for s in values(google_project_service.apis) : s.disable_on_destroy == false])
    error_message = "All enabled APIs must enforce disable_on_destroy = false."
  }
}

# TC-004: Negative validation tests
run "reject_invalid_environment" {
  command = plan

  variables {
    environment = "qa"
  }

  expect_failures = [var.environment]
}

run "reject_malformed_billing_account" {
  command = plan

  variables {
    billing_account_id = "invalid-billing-id"
  }

  expect_failures = [var.billing_account_id]
}

run "reject_uppercase_project_id" {
  command = plan

  variables {
    project_id = "UDP-Dev-Invalid"
  }

  expect_failures = [var.project_id]
}

run "reject_invalid_deletion_policy" {
  command = plan

  variables {
    deletion_policy = "DESTROY_NOW"
  }

  expect_failures = [var.deletion_policy]
}
