include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "../../platform//."
}

inputs = {
  environment        = "uat"
  project_id         = get_env("UDP_GCP_UAT_PROJECT_ID", "udp-uat")
  project_name       = "UDP UAT"
  subnet_cidr        = "10.20.0.0/20"
  enable_cloud_nat   = false
  enable_flow_logs   = false
  monthly_budget_usd = 100
}
