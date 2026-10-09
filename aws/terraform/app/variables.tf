variable "region" {
  description = "AWS region. Must match the bootstrap stack."
  type        = string
  default     = "ap-east-1"
}

variable "project" {
  description = "Name prefix. Must match the bootstrap stack, whose deploy role is scoped to it."
  type        = string
  default     = "infra-toolkit-links"
}

variable "deployment_config_name" {
  description = "CodeDeploy traffic-shifting strategy for new Lambda versions."
  type        = string
  default     = "CodeDeployDefault.LambdaCanary10Percent5Minutes"

  validation {
    condition = contains([
      "CodeDeployDefault.LambdaAllAtOnce",
      "CodeDeployDefault.LambdaCanary10Percent5Minutes",
      "CodeDeployDefault.LambdaCanary10Percent10Minutes",
      "CodeDeployDefault.LambdaCanary10Percent15Minutes",
      "CodeDeployDefault.LambdaCanary10Percent30Minutes",
      "CodeDeployDefault.LambdaLinear10PercentEvery1Minute",
      "CodeDeployDefault.LambdaLinear10PercentEvery2Minutes",
      "CodeDeployDefault.LambdaLinear10PercentEvery3Minutes",
      "CodeDeployDefault.LambdaLinear10PercentEvery10Minutes",
    ], var.deployment_config_name)
    error_message = "deployment_config_name must be a predefined CodeDeploy Lambda configuration."
  }
}

variable "alarm_email" {
  description = "Optional email subscribed to alarm and deployment notifications. Leave empty to skip."
  type        = string
  default     = ""
}

variable "log_retention_days" {
  description = "Retention for Lambda and API access logs."
  type        = number
  default     = 14
}

variable "table_deletion_protection" {
  description = "Protect the DynamoDB table from deletion. Off by default so the demo can be torn down."
  type        = bool
  default     = false
}
