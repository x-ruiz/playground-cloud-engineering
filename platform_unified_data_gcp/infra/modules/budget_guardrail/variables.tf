variable "billing_account_id" {
  description = "GCP Billing Account ID in XXXXXX-XXXXXX-XXXXXX format."
  type        = string

  validation {
    condition     = can(regex("^[A-Z0-9]{6}-[A-Z0-9]{6}-[A-Z0-9]{6}$", var.billing_account_id))
    error_message = "billing_account_id must match XXXXXX-XXXXXX-XXXXXX."
  }
}

variable "project_id" {
  description = "Host GCP Project ID where the Cloud Monitoring notification channel is created."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.project_id))
    error_message = "project_id must be a valid GCP Project ID."
  }
}

variable "project_number" {
  description = "Numeric GCP Project number targeted by the Billing Budget filter."
  type        = string

  validation {
    condition     = can(regex("^[0-9]+$", var.project_number))
    error_message = "project_number must contain digits only."
  }
}

variable "display_name" {
  description = "Display name for the Billing Budget."
  type        = string

  validation {
    condition     = length(trimspace(var.display_name)) > 0
    error_message = "display_name must not be empty."
  }
}

variable "monthly_amount_usd" {
  description = "Monthly budget cap in whole USD."
  type        = number
  default     = 50

  validation {
    condition     = var.monthly_amount_usd > 0
    error_message = "monthly_amount_usd must be greater than 0."
  }
}

variable "alert_email" {
  description = "Email address receiving budget threshold alerts via Cloud Monitoring."
  type        = string

  validation {
    condition     = can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.alert_email))
    error_message = "alert_email must be a valid email address."
  }
}

variable "threshold_percents" {
  description = "List of spend threshold ratios (e.g., [0.5, 0.8, 1.0] for 50%, 80%, 100%)."
  type        = list(number)
  default     = [0.5, 0.8, 1.0]

  validation {
    condition     = length(var.threshold_percents) > 0 && alltrue([for t in var.threshold_percents : t > 0 && t <= 2.0])
    error_message = "threshold_percents must be non-empty and each threshold must be > 0 and <= 2.0."
  }
}

variable "spend_basis" {
  description = "Budget threshold evaluation basis (CURRENT_SPEND or FORECASTED_SPEND)."
  type        = string
  default     = "CURRENT_SPEND"

  validation {
    condition     = contains(["CURRENT_SPEND", "FORECASTED_SPEND"], var.spend_basis)
    error_message = "spend_basis must be CURRENT_SPEND or FORECASTED_SPEND."
  }
}
