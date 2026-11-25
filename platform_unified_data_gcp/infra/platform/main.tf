locals {
  # Upstream module repositories & release tags (OpenTofu 1.8+ Early Evaluation in module.source).
  # Sourced from module-versions.yaml so they freeze atomically inside each udp-gcp-vX.Y.Z tag.
  module_versions         = yamldecode(file("${path.module}/module-versions.yaml")).modules
  cff_repository          = local.module_versions["cloud-foundation-fabric"].repository
  cff_version             = local.module_versions["cloud-foundation-fabric"].version
  project_factory_repo    = local.module_versions["terraform-google-project-factory"].repository
  project_factory_version = local.module_versions["terraform-google-project-factory"].version

  normalized_parent = startswith(var.platform_folder_id, "folders/") ? var.platform_folder_id : "folders/${var.platform_folder_id}"

  mandatory_labels = {
    managed_by  = "opentofu"
    platform    = var.platform_name
    environment = var.environment
    cost_center = var.cost_center
  }

  platform_apis = [
    "compute.googleapis.com",
    "iam.googleapis.com",
    "serviceusage.googleapis.com",
    "monitoring.googleapis.com",
    "billingbudgets.googleapis.com",
  ]

  vpc_name            = "udp-${var.environment}-vpc"
  primary_subnet_name = "${local.vpc_name}-${var.region}-primary"
  primary_subnet_key  = "${var.region}/${local.primary_subnet_name}"
}

resource "random_id" "project_suffix" {
  byte_length = 2
}

module "project" {
  source = "git::${local.cff_repository}//modules/project?ref=${local.cff_version}"

  name                = "${var.project_id}-${random_id.project_suffix.hex}"
  descriptive_name    = var.project_name
  parent              = local.normalized_parent
  billing_account     = var.billing_account_id
  auto_create_network = false
  deletion_policy     = var.deletion_policy
  labels              = local.mandatory_labels
  services            = local.platform_apis

  service_config = {
    disable_on_destroy         = false
    disable_dependent_services = false
  }
}

module "vpc" {
  source = "git::${local.cff_repository}//modules/net-vpc?ref=${local.cff_version}"

  project_id              = module.project.project_id
  name                    = local.vpc_name
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"

  subnets = [
    {
      name                  = local.primary_subnet_name
      region                = var.region
      ip_cidr_range         = var.subnet_cidr
      enable_private_access = true
      flow_logs_config = var.enable_flow_logs ? {
        aggregation_interval = "INTERVAL_5_SEC"
        flow_sampling        = 0.5
        metadata             = "INCLUDE_ALL_METADATA"
      } : null
    }
  ]

  depends_on = [module.project]
}

module "firewall" {
  source = "git::${local.cff_repository}//modules/net-vpc-firewall?ref=${local.cff_version}"

  project_id = module.project.project_id
  network    = module.vpc.name

  default_rules_config = {
    disabled = true
  }

  ingress_rules = {
    "${local.vpc_name}-allow-iap-ssh" = {
      description   = "Allow SSH via Google Identity-Aware Proxy (35.235.240.0/20) to tagged instances."
      priority      = 1000
      source_ranges = ["35.235.240.0/20"]
      targets       = var.iap_ssh_target_tags
      rules = [
        {
          protocol = "tcp"
          ports    = ["22"]
        }
      ]
    }

    "${local.vpc_name}-allow-internal" = {
      description   = "Allow internal TCP, UDP, and ICMP traffic within the primary subnet."
      priority      = 1000
      source_ranges = [var.subnet_cidr]
      rules = [
        { protocol = "tcp" },
        { protocol = "udp" },
        { protocol = "icmp" },
      ]
    }

    "${local.vpc_name}-deny-all-ingress" = {
      deny          = true
      description   = "Explicit fallback deny rule for unmatched ingress traffic."
      priority      = 65534
      source_ranges = ["0.0.0.0/0"]
      rules = [
        { protocol = "all" }
      ]
    }
  }

  depends_on = [module.vpc]
}

module "cloud_nat" {
  source = "git::${local.cff_repository}//modules/net-cloudnat?ref=${local.cff_version}"
  count  = var.enable_cloud_nat ? 1 : 0

  project_id     = module.project.project_id
  region         = var.region
  name           = "${local.vpc_name}-${var.region}-nat"
  router_name    = "${local.vpc_name}-${var.region}-router"
  router_network = module.vpc.name
  logging_filter = "ERRORS_ONLY"

  depends_on = [module.vpc]
}

resource "google_monitoring_notification_channel" "budget_email" {
  project      = module.project.project_id
  display_name = "udp-${var.environment}-monthly-budget Email"
  type         = "email"

  labels = {
    email_address = var.budget_alert_email
  }

  depends_on = [module.project]
}

module "budget" {
  source = "git::${local.project_factory_repo}//modules/budget?ref=${local.project_factory_version}"

  billing_account      = var.billing_account_id
  projects             = [module.project.project_id]
  display_name         = "udp-${var.environment}-monthly-budget"
  amount               = var.monthly_budget_usd
  alert_spent_percents = [0.5, 0.8, 1.0]
  alert_spend_basis    = "CURRENT_SPEND"

  monitoring_notification_channels = [
    google_monitoring_notification_channel.budget_email.id,
  ]

  depends_on = [module.project]
}
