mock_provider "random" {
  mock_resource "random_id" {
    defaults = {
      hex = "e5f6"
    }
  }
}

mock_provider "google" {
  mock_resource "google_project" {
    defaults = {
      number = "987654321098"
    }
  }

  mock_data "google_project" {
    defaults = {
      number = "987654321098"
    }
  }
}

mock_provider "google-beta" {
  mock_resource "google_project" {
    defaults = {
      number = "987654321098"
    }
  }

  mock_data "google_project" {
    defaults = {
      number = "987654321098"
    }
  }
}

variables {
  cff_version             = "v60.0.0"
  project_factory_version = "v18.4.0"
  environment             = "dev"
  platform_folder_id      = "folders/123456789012"
  billing_account_id      = "01ABCD-23EFGH-45IJKL"
  project_id              = "udp-dev-test"
  project_name            = "UDP Dev"
  region                  = "us-central1"
  subnet_cidr             = "10.10.0.0/20"
  monthly_budget_usd      = 50
  budget_alert_email      = "alerts@example.com"
}

# TC-004 (dev): Default $0/mo baseline with tag-pinned upstream CFF & PF budget modules
run "dev_platform_composition" {
  command = plan

  assert {
    condition     = module.project.project_id == "udp-dev-test-e5f6"
    error_message = "Dev platform must append 4-char hex suffix to project_id."
  }

  assert {
    condition     = module.vpc.name == "udp-dev-vpc" && length(module.cloud_nat) == 0 && output.nat_enabled == false
    error_message = "Dev platform must create udp-dev-vpc with 0 Cloud NAT modules when enable_cloud_nat is false."
  }

  assert {
    condition     = google_monitoring_notification_channel.budget_email.labels["email_address"] == "alerts@example.com"
    error_message = "Monitoring email channel must target var.budget_alert_email."
  }
}

# TC-004 (uat): Parameterized UAT composition
run "uat_platform_composition" {
  command = plan

  variables {
    environment        = "uat"
    project_id         = "udp-uat-test"
    project_name       = "UDP UAT"
    subnet_cidr        = "10.20.0.0/20"
    monthly_budget_usd = 100
  }

  assert {
    condition     = module.project.project_id == "udp-uat-test-e5f6" && module.vpc.name == "udp-uat-vpc" && length(module.cloud_nat) == 0
    error_message = "UAT platform must wire environment = uat across upstream modules."
  }
}

# TC-004 (prod + opt-in NAT): Parameterized Prod composition with flow logs and Cloud NAT
run "prod_platform_with_opt_in_nat" {
  command = plan

  variables {
    environment        = "prod"
    project_id         = "udp-prod-test"
    project_name       = "UDP Prod"
    subnet_cidr        = "10.30.0.0/20"
    enable_flow_logs   = true
    enable_cloud_nat   = true
    monthly_budget_usd = 250
  }

  assert {
    condition     = module.project.project_id == "udp-prod-test-e5f6" && module.vpc.name == "udp-prod-vpc" && length(module.cloud_nat) == 1 && output.nat_enabled == true
    error_message = "Prod platform must enable Cloud NAT when enable_cloud_nat is true."
  }
}

# TC-004 (negative): Reject unsupported environment enum, invalid CIDR, and zero budget
run "reject_invalid_environment" {
  command = plan

  variables {
    environment = "staging"
  }

  expect_failures = [var.environment]
}

run "reject_invalid_cidr" {
  command = plan

  variables {
    subnet_cidr = "not-a-cidr"
  }

  expect_failures = [var.subnet_cidr]
}

run "reject_zero_budget" {
  command = plan

  variables {
    monthly_budget_usd = 0
  }

  expect_failures = [var.monthly_budget_usd]
}
