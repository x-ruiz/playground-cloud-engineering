include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

locals {
  # Immutable platform release pin, managed by .github/workflows/udp-gcp-promote.yml.
  platform_version = yamldecode(file("${get_terragrunt_dir()}/release.yaml")).platform_version
}

# prod is isolated from main HEAD: it only ever deploys the tagged infra/platform release
# pinned in release.yaml. The local relative path is used solely for offline validate/tests.
terraform {
  source = include.root.locals.offline_test ? "../../platform//." : "${include.root.locals.platform_git_source}?ref=${local.platform_version}"
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
