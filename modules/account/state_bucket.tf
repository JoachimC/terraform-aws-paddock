# One bucket holds the state of the account layer and of every paddock, each
# under its own key prefix. Versioning is the recovery path: a bad state is
# one earlier version away.
resource "aws_s3_bucket" "state" {
  bucket = local.state_bucket

  # State is the only record of what exists. Losing it costs more than the
  # bucket is worth. To remove the account layer, see "Teardown" in the
  # README: move the state out first, then delete this block.
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id

  versioning_configuration {
    status = "Enabled"
  }
}

# SSE-S3, not KMS. A KMS key would add kms:Decrypt and kms:GenerateDataKey to
# every deploy role for no gain: the bucket policy already decides who may
# read an object.
resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    id     = "expire-replaced-state"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = var.noncurrent_state_version_days
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  # A lifecycle rule on noncurrent versions needs versioning to exist first.
  depends_on = [aws_s3_bucket_versioning.state]
}

locals {
  # The bucket policy holds Deny statements only. Within one account an
  # identity policy alone grants access, so each deploy role's own policy
  # (modules/paddock) grants its prefix. The bucket policy keeps everyone
  # else out, even a role that has s3:* on * by mistake.
  #
  # It never denies bucket-policy actions. A wrong admin pattern then locks
  # nobody out of correcting this policy.
  state_bucket_policy = {
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource  = [local.state_bucket_arn, "${local.state_bucket_arn}/*"]
        Condition = {
          Bool = { "aws:SecureTransport" = "false" }
        }
      },
      {
        Sid       = "DenyStateAccessToEveryoneButCiRolesAndAdmins"
        Effect    = "Deny"
        Principal = "*"
        Action = [
          "s3:GetObject",
          "s3:GetObjectVersion",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:DeleteObjectVersion",
          "s3:ListBucket",
          "s3:ListBucketVersions",
        ]
        Resource = [local.state_bucket_arn, "${local.state_bucket_arn}/*"]
        Condition = {
          StringNotLike = {
            "aws:PrincipalArn" = concat([local.ci_role_pattern], var.admin_principal_arns)
          }
        }
      },
    ]
  }
}

resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id
  policy = jsonencode(local.state_bucket_policy)

  # S3 judges a policy against the public access block, so the block must
  # exist first.
  depends_on = [aws_s3_bucket_public_access_block.state]

  # Every paddock role trusts this provider, so the account layer cannot do
  # its job without one.
  lifecycle {
    precondition {
      condition     = local.oidc_provider_arn != null
      error_message = "create_github_oidc_provider is false, so set existing_github_oidc_provider_arn to the provider the account already has."
    }
  }
}
