mock_provider "google" {}

variables {
  billing_account_id = "01ABCD-23EFGH-45IJKL"
  project_id         = "udp-dev-test-001"
  project_number     = "123456789012"
  display_name       = "udp-dev-monthly-budget"
  monthly_amount_usd = 50
  alert_email        = "alerts@example.com"
}

# TC-007 (positive): Monitoring email channel + project-scoped Billing Budget with 3 thresholds
run "happy_path_budget_guardrail" {
  command = plan

  assert {
    condition     = google_monitoring_notification_channel.budget_email.type == "email" && google_monitoring_notification_channel.budget_email.labels["email_address"] == "alerts@example.com"
    error_message = "Monitoring notification channel must target the configured alert email."
  }

  assert {
    condition     = contains(google_billing_budget.this.budget_filter[0].projects, "projects/123456789012")
    error_message = "Billing Budget must be scoped strictly to projects/<project_number>."
  }

  assert {
    condition     = google_billing_budget.this.amount[0].specified_amount[0].currency_code == "USD" && google_billing_budget.this.amount[0].specified_amount[0].units == "50"
    error_message = "Billing Budget amount must equal 50 USD."
  }

  assert {
    condition     = length(google_billing_budget.this.threshold_rules) == 3
    error_message = "Billing Budget must configure 3 default threshold rules (50%, 80%, 100%)."
  }
}

# TC-007 (negative): Non-positive monthly amount rejected
run "reject_zero_monthly_amount" {
  command = plan

  variables {
    monthly_amount_usd = 0
  }

  expect_failures = [var.monthly_amount_usd]
}

run "reject_out_of_range_threshold" {
  command = plan

  variables {
    threshold_percents = [0.5, 2.5]
  }

  expect_failures = [var.threshold_percents]
}
