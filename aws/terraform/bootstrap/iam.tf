# ---------------------------------------------------------------------------
# GitHub Actions -> AWS via OIDC. No long-lived access keys are stored in
# GitHub; each workflow run receives short-lived credentials instead.
# ---------------------------------------------------------------------------
resource "aws_iam_openid_connect_provider" "github" {
  count = var.create_github_oidc_provider ? 1 : 0

  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

data "aws_iam_openid_connect_provider" "github" {
  count = var.create_github_oidc_provider ? 0 : 1

  url = "https://token.actions.githubusercontent.com"
}

locals {
  github_oidc_provider_arn = var.create_github_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : data.aws_iam_openid_connect_provider.github[0].arn
}

data "aws_iam_policy_document" "github_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.github_oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Only jobs that run in the protected GitHub environment of this
    # repository can assume the role: not forks, other branches' ad-hoc jobs
    # or other repositories.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_repository}:environment:${var.github_environment}"]
    }
  }
}

# Deliberately named outside the "${var.project}-*" prefix so the role cannot
# use its own IAM permissions to rewrite its trust policy.
resource "aws_iam_role" "github_deploy" {
  name                 = "github-deploy-${var.project}"
  description          = "Assumed by GitHub Actions to deploy ${var.project}"
  assume_role_policy   = data.aws_iam_policy_document.github_trust.json
  max_session_duration = 3600
}

# ---------------------------------------------------------------------------
# Deploy role permissions: scoped by name prefix instead of
# AdministratorAccess. API Gateway ARNs carry generated IDs rather than names,
# so that service is scoped to the region only.
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "github_deploy" {
  statement {
    sid       = "TerraformStateList"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.state.arn]
  }

  statement {
    sid       = "TerraformStateObjects"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.state.arn}/*"]
  }

  statement {
    sid       = "LambdaFunctions"
    actions   = ["lambda:*"]
    resources = [local.lambda_functions]
  }

  statement {
    sid       = "DynamoDBTables"
    actions   = ["dynamodb:*"]
    resources = [local.dynamodb_tables]
  }

  statement {
    sid     = "HttpApis"
    actions = ["apigateway:GET", "apigateway:POST", "apigateway:PUT", "apigateway:PATCH", "apigateway:DELETE"]
    resources = [
      "arn:${local.partition}:apigateway:${local.region}::/apis",
      "arn:${local.partition}:apigateway:${local.region}::/apis/*",
      "arn:${local.partition}:apigateway:${local.region}::/tags/*",
    ]
  }

  statement {
    sid = "ProjectLogGroups"
    actions = [
      "logs:CreateLogGroup",
      "logs:DeleteLogGroup",
      "logs:PutRetentionPolicy",
      "logs:DeleteRetentionPolicy",
      "logs:TagResource",
      "logs:UntagResource",
      "logs:ListTagsForResource",
      "logs:TagLogGroup",
      "logs:ListTagsLogGroup",
    ]
    resources = [local.log_groups]
  }

  # API Gateway access logging and log-group discovery cannot be scoped to a
  # resource ARN.
  statement {
    sid = "LogDeliveryAndDiscovery"
    actions = [
      "logs:DescribeLogGroups",
      "logs:CreateLogDelivery",
      "logs:GetLogDelivery",
      "logs:UpdateLogDelivery",
      "logs:DeleteLogDelivery",
      "logs:ListLogDeliveries",
      "logs:PutResourcePolicy",
      "logs:DescribeResourcePolicies",
      "cloudwatch:DescribeAlarms",
    ]
    resources = ["*"]
  }

  statement {
    sid = "ProjectAlarmsAndDashboards"
    actions = [
      "cloudwatch:PutMetricAlarm",
      "cloudwatch:DeleteAlarms",
      "cloudwatch:TagResource",
      "cloudwatch:UntagResource",
      "cloudwatch:ListTagsForResource",
      "cloudwatch:PutDashboard",
      "cloudwatch:GetDashboard",
      "cloudwatch:DeleteDashboards",
    ]
    resources = [
      "arn:${local.partition}:cloudwatch:${local.region}:${local.account_id}:alarm:${var.project}-*",
      "arn:${local.partition}:cloudwatch::${local.account_id}:dashboard/${var.project}-*",
    ]
  }

  statement {
    sid       = "ProjectTopics"
    actions   = ["sns:*"]
    resources = [local.sns_topics]
  }

  statement {
    sid     = "CodeDeploy"
    actions = ["codedeploy:*"]
    resources = [
      "arn:${local.partition}:codedeploy:${local.region}:${local.account_id}:application:${var.project}*",
      "arn:${local.partition}:codedeploy:${local.region}:${local.account_id}:deploymentgroup:${var.project}*/*",
      "arn:${local.partition}:codedeploy:${local.region}:${local.account_id}:deploymentconfig:*",
    ]
  }

  # Roles created by the pipeline must carry the permissions boundary, so the
  # deploy role cannot mint a role more powerful than the application needs.
  statement {
    sid       = "CreateBoundedProjectRoles"
    actions   = ["iam:CreateRole", "iam:PutRolePolicy"]
    resources = [local.project_roles]

    condition {
      test     = "StringEquals"
      variable = "iam:PermissionsBoundary"
      values   = [local.boundary_arn]
    }
  }

  statement {
    sid = "ManageProjectRoles"
    actions = [
      "iam:GetRole",
      "iam:GetRolePolicy",
      "iam:ListRolePolicies",
      "iam:ListAttachedRolePolicies",
      "iam:ListInstanceProfilesForRole",
      "iam:DeleteRolePolicy",
      "iam:DeleteRole",
      "iam:TagRole",
      "iam:UntagRole",
      "iam:UpdateAssumeRolePolicy",
    ]
    resources = [local.project_roles]
  }

  statement {
    sid       = "PassProjectRolesToServices"
    actions   = ["iam:PassRole"]
    resources = [local.project_roles]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["lambda.amazonaws.com", "codedeploy.amazonaws.com"]
    }
  }

  statement {
    sid       = "ProtectPermissionsBoundary"
    effect    = "Deny"
    actions   = ["iam:PutRolePermissionsBoundary", "iam:DeleteRolePermissionsBoundary"]
    resources = ["*"]
  }

  statement {
    sid       = "ProtectBoundaryPolicy"
    effect    = "Deny"
    actions   = ["iam:CreatePolicyVersion", "iam:DeletePolicy", "iam:DeletePolicyVersion", "iam:SetDefaultPolicyVersion"]
    resources = [local.boundary_arn]
  }
}

resource "aws_iam_role_policy" "github_deploy" {
  name   = "deploy-${var.project}"
  role   = aws_iam_role.github_deploy.id
  policy = data.aws_iam_policy_document.github_deploy.json
}

# ---------------------------------------------------------------------------
# Permissions boundary: the maximum any application role may ever do, no
# matter what inline policy the pipeline attaches to it.
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "boundary" {
  statement {
    sid       = "WriteOwnLogs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = [local.log_groups]
  }

  statement {
    sid       = "Tracing"
    actions   = ["xray:PutTraceSegments", "xray:PutTelemetryRecords"]
    resources = ["*"]
  }

  statement {
    sid       = "ProjectTablesItemAccess"
    actions   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:DeleteItem", "dynamodb:Query"]
    resources = [local.dynamodb_tables]
  }

  # Needed by the CodeDeploy service role to shift alias traffic.
  statement {
    sid       = "ShiftLambdaAliasTraffic"
    actions   = ["lambda:GetAlias", "lambda:UpdateAlias", "lambda:GetProvisionedConcurrencyConfig", "lambda:InvokeFunction"]
    resources = [local.lambda_functions]
  }

  statement {
    sid       = "ReadAlarms"
    actions   = ["cloudwatch:DescribeAlarms"]
    resources = ["*"]
  }

  statement {
    sid       = "NotifyProjectTopics"
    actions   = ["sns:Publish"]
    resources = [local.sns_topics]
  }
}

resource "aws_iam_policy" "boundary" {
  name        = "${var.project}-boundary"
  description = "Permissions boundary for every role created by the ${var.project} pipeline"
  policy      = data.aws_iam_policy_document.boundary.json
}
