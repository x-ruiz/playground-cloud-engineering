variable "environment" {
  description = "Deployment environment (dev, uat, or prod)."
  type        = string

  validation {
    condition     = contains(["dev", "uat", "prod"], var.environment)
    error_message = "environment must be one of: dev, uat, prod."
  }
}

variable "platform_folder_id" {
  description = "Platform Folder ID output from bootstrap (folders/<id> or numeric ID)."
  type        = string

  validation {
    condition     = can(regex("^(folders/)?[0-9]+$", var.platform_folder_id))
    error_message = "platform_folder_id must be a numeric folder ID or folders/<numeric-id>."
  }
}

variable "billing_account_id" {
  description = "GCP Billing Account ID in XXXXXX-XXXXXX-XXXXXX format."
  type        = string

  validation {
    condition     = can(regex("^[A-Z0-9]{6}-[A-Z0-9]{6}-[A-Z0-9]{6}$", var.billing_account_id))
    error_message = "billing_account_id must match XXXXXX-XXXXXX-XXXXXX."
  }
}

variable "project_id" {
  description = "Base GCP Project ID prefix for this environment (project_factory appends -xxxx)."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,23}[a-z0-9]$", var.project_id))
    error_message = "project_id must be 4-25 lowercase letters, digits, or hyphens."
  }
}

variable "project_name" {
  description = "Human-readable GCP project display name (4-30 characters)."
  type        = string

  validation {
    condition     = length(var.project_name) >= 4 && length(var.project_name) <= 30
    error_message = "project_name must be between 4 and 30 characters."
  }
}

variable "region" {
  description = "Primary GCP region for environment networking and resources."
  type        = string
  default     = "us-central1"

  validation {
    condition     = can(regex("^[a-z]+-[a-z]+[0-9]+$", var.region))
    error_message = "region must be a valid GCP region identifier."
  }
}

variable "subnet_cidr" {
  description = "Primary IPv4 CIDR block for the regional subnet (must be non-overlapping per environment)."
  type        = string

  validation {
    condition     = can(cidrhost(var.subnet_cidr, 0))
    error_message = "subnet_cidr must be a valid IPv4 CIDR block."
  }
}

variable "enable_cloud_nat" {
  description = "Opt-in toggle for Cloud Router and Cloud NAT (default false for $0/mo baseline)."
  type        = bool
  default     = false
}

variable "enable_flow_logs" {
  description = "Opt-in toggle for VPC Flow Logs on the primary subnet (default false)."
  type        = bool
  default     = false
}

variable "monthly_budget_usd" {
  description = "Monthly Billing Budget cap in USD for this environment's project."
  type        = number
  default     = 50

  validation {
    condition     = var.monthly_budget_usd > 0
    error_message = "monthly_budget_usd must be greater than 0."
  }
}

variable "budget_alert_email" {
  description = "Email address receiving Billing Budget threshold alerts."
  type        = string

  validation {
    condition     = can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.budget_alert_email))
    error_message = "budget_alert_email must be a valid email address."
  }
}

variable "deletion_policy" {
  description = "Project deletion protection policy (PREVENT by default; override explicitly for teardown)."
  type        = string
  default     = "PREVENT"

  validation {
    condition     = contains(["PREVENT", "DELETE", "ABANDON"], var.deletion_policy)
    error_message = "deletion_policy must be one of: PREVENT, DELETE, ABANDON."
  }
}

variable "platform_name" {
  description = "Platform identifier applied to mandatory labels."
  type        = string
  default     = "unified-data-platform"

  validation {
    condition     = can(regex("^[a-z][a-z0-9_-]{1,61}[a-z0-9]$", var.platform_name))
    error_message = "platform_name must be a valid lowercase GCP label value."
  }
}

variable "cost_center" {
  description = "Cost center identifier applied to mandatory labels."
  type        = string
  default     = "engineering-playground"

  validation {
    condition     = can(regex("^[a-z][a-z0-9_-]{1,61}[a-z0-9]$", var.cost_center))
    error_message = "cost_center must be a valid lowercase GCP label value."
  }
}

variable "iap_ssh_target_tags" {
  description = "Network tags permitted inbound SSH (TCP 22) exclusively from Google IAP range 35.235.240.0/20."
  type        = list(string)
  default     = ["allow-iap-ssh"]

  validation {
    condition     = length(var.iap_ssh_target_tags) > 0
    error_message = "iap_ssh_target_tags must contain at least one network tag."
  }
}

variable "soft_delete_retention_seconds" {
  description = "GCS soft delete retention window in seconds for the catalog root bucket (7 to 90 days)."
  type        = number
  default     = 604800

  validation {
    condition     = floor(var.soft_delete_retention_seconds) == var.soft_delete_retention_seconds && var.soft_delete_retention_seconds >= 604800 && var.soft_delete_retention_seconds <= 7776000
    error_message = "soft_delete_retention_seconds must be an integer between 604800 (7d) and 7776000 (90d)."
  }
}

variable "catalog_name" {
  description = "Env-agnostic BigLake Iceberg REST catalog name for the Bronze layer (Spec 03 ADR-03)."
  type        = string
  default     = "bronze"

  validation {
    condition     = can(regex("^[a-z][a-z0-9_-]{1,61}[a-z0-9]$", var.catalog_name))
    error_message = "catalog_name must be 3-63 lowercase characters (letters, digits, _ or -), starting with a letter."
  }
}

variable "catalog_deletion_policy" {
  description = "OpenTofu deletion protection for the BigLake catalog (PREVENT by default; override explicitly for teardown)."
  type        = string
  default     = "PREVENT"

  validation {
    condition     = contains(["PREVENT", "DELETE", "ABANDON"], var.catalog_deletion_policy)
    error_message = "catalog_deletion_policy must be one of: PREVENT, DELETE, ABANDON."
  }
}
