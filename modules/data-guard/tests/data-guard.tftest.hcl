# Runs with a mock provider: no AWS account and no credentials.

mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012" }
  }
  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }
  mock_data "aws_ssm_parameter" {
    defaults = { value = "arn:aws:iam::123456789012:user/admin" }
  }
}

variables {
  paddock        = "orders"
  runtime_roles  = ["app"]
  resource_arns  = ["arn:aws:dynamodb:ap-southeast-2:123456789012:table/orders-sessions"]
  use_actions    = ["dynamodb:GetItem", "dynamodb:PutItem"]
  manage_actions = ["dynamodb:UpdateTable"]
}

run "given_runtime_roles_when_applied_then_only_they_and_the_admins_use_the_data" {
  assert {
    condition = toset(jsondecode(output.policy_json).Statement[0].Condition.StringNotLike["aws:PrincipalArn"]) == toset([
      "arn:aws:iam::123456789012:role/paddock/runtime/orders-app",
      "arn:aws:iam::123456789012:user/admin",
    ])
    error_message = "Only the runtime roles and the admins may use the data."
  }
}

run "given_manage_actions_when_applied_then_only_ci_roles_and_admins_manage_the_resource" {
  assert {
    condition = toset(jsondecode(output.policy_json).Statement[1].Condition.StringNotLike["aws:PrincipalArn"]) == toset([
      "arn:aws:iam::123456789012:role/paddock/ci/orders-deploy",
      "arn:aws:iam::123456789012:role/paddock/ci/orders-plan",
      "arn:aws:iam::123456789012:user/admin",
    ])
    error_message = "Only the deploy role, the plan role and the admins may manage the resource."
  }
}

run "given_any_lists_when_applied_then_aws_services_are_not_denied" {
  assert {
    condition     = alltrue([for statement in jsondecode(output.policy_json).Statement : statement.Condition.BoolIfExists["aws:PrincipalIsAWSService"] == "false"])
    error_message = "The Deny statements must not block AWS services, which carry no principal ARN."
  }
}

run "given_no_manage_actions_when_applied_then_only_the_use_statement_exists" {
  variables {
    manage_actions = []
  }

  assert {
    condition     = length(jsondecode(output.policy_json).Statement) == 1
    error_message = "With no manage actions there must be one statement."
  }
}
