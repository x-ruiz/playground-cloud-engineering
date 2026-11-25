resource "google_compute_network" "this" {
  name                            = var.network_name
  project                         = var.project_id
  auto_create_subnetworks         = false
  routing_mode                    = "REGIONAL"
  delete_default_routes_on_create = false
}

resource "google_compute_subnetwork" "primary" {
  name                     = "${var.network_name}-${var.region}-primary"
  project                  = var.project_id
  region                   = var.region
  network                  = google_compute_network.this.id
  ip_cidr_range            = var.subnet_cidr
  private_ip_google_access = true

  dynamic "log_config" {
    for_each = var.enable_flow_logs ? [1] : []
    content {
      aggregation_interval = "INTERVAL_5_SEC"
      flow_sampling        = 0.5
      metadata             = "INCLUDE_ALL_METADATA"
    }
  }
}

# Allow SSH strictly from Google Identity-Aware Proxy (IAP) — zero public IPs required.
resource "google_compute_firewall" "allow_iap_ssh" {
  name        = "${var.network_name}-allow-iap-ssh"
  project     = var.project_id
  network     = google_compute_network.this.id
  description = "Allow SSH via Google Identity-Aware Proxy (35.235.240.0/20) to tagged instances."
  direction   = "INGRESS"
  priority    = 1000

  source_ranges = ["35.235.240.0/20"]
  target_tags   = var.iap_ssh_target_tags

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
}

# Allow intra-subnet private communication.
resource "google_compute_firewall" "allow_internal" {
  name        = "${var.network_name}-allow-internal"
  project     = var.project_id
  network     = google_compute_network.this.id
  description = "Allow internal TCP, UDP, and ICMP traffic within the primary subnet."
  direction   = "INGRESS"
  priority    = 1000

  source_ranges = [var.subnet_cidr]

  allow {
    protocol = "tcp"
  }

  allow {
    protocol = "udp"
  }

  allow {
    protocol = "icmp"
  }
}

# Explicit low-priority deny-all-ingress rule for defense in depth and audit visibility.
resource "google_compute_firewall" "deny_all_ingress" {
  name        = "${var.network_name}-deny-all-ingress"
  project     = var.project_id
  network     = google_compute_network.this.id
  description = "Explicit fallback deny rule for unmatched ingress traffic."
  direction   = "INGRESS"
  priority    = 65534

  source_ranges = ["0.0.0.0/0"]

  deny {
    protocol = "all"
  }
}

resource "google_compute_router" "nat" {
  count = var.enable_cloud_nat ? 1 : 0

  name    = "${var.network_name}-${var.region}-router"
  project = var.project_id
  region  = var.region
  network = google_compute_network.this.id
}

resource "google_compute_router_nat" "this" {
  count = var.enable_cloud_nat ? 1 : 0

  name                               = "${var.network_name}-${var.region}-nat"
  project                            = var.project_id
  region                             = var.region
  router                             = google_compute_router.nat[0].name
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}
