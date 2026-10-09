data "archive_file" "app" {
  type        = "zip"
  source_file = "${path.module}/../../app/handler.py"
  output_path = "${path.module}/.build/app.zip"
}

resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${local.function_name}"
  retention_in_days = var.log_retention_days
}

resource "aws_lambda_function" "app" {
  function_name    = local.function_name
  description      = "URL shortener API"
  role             = aws_iam_role.lambda.arn
  runtime          = "python3.13"
  handler          = "handler.lambda_handler"
  architectures    = ["arm64"]
  memory_size      = 256
  timeout          = 5
  filename         = data.archive_file.app.output_path
  source_code_hash = data.archive_file.app.output_base64sha256

  # Every code or configuration change publishes an immutable version.
  # Traffic only moves to it through CodeDeploy (see codedeploy.tf).
  publish = true

  environment {
    variables = {
      TABLE_NAME = aws_dynamodb_table.links.name
    }
  }

  tracing_config {
    mode = "Active"
  }

  logging_config {
    log_format            = "JSON"
    log_group             = aws_cloudwatch_log_group.lambda.name
    application_log_level = "INFO"
    system_log_level      = "WARN"
  }

  depends_on = [aws_iam_role_policy.lambda]
}

# API Gateway always invokes this alias, never $LATEST. Terraform creates it
# once; afterwards CodeDeploy owns which version it points to.
resource "aws_lambda_alias" "live" {
  name             = local.alias_name
  function_name    = aws_lambda_function.app.function_name
  function_version = aws_lambda_function.app.version

  lifecycle {
    ignore_changes = [function_version, routing_config]
  }
}
