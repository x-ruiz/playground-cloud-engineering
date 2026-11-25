# Phase 2 Bootstrap State Migration:
# After completing Phase 1 local `tofu apply`, uncomment this block and run:
#   tofu init -migrate-state -backend-config="bucket=<state_bucket_name>"
#
# terraform {
#   backend "gcs" {
#     prefix = "bootstrap"
#   }
# }
