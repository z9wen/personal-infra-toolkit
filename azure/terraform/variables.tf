variable "location" {
  description = "Azure region. eastasia is Hong Kong; southeastasia is Singapore."
  type        = string
  default     = "eastasia"
}

variable "name" {
  description = "Name prefix for every resource."
  type        = string
  default     = "infra-toolkit"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,20}$", var.name))
    error_message = "name must be 3-21 lowercase letters, digits or hyphens."
  }
}

variable "admin_source_cidr" {
  description = "Only this CIDR may SSH to the VM, e.g. \"203.0.113.10/32\". Deliberately has no default."
  type        = string

  validation {
    condition     = can(cidrhost(var.admin_source_cidr, 0)) && var.admin_source_cidr != "0.0.0.0/0"
    error_message = "admin_source_cidr must be a valid CIDR and must not be 0.0.0.0/0."
  }
}

variable "ssh_public_key_path" {
  description = "Public key installed for the VM admin user. Password login is disabled."
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}

variable "vm_size" {
  description = "VM size. B2ats_v2 is covered by the Azure free account for 12 months."
  type        = string
  default     = "Standard_B2ats_v2"
}

variable "mysql_sku" {
  description = "MySQL Flexible Server SKU. B_Standard_B1ms is covered by the Azure free account for 12 months."
  type        = string
  default     = "B_Standard_B1ms"
}

variable "internal_dns_zone" {
  description = "Private DNS zone for internal names. VMs in the VNet register themselves here."
  type        = string
  default     = "infra.internal"
}

variable "auto_shutdown_time" {
  description = "Daily VM shutdown time (HHmm, Hong Kong time) to cap compute cost. Empty disables it."
  type        = string
  default     = "2300"
}

variable "monthly_budget" {
  description = "Monthly budget for the resource group, in the billing currency."
  type        = number
  default     = 10
}

variable "budget_alert_email" {
  description = "Email for budget alerts. Empty skips creating the budget."
  type        = string
  default     = ""
}
