resource "random_string" "suffix" {
  length  = 6
  upper   = false
  special = false
}

locals {
  vm_name = "${var.name}-app"
  tags = {
    project   = var.name
    managedBy = "terraform"
  }
}

resource "azurerm_resource_group" "this" {
  name     = "rg-${var.name}"
  location = var.location
  tags     = local.tags
}

resource "azurerm_consumption_budget_resource_group" "monthly" {
  count = var.budget_alert_email == "" ? 0 : 1

  name              = "${var.name}-monthly"
  resource_group_id = azurerm_resource_group.this.id
  amount            = var.monthly_budget
  time_grain        = "Monthly"

  time_period {
    start_date = formatdate("YYYY-MM-01'T'00:00:00Z", timestamp())
  }

  notification {
    enabled        = true
    threshold      = 80
    operator       = "GreaterThan"
    threshold_type = "Forecasted"
    contact_emails = [var.budget_alert_email]
  }

  notification {
    enabled        = true
    threshold      = 100
    operator       = "GreaterThan"
    threshold_type = "Actual"
    contact_emails = [var.budget_alert_email]
  }

  lifecycle {
    # The start date is fixed at creation; later applies must not move it.
    ignore_changes = [time_period]
  }
}
