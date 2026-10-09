variable "region" {
  description = "AWS region. ap-east-1 (Hong Kong) is an opt-in region and must be enabled on the account first."
  type        = string
  default     = "ap-east-1"
}

variable "project" {
  description = "Name prefix shared by every resource. The deploy role is only allowed to manage resources that start with it."
  type        = string
  default     = "infra-toolkit-links"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,30}$", var.project))
    error_message = "project must be 3-31 lowercase letters, digits or hyphens."
  }
}

variable "github_repository" {
  description = "GitHub repository allowed to assume the deploy role, as owner/name."
  type        = string
  default     = "z9wen/personal-infra-toolkit"
}

variable "github_environment" {
  description = "GitHub Actions environment allowed to assume the deploy role. Protect it with required reviewers."
  type        = string
  default     = "aws-demo"
}

variable "create_github_oidc_provider" {
  description = "Set to false if the account already has the token.actions.githubusercontent.com OIDC provider."
  type        = bool
  default     = true
}

variable "monthly_budget_usd" {
  description = "Monthly cost budget that triggers email alerts."
  type        = number
  default     = 5
}

variable "budget_alert_email" {
  description = "Email address that receives budget alerts."
  type        = string
}
