include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "../../platform//."
}

inputs = {
  environment        = "prod"
  project_id         = get_env("UDP_GCP_PROD_PROJECT_ID", "udp-prod")
  project_name       = "UDP Prod"
  subnet_cidr        = "10.30.0.0/20"
  enable_cloud_nat   = false
  enable_flow_logs   = true
  monthly_budget_usd = 250
}
