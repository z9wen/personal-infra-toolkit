# Blue/green traffic shifting between Lambda versions. A deployment moves the
# "live" alias from the current version to the newly published one in steps,
# and rolls back automatically if a rollback alarm fires during the bake time.
resource "aws_codedeploy_app" "this" {
  name             = var.project
  compute_platform = "Lambda"
}

resource "aws_codedeploy_deployment_group" "live" {
  app_name               = aws_codedeploy_app.this.name
  deployment_group_name  = "${var.project}-live"
  service_role_arn       = aws_iam_role.codedeploy.arn
  deployment_config_name = var.deployment_config_name

  deployment_style {
    deployment_type   = "BLUE_GREEN"
    deployment_option = "WITH_TRAFFIC_CONTROL"
  }

  auto_rollback_configuration {
    enabled = true
    events  = ["DEPLOYMENT_FAILURE", "DEPLOYMENT_STOP_ON_ALARM"]
  }

  alarm_configuration {
    enabled = true
    alarms = [
      aws_cloudwatch_metric_alarm.lambda_errors.alarm_name,
      aws_cloudwatch_metric_alarm.api_5xx.alarm_name,
    ]
  }

  trigger_configuration {
    trigger_name       = "${var.project}-deployment-events"
    trigger_target_arn = aws_sns_topic.alerts.arn
    trigger_events     = ["DeploymentSuccess", "DeploymentFailure", "DeploymentRollback", "DeploymentStop"]
  }

  depends_on = [aws_iam_role_policy.codedeploy]
}
