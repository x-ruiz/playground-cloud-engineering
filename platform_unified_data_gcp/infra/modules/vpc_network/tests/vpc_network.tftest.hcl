mock_provider "google" {}

variables {
  project_id   = "udp-dev-test-001"
  network_name = "udp-dev-vpc"
  region       = "us-central1"
  subnet_cidr  = "10.10.0.0/20"
}

# TC-005: Default $0/mo VPC baseline (no Cloud Router / Cloud NAT, Private Google Access enabled)
run "default_zero_cost_vpc_baseline" {
  command = plan

  assert {
    condition     = google_compute_network.this.auto_create_subnetworks == false
    error_message = "VPC must be custom-mode (auto_create_subnetworks = false)."
  }

  assert {
    condition     = google_compute_subnetwork.primary.private_ip_google_access == true
    error_message = "Primary subnet must enable Private Google Access."
  }

  assert {
    condition     = contains(google_compute_firewall.allow_iap_ssh.source_ranges, "35.235.240.0/20")
    error_message = "IAP SSH firewall must restrict source_ranges to 35.235.240.0/20."
  }

  assert {
    condition     = google_compute_firewall.deny_all_ingress.priority == 65534
    error_message = "Explicit deny-all-ingress fallback rule must be configured at priority 65534."
  }

  assert {
    condition     = length(google_compute_router.nat) == 0 && length(google_compute_router_nat.this) == 0
    error_message = "Cloud Router and Cloud NAT must NOT be created when enable_cloud_nat is false."
  }

  assert {
    condition     = output.nat_enabled == false
    error_message = "nat_enabled output must be false by default."
  }
}

# TC-006 (positive): Opt-in Cloud NAT creates Router + NAT
run "opt_in_cloud_nat_provisions_router_and_nat" {
  command = plan

  variables {
    enable_cloud_nat = true
    enable_flow_logs = true
  }

  assert {
    condition     = length(google_compute_router.nat) == 1 && length(google_compute_router_nat.this) == 1
    error_message = "Enabling enable_cloud_nat must provision exactly one Cloud Router and one Cloud NAT."
  }

  assert {
    condition     = output.nat_enabled == true
    error_message = "nat_enabled output must reflect true when enabled."
  }
}

# TC-006 (negative): Invalid subnet CIDR rejected
run "reject_invalid_subnet_cidr" {
  command = plan

  variables {
    subnet_cidr = "not-a-cidr"
  }

  expect_failures = [var.subnet_cidr]
}
