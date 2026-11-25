# Phase 2 Bootstrap State Encryption:
# After Phase 1 creates the Cloud KMS CryptoKey, uncomment this block together with
# backend.tf, export TF_VAR_state_kms_key_id="<kms_key_id>", and run:
#   tofu init -migrate-state -backend-config="bucket=<state_bucket_name>"
#
# Once the migrated state in GCS is verified as encrypted ciphertext, REMOVE the
# `method "unencrypted" "migrate"` and `fallback` blocks so plaintext state is rejected.
#
# variable "state_kms_key_id" {
#   description = "Cloud KMS CryptoKey ID created in Phase 1 for OpenTofu state encryption."
#   type        = string
# }
#
# terraform {
#   encryption {
#     key_provider "gcp_kms" "state" {
#       kms_encryption_key = var.state_kms_key_id
#       key_length         = 32
#     }
#
#     method "aes_gcm" "state" {
#       keys = key_provider.gcp_kms.state
#     }
#
#     # Temporary migration fallback — remove immediately after verifying encrypted GCS state.
#     method "unencrypted" "migrate" {}
#
#     state {
#       method   = method.aes_gcm.state
#       enforced = true
#       fallback {
#         method = method.unencrypted.migrate
#       }
#     }
#   }
# }
