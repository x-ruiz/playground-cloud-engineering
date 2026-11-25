resource "google_monitoring_notification_channel" "budget_email" {
  project      = var.project_id
  display_name = "${var.display_name} Email"
  type         = "email"

  labels = {
    email_address = var.alert_email
  }
}

resource "google_billing_budget" "this" {
  billing_account = var.billing_account_id
  display_name    = var.display_name

  budget_filter {
    projects = ["projects/${var.project_number}"]
  }

  amount {
    specified_amount {
      currency_code = "USD"
      units         = tostring(floor(var.monthly_amount_usd))
    }
  }

  dynamic "threshold_rules" {
    for_each = var.threshold_percents
    content {
      threshold_percent = threshold_rules.value
      spend_basis       = var.spend_basis
    }
  }

  all_updates_rule {
    monitoring_notification_channels = [
      google_monitoring_notification_channel.budget_email.id,
    ]
    disable_default_iam_recipients = false
  }
}
