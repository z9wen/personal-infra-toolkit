resource "aws_dynamodb_table" "links" {
  name                        = "${var.project}-links"
  billing_mode                = "PAY_PER_REQUEST"
  hash_key                    = "code"
  deletion_protection_enabled = var.table_deletion_protection

  attribute {
    name = "code"
    type = "S"
  }

  # TTL removes expired links in the background. Deletion can lag by hours,
  # so the handler also checks expires_at on every read.
  ttl {
    attribute_name = "expires_at"
    enabled        = true
  }

  point_in_time_recovery {
    enabled = true
  }
}
