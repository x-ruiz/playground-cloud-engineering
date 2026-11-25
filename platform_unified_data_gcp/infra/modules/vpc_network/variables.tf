variable "project_id" {
  description = "Target GCP Project ID."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.project_id))
    error_message = "project_id must be a valid GCP Project ID."
  }
}

variable "network_name" {
  description = "Lowercase DNS-safe name for the custom-mode VPC."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,61}[a-z0-9]$", var.network_name))
    error_message = "network_name must be lowercase letters, digits, or hyphens (RFC 1035)."
  }
}

variable "region" {
  description = "GCP region for the primary subnet and optional Cloud Router / Cloud NAT."
  type        = string
  default     = "us-central1"

  validation {
    condition     = can(regex("^[a-z]+-[a-z]+[0-9]+$", var.region))
    error_message = "region must be a valid GCP region identifier."
  }
}

variable "subnet_cidr" {
  description = "Primary IPv4 CIDR block for the regional subnet."
  type        = string
  default     = "10.10.0.0/20"

  validation {
    condition     = can(cidrhost(var.subnet_cidr, 0))
    error_message = "subnet_cidr must be a valid IPv4 CIDR block."
  }
}

variable "enable_flow_logs" {
  description = "Enable VPC Flow Logs on the primary subnet (default false for $0/mo baseline)."
  type        = bool
  default     = false
}

variable "enable_cloud_nat" {
  description = "Provision Cloud Router and Cloud NAT for private egress (default false for $0/mo baseline)."
  type        = bool
  default     = false
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
