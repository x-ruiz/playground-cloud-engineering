# Cloud KMS client-side state encryption for bootstrap (enforced — plaintext state rejected).

terraform {
  encryption {
    key_provider "gcp_kms" "state" {
      kms_encryption_key = var.state_kms_key_id
      key_length         = 32
    }

    method "aes_gcm" "state" {
      keys = key_provider.gcp_kms.state
    }

    state {
      method   = method.aes_gcm.state
      enforced = true
    }

    plan {
      method   = method.aes_gcm.state
      enforced = true
    }
  }
}
