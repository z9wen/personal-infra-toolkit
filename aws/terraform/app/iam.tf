data "aws_iam_policy_document" "lambda_trust" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda" {
  name                 = "${var.project}-lambda"
  assume_role_policy   = data.aws_iam_policy_document.lambda_trust.json
  permissions_boundary = local.permissions_boundary_arn
}

# Inline least-privilege policy instead of broad AWS managed policies: the
# function can only write its own logs and read/write items in its own table.
data "aws_iam_policy_document" "lambda" {
  statement {
    sid       = "WriteOwnLogs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.lambda.arn}:*"]
  }

  statement {
    sid       = "Tracing"
    actions   = ["xray:PutTraceSegments", "xray:PutTelemetryRecords"]
    resources = ["*"]
  }

  statement {
    sid       = "LinksTable"
    actions   = ["dynamodb:GetItem", "dynamodb:PutItem"]
    resources = [aws_dynamodb_table.links.arn]
  }
}

resource "aws_iam_role_policy" "lambda" {
  name   = "runtime"
  role   = aws_iam_role.lambda.id
  policy = data.aws_iam_policy_document.lambda.json
}

data "aws_iam_policy_document" "codedeploy_trust" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["codedeploy.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "codedeploy" {
  name                 = "${var.project}-codedeploy"
  assume_role_policy   = data.aws_iam_policy_document.codedeploy_trust.json
  permissions_boundary = local.permissions_boundary_arn
}

data "aws_iam_policy_document" "codedeploy" {
  statement {
    sid     = "ShiftAliasTraffic"
    actions = ["lambda:GetAlias", "lambda:UpdateAlias", "lambda:GetProvisionedConcurrencyConfig"]
    resources = [
      aws_lambda_function.app.arn,
      "${aws_lambda_function.app.arn}:*",
    ]
  }

  statement {
    sid       = "WatchRollbackAlarms"
    actions   = ["cloudwatch:DescribeAlarms"]
    resources = ["*"]
  }

  statement {
    sid       = "PublishDeploymentEvents"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.alerts.arn]
  }
}

resource "aws_iam_role_policy" "codedeploy" {
  name   = "lambda-traffic-shifting"
  role   = aws_iam_role.codedeploy.id
  policy = data.aws_iam_policy_document.codedeploy.json
}
