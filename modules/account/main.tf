data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

data "aws_partition" "current" {}

locals {
  account   = data.aws_caller_identity.current.account_id
  region    = data.aws_region.current.region
  partition = data.aws_partition.current.partition

  state_bucket = "${var.state_bucket_prefix}-terraform-state-${local.account}"

  # Every deploy role and plan role sits under this IAM path. The state bucket
  # policy can then name all of them with one pattern, and it never has to
  # change when a paddock is added. modules/paddock uses the same path.
  ci_role_path    = "/paddock/ci/"
  ci_role_pattern = "arn:${local.partition}:iam::${local.account}:role${local.ci_role_path}*"

  # The account layer's own state key. No paddock may be named "account"
  # (modules/paddock checks this), so no deploy role can reach this prefix.
  account_state_key = "account/terraform.tfstate"

  oidc_provider_arn = var.create_github_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : var.existing_github_oidc_provider_arn
}
