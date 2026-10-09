output "state_bucket" {
  description = "S3 bucket for the application stack's Terraform state."
  value       = aws_s3_bucket.state.bucket
}

output "deploy_role_arn" {
  description = "Set as the AWS_DEPLOY_ROLE_ARN variable of the GitHub environment."
  value       = aws_iam_role.github_deploy.arn
}

output "permissions_boundary_arn" {
  description = "Boundary that application roles must carry."
  value       = aws_iam_policy.boundary.arn
}

output "region" {
  value = var.region
}
