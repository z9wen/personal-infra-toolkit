output "api_url" {
  description = "Base URL of the HTTP API."
  value       = aws_apigatewayv2_stage.default.invoke_url
}

output "function_name" {
  value = aws_lambda_function.app.function_name
}

output "function_version" {
  description = "Version published by the latest apply; the deploy script shifts the live alias to it."
  value       = aws_lambda_function.app.version
}

output "alias_name" {
  value = aws_lambda_alias.live.name
}

output "codedeploy_application" {
  value = aws_codedeploy_app.this.name
}

output "codedeploy_deployment_group" {
  value = aws_codedeploy_deployment_group.live.deployment_group_name
}

output "table_name" {
  value = aws_dynamodb_table.links.name
}

output "dashboard_url" {
  value = "https://${var.region}.console.aws.amazon.com/cloudwatch/home?region=${var.region}#dashboards:name=${aws_cloudwatch_dashboard.overview.dashboard_name}"
}
