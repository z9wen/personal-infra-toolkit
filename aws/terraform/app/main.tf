data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  function_name = "${var.project}-api"
  alias_name    = "live"

  # Created by the bootstrap stack. The deploy role may only create roles that
  # carry this boundary.
  permissions_boundary_arn = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:policy/${var.project}-boundary"
}
