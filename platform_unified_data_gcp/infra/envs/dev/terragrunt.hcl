include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

# dev tracks infra/platform on main HEAD for fast iteration.
terraform {
  source = "../../platform//."
}

inputs = {
  environment        = "dev"
  project_id         = get_env("UDP_GCP_DEV_PROJECT_ID", "udp-dev")
  project_name       = "UDP Dev"
  subnet_cidr        = "10.10.0.0/20"
  enable_cloud_nat   = false
  enable_flow_logs   = false
  monthly_budget_usd = 50
}
