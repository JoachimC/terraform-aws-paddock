# Runs with a mock provider: no AWS account and no credentials. Each run
# applies against the mock, so every policy is a known JSON string, and the
# asserts read the policies the module would send to IAM.

mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012" }
  }
  mock_data "aws_region" {
    defaults = { region = "ap-southeast-2" }
  }
  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }
  mock_resource "aws_iam_policy" {
    defaults = { arn = "arn:aws:iam::123456789012:policy/paddock/orders-boundary" }
  }
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::123456789012:role/paddock/ci/orders-deploy" }
  }
}

variables {
  name = "orders"
  account = {
    state_bucket             = "example-terraform-state-123456789012"
    oidc_provider_arn        = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
    zone_id                  = "Z0123456789ABCDEFGHIJ"
    wildcard_certificate_arn = "arn:aws:acm:ap-southeast-2:123456789012:certificate/11111111-2222-3333-4444-555555555555"
  }
  github_repository = "example-org/orders"
  aws_services      = ["lambda", "logs", "apigateway", "dynamodb"]
  hostnames         = ["api.apps.example.com"]
}

run "given_a_repository_when_applied_then_deploy_role_trusts_only_pushes_to_main" {
  assert {
    condition = jsondecode(aws_iam_role.deploy.assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:sub"] == [
      "repo:example-org/orders:ref:refs/heads/main",
    ]
    error_message = "The deploy role must trust exactly the main branch of the one repository."
  }

  assert {
    condition     = jsondecode(aws_iam_role.deploy.assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:aud"] == "sts.amazonaws.com"
    error_message = "The deploy role must require the sts.amazonaws.com audience."
  }
}

run "given_a_repository_when_applied_then_plan_role_trusts_only_pull_requests" {
  assert {
    condition = jsondecode(aws_iam_role.plan[0].assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:sub"] == [
      "repo:example-org/orders:pull_request",
    ]
    error_message = "The plan role must trust pull request tokens of the one repository only."
  }
}

run "given_an_immutable_subject_prefix_when_applied_then_both_subject_forms_are_trusted" {
  variables {
    github_subject_prefix = "repo:example-org@1234/orders@5678"
  }

  assert {
    condition = toset(jsondecode(aws_iam_role.deploy.assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:sub"]) == toset([
      "repo:example-org/orders:ref:refs/heads/main",
      "repo:example-org@1234/orders@5678:ref:refs/heads/main",
    ])
    error_message = "Both the plain and the immutable subject must be trusted."
  }
}

run "given_a_github_environment_when_applied_then_deploy_role_trusts_the_environment_subject" {
  variables {
    github_environment = "production"
  }

  assert {
    condition = jsondecode(aws_iam_role.deploy.assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:sub"] == [
      "repo:example-org/orders:environment:production",
    ]
    error_message = "A job with an environment sends an environment subject; the trust policy must name it."
  }
}

run "given_any_services_when_applied_then_deploy_role_cannot_create_roles_or_change_boundaries" {
  variables {
    aws_services = ["apigateway", "cloudwatch", "dynamodb", "ecr", "events", "kms", "lambda", "logs", "s3", "secretsmanager", "sns", "sqs", "ssm"]
  }

  assert {
    condition = length([
      for statement in jsondecode(aws_iam_role_policy.deploy.policy).Statement : statement
      if statement.Effect == "Allow" && length(setintersection(toset(flatten([statement.Action])), toset(["iam:CreateRole", "iam:*", "*", "iam:PutRolePermissionsBoundary", "iam:UpdateAssumeRolePolicy"]))) > 0
    ]) == 0
    error_message = "No Allow statement may grant role creation, trust changes or boundary changes."
  }

  assert {
    condition = length(setintersection(
      toset(flatten([for statement in jsondecode(aws_iam_role_policy.deploy.policy).Statement : flatten([statement.Action]) if statement.Effect == "Deny"])),
      toset(["iam:CreateRole", "iam:UpdateAssumeRolePolicy", "iam:PutRolePermissionsBoundary", "iam:DeleteRolePermissionsBoundary", "iam:AttachRolePolicy"]),
    )) == 5
    error_message = "Role creation, trust changes and boundary changes must be denied explicitly."
  }
}

run "given_any_services_when_applied_then_every_manage_statement_names_only_the_paddock" {
  variables {
    aws_services = ["cloudwatch", "dynamodb", "ecr", "events", "lambda", "logs", "s3", "secretsmanager", "sns", "sqs", "ssm"]
  }

  assert {
    condition = alltrue(flatten([
      for statement in jsondecode(aws_iam_role_policy.deploy.policy).Statement : [
        for resource in flatten([statement.Resource]) : can(regex("[:/]orders[-/]", resource))
      ] if startswith(try(statement.Sid, ""), "Manage") && statement.Sid != "ManageEventSourceMappings"
    ]))
    error_message = "A Manage statement may only name resources that start with the paddock name."
  }
}

run "given_dynamodb_is_not_chosen_when_applied_then_no_dynamodb_rights_exist" {
  variables {
    aws_services = ["lambda", "logs"]
  }

  assert {
    condition     = !strcontains(aws_iam_role_policy.deploy.policy, "dynamodb")
    error_message = "A service that is not chosen must not appear in the deploy policy."
  }

  assert {
    condition     = !strcontains(aws_iam_policy.boundary.policy, "dynamodb")
    error_message = "A service that is not chosen must not appear in the boundary."
  }
}

run "given_hostnames_when_applied_then_dns_changes_are_limited_to_those_names" {
  assert {
    condition = one([
      for statement in jsondecode(aws_iam_role_policy.deploy.policy).Statement : statement
      if try(statement.Sid, "") == "DnsOwnRecords"
    ]).Condition["ForAllValues:StringEquals"]["route53:ChangeResourceRecordSetsNormalizedRecordNames"] == ["api.apps.example.com"]
    error_message = "DNS changes must be limited to the paddock's own hostnames."
  }
}

run "given_no_hostnames_when_applied_then_no_dns_rights_exist" {
  variables {
    hostnames = []
  }

  assert {
    condition     = !strcontains(aws_iam_role_policy.deploy.policy, "route53:ChangeResourceRecordSets")
    error_message = "A paddock without hostnames must not change DNS."
  }
}

run "given_runtime_roles_when_applied_then_each_carries_the_boundary" {
  variables {
    runtime_roles = ["api", "token"]
  }

  assert {
    condition     = alltrue([for role in aws_iam_role.runtime : role.permissions_boundary == aws_iam_policy.boundary.arn])
    error_message = "Every runtime role must carry the paddock boundary."
  }

  assert {
    condition     = toset([for role in aws_iam_role.runtime : role.name]) == toset(["orders-api", "orders-token"])
    error_message = "Runtime roles must be named <paddock>-<role>."
  }

  assert {
    condition     = alltrue([for role in aws_iam_role.runtime : role.path == "/paddock/runtime/"])
    error_message = "Runtime roles must sit under /paddock/runtime/, outside the CI path that the state bucket lets through."
  }
}

run "given_every_service_when_applied_then_policies_fit_the_iam_size_limits" {
  variables {
    aws_services = ["apigateway", "cloudwatch", "dynamodb", "ecr", "events", "kms", "lambda", "logs", "s3", "secretsmanager", "sns", "sqs", "ssm"]
    reads_from   = ["identity", "catalog"]
    hostnames    = ["api.apps.example.com", "admin.apps.example.com"]
  }

  # Role inline policies share 10,240 characters; a managed policy holds
  # 6,144. Both limits count characters without whitespace, and jsonencode
  # writes none.
  assert {
    condition     = length(aws_iam_role_policy.deploy.policy) <= 10240
    error_message = "The deploy policy must fit the 10,240-character inline limit."
  }

  assert {
    condition     = length(aws_iam_role_policy.plan[0].policy) <= 10240
    error_message = "The plan policy must fit the 10,240-character inline limit."
  }

  assert {
    condition     = length(aws_iam_policy.boundary.policy) <= 6144
    error_message = "The boundary must fit the 6,144-character managed policy limit."
  }
}

run "given_the_name_account_when_planned_then_it_is_rejected" {
  command = plan

  variables {
    name = "account"
  }

  expect_failures = [var.name]
}

run "given_hostnames_without_a_zone_when_planned_then_it_is_rejected" {
  command = plan

  variables {
    account = {
      state_bucket      = "example-terraform-state-123456789012"
      oidc_provider_arn = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
    }
  }

  expect_failures = [aws_iam_role_policy.deploy]
}

run "given_a_budget_without_emails_when_planned_then_it_is_rejected" {
  command = plan

  variables {
    monthly_budget_usd = 10
  }

  expect_failures = [aws_budgets_budget.monthly]
}

run "given_a_budget_when_applied_then_it_filters_on_the_paddock_tag" {
  variables {
    monthly_budget_usd  = 10
    budget_alert_emails = ["alerts@example.com"]
  }

  assert {
    condition     = one(aws_budgets_budget.monthly[0].cost_filter).values == ["user:Paddock$orders"]
    error_message = "The budget must filter on the Paddock tag with the paddock's name."
  }
}
