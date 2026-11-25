variable "project_id" {
  description = "Base GCP Project ID prefix (a random 4-char hex suffix -xxxx is appended automatically)."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,23}[a-z0-9]$", var.project_id))
    error_message = "project_id must be 4-25 lowercase letters, digits, or hyphens (leaving room for the -xxxx random suffix within GCP's 30-char limit)."
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

variable "folder_id" {
  description = "Parent GCP Folder ID (accepts either folders/<id> or numeric <id>)."
  type        = string

  validation {
    condition     = can(regex("^(folders/)?[0-9]+$", var.folder_id))
    error_message = "folder_id must be a numeric folder ID or folders/<numeric-id>."
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

variable "environment" {
  description = "Deployment environment (dev, staging, or prod)."
  type        = string

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of: dev, staging, prod."
  }
}

variable "activate_apis" {
  description = "Set of GCP service APIs to enable on the project (disable_on_destroy is always false)."
  type        = set(string)
  default     = []
}

variable "deletion_policy" {
  description = "Deletion protection policy for the GCP project (PREVENT, DELETE, or ABANDON)."
  type        = string
  default     = "PREVENT"

  validation {
    condition     = contains(["PREVENT", "DELETE", "ABANDON"], var.deletion_policy)
    error_message = "deletion_policy must be one of: PREVENT, DELETE, ABANDON."
  }
}

variable "platform_name" {
  description = "Platform identifier applied to mandatory resource labels."
  type        = string
  default     = "unified-data-platform"

  validation {
    condition     = can(regex("^[a-z][a-z0-9_-]{1,61}[a-z0-9]$", var.platform_name))
    error_message = "platform_name must be a valid lowercase GCP label value."
  }
}

variable "cost_center" {
  description = "Cost center identifier applied to mandatory resource labels."
  type        = string
  default     = "engineering-playground"

  validation {
    condition     = can(regex("^[a-z][a-z0-9_-]{1,61}[a-z0-9]$", var.cost_center))
    error_message = "cost_center must be a valid lowercase GCP label value."
  }
}

variable "labels" {
  description = "Additional custom GCP labels merged with mandatory platform labels."
  type        = map(string)
  default     = {}

  validation {
    condition = alltrue([
      for k, v in var.labels :
      can(regex("^[a-z][a-z0-9_-]{0,62}$", k)) && can(regex("^[a-z0-9_-]{0,63}$", v))
    ])
    error_message = "All label keys and values must comply with GCP lowercase label formatting."
  }
}
