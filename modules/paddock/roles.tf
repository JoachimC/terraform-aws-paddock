locals {
  oidc_issuer = "token.actions.githubusercontent.com"

  # Both subject forms, so the roles work whichever one GitHub sends.
  subject_prefixes = distinct(compact(["repo:${var.github_repository}", var.github_subject_prefix]))

  deploy_subjects = var.github_environment == null ? [
    for prefix in local.subject_prefixes : "${prefix}:ref:refs/heads/${var.deploy_branch}"
    ] : [
    for prefix in local.subject_prefixes : "${prefix}:environment:${var.github_environment}"
  ]

  # A pull_request token carries this subject whatever the branch, and can
  # never match the deploy role's subjects.
  plan_subjects = [for prefix in local.subject_prefixes : "${prefix}:pull_request"]

  github_trust = {
    for role, subjects in { deploy = local.deploy_subjects, plan = local.plan_subjects } : role => {
      Version                      = "2012-10-17"
      Statement = [{
        Effect    = "Allow"
        Principal = { Federated = var.account.oidc_provider_arn }
        Action    = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "${local.oidc_issuer}:aud" = "sts.amazonaws.com"
            "${local.oidc_issuer}:sub" = subjects
          }
        }
      }]
    }
  }

  runtime_trust = {
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = var.runtime_service }
      Action    = "sts:AssumeRole"
    }]
  }

  common_tags = { Paddock = local.n }
}

# --- Deploy role --------------------------------------------------------------

resource "aws_iam_role" "deploy" {
  name                 = "${local.n}-deploy"
  path                 = local.ci_role_path
  description          = "GitHub Actions deploys paddock ${local.n} from ${var.github_repository} with this role."
  assume_role_policy   = jsonencode(local.github_trust.deploy)
  max_session_duration = 3600
  tags                 = local.common_tags
}

# Inline, not managed: inline policies on a role hold 10,240 characters in
# total, a managed policy 6,144. With many services the deploy policy passes
# 6,144.
resource "aws_iam_role_policy" "deploy" {
  name   = "paddock-deploy"
  role   = aws_iam_role.deploy.id
  policy = jsonencode(local.deploy_policy)

  lifecycle {
    precondition {
      condition     = !local.publishes_dns || var.account.zone_id != null
      error_message = "hostnames are set, but the account has no hosted zone. Set dns in modules/account."
    }
  }
}

# --- Plan role ----------------------------------------------------------------

resource "aws_iam_role" "plan" {
  count = var.plan_role ? 1 : 0

  name                 = "${local.n}-plan"
  path                 = local.ci_role_path
  description          = "GitHub Actions pull requests plan paddock ${local.n} from ${var.github_repository} with this read-only role."
  assume_role_policy   = jsonencode(local.github_trust.plan)
  max_session_duration = 3600
  tags                 = local.common_tags
}

resource "aws_iam_role_policy" "plan" {
  count = var.plan_role ? 1 : 0

  name   = "paddock-plan"
  role   = aws_iam_role.plan[0].id
  policy = jsonencode(local.plan_policy)
}

# --- Runtime roles and their boundary -------------------------------------------

resource "aws_iam_policy" "boundary" {
  name        = "${local.n}-boundary"
  path        = "/paddock/"
  description = "The most any runtime role of paddock ${local.n} can do."
  policy      = jsonencode(local.boundary_policy)
  tags        = local.common_tags
}

resource "aws_iam_role" "runtime" {
  for_each = toset(var.runtime_roles)

  name                 = "${local.n}-${each.key}"
  path                 = local.runtime_role_path
  description          = "Runtime role ${each.key} of paddock ${local.n}. Its own Terraform adds inline policies; the boundary caps them."
  assume_role_policy   = jsonencode(local.runtime_trust)
  permissions_boundary = aws_iam_policy.boundary.arn
  tags                 = local.common_tags
}

resource "aws_iam_role_policy" "runtime_baseline" {
  for_each = toset(var.runtime_roles)

  name   = "paddock-baseline"
  role   = aws_iam_role.runtime[each.key].id
  policy = jsonencode(local.runtime_baseline_policy)
}
