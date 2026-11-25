variable "org_id" {
  description = "Numeric GCP Organization ID under which the Platform Folder will be created."
  type        = string

  validation {
    condition     = can(regex("^[0-9]+$", var.org_id))
    error_message = "org_id must be a numeric GCP Organization ID (digits only)."
  }
}

variable "billing_account_id" {
  description = "GCP Billing Account ID in XXXXXX-XXXXXX-XXXXXX format."
  type        = string

  validation {
    condition     = can(regex("^[A-Z0-9]{6}-[A-Z0-9]{6}-[A-Z0-9]{6}$", var.billing_account_id))
    error_message = "billing_account_id must match the format XXXXXX-XXXXXX-XXXXXX."
  }
}

variable "github_repository" {
  description = "GitHub repository in owner/repo format authorized via WIF (e.g., x-ruiz/playground-cloud-engineering)."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", var.github_repository))
    error_message = "github_repository must be in owner/repo format."
  }
}

variable "platform_name" {
  description = "Lowercase slug used for Platform Folder display naming, labels, and resource prefixes."
  type        = string
  default     = "unified-data-platform"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,28}[a-z0-9]$", var.platform_name))
    error_message = "platform_name must be 4-30 lowercase alphanumeric characters or hyphens, starting with a letter and ending with a letter or digit."
  }
}

variable "seed_project_id" {
  description = "Base GCP Project ID prefix for the bootstrap Seed project (a random 4-char hex suffix -xxxx is appended automatically)."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,23}[a-z0-9]$", var.seed_project_id))
    error_message = "seed_project_id must be 4-25 lowercase letters, digits, or hyphens (leaving room for the -xxxx random suffix within GCP's 30-char limit)."
  }
}

variable "dev_project_id" {
  description = "Base GCP Project ID prefix for envs/dev (synced declaratively to GitHub Actions variable UDP_GCP_DEV_PROJECT_ID)."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,23}[a-z0-9]$", var.dev_project_id))
    error_message = "dev_project_id must be 4-25 lowercase letters, digits, or hyphens (leaving room for the -xxxx random suffix within GCP's 30-char limit)."
  }
}

variable "budget_alert_email" {
  description = "Email address for dev Billing Budget alerts (synced declaratively to GitHub Actions variable UDP_GCP_BUDGET_ALERT_EMAIL)."
  type        = string

  validation {
    condition     = can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.budget_alert_email))
    error_message = "budget_alert_email must be a valid email address."
  }
}

variable "region" {
  description = "Primary GCP region for the Seed remote state bucket and Cloud KMS KeyRing."
  type        = string
  default     = "us-central1"

  validation {
    condition     = can(regex("^[a-z]+-[a-z]+[0-9]+$", var.region))
    error_message = "region must be a valid GCP region identifier (e.g., us-central1)."
  }
}

variable "cost_center" {
  description = "Cost center label applied to all Seed platform resources."
  type        = string
  default     = "engineering-playground"

  validation {
    condition     = can(regex("^[a-z][a-z0-9_-]{1,61}[a-z0-9]$", var.cost_center))
    error_message = "cost_center must be a valid lowercase GCP label value."
  }
}

variable "state_kms_key_id" {
  description = "Cloud KMS CryptoKey ID used by OpenTofu gcp_kms state encryption."
  type        = string
}

