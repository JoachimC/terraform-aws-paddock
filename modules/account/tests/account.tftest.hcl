# Runs with a mock provider: no AWS account and no credentials.

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
  mock_resource "aws_s3_bucket" {
    defaults = { arn = "arn:aws:s3:::example-terraform-state-123456789012" }
  }
  mock_resource "aws_iam_openid_connect_provider" {
    defaults = { arn = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com" }
  }
  mock_resource "aws_acm_certificate" {
    defaults = {
      arn = "arn:aws:acm:ap-southeast-2:123456789012:certificate/11111111-2222-3333-4444-555555555555"
      domain_validation_options = [{
        domain_name           = "*.apps.example.com"
        resource_record_name  = "_abc.apps.example.com."
        resource_record_type  = "CNAME"
        resource_record_value = "_def.acm-validations.aws."
      }]
    }
  }
}

variables {
  state_bucket_prefix  = "example"
  admin_principal_arns = ["arn:aws:iam::123456789012:user/admin"]
}

run "given_a_prefix_when_applied_then_the_bucket_name_holds_the_account_id" {
  assert {
    condition     = aws_s3_bucket.state.bucket == "example-terraform-state-123456789012"
    error_message = "The state bucket must be named <prefix>-terraform-state-<account id>."
  }
}

run "given_admins_when_applied_then_only_ci_roles_and_admins_reach_state" {
  assert {
    condition = toset(one([
      for statement in jsondecode(aws_s3_bucket_policy.state.policy).Statement : statement
      if statement.Sid == "DenyStateAccessToEveryoneButCiRolesAndAdmins"
      ]).Condition.StringNotLike["aws:PrincipalArn"]) == toset([
      "arn:aws:iam::123456789012:role/paddock/ci/*",
      "arn:aws:iam::123456789012:user/admin",
    ])
    error_message = "State access must be denied to everyone but the CI role path and the admins."
  }

  assert {
    condition = length([
      for statement in jsondecode(aws_s3_bucket_policy.state.policy).Statement : statement
      if statement.Effect == "Deny" && contains(flatten([statement.Action]), "s3:PutBucketPolicy")
    ]) == 0
    error_message = "The bucket policy must never deny bucket-policy actions, or a wrong admin pattern locks everyone out."
  }
}

run "given_any_settings_when_applied_then_plain_http_is_denied" {
  assert {
    condition = one([
      for statement in jsondecode(aws_s3_bucket_policy.state.policy).Statement : statement
      if statement.Sid == "DenyInsecureTransport"
    ]).Condition.Bool["aws:SecureTransport"] == "false"
    error_message = "Requests without TLS must be denied."
  }
}

run "given_no_dns_when_applied_then_no_zone_or_certificate_exists" {
  assert {
    condition     = length(aws_route53_zone.this) == 0 && length(aws_acm_certificate.wildcard) == 0
    error_message = "Without dns, the module must create no zone and no certificate."
  }

  assert {
    condition     = !contains(keys(aws_ssm_parameter.public), "zone-id")
    error_message = "Without dns, no zone id is published."
  }
}

run "given_dns_with_a_parent_zone_when_applied_then_the_zone_is_delegated_and_a_wildcard_is_issued" {
  variables {
    dns = {
      domain         = "apps.example.com"
      parent_zone_id = "Z0PARENT0000000000000"
    }
  }

  assert {
    condition     = aws_route53_record.delegation[0].zone_id == "Z0PARENT0000000000000" && aws_route53_record.delegation[0].type == "NS"
    error_message = "The zone must be delegated from the parent with an NS record."
  }

  assert {
    condition     = aws_acm_certificate.wildcard[0].domain_name == "*.apps.example.com"
    error_message = "One wildcard certificate keeps the paddock hostnames out of Certificate Transparency logs."
  }

  assert {
    condition     = contains(keys(aws_ssm_parameter.public), "wildcard-certificate-arn")
    error_message = "The certificate ARN must be published for the paddocks."
  }
}

run "given_admins_when_applied_then_they_are_published_for_data_guard" {
  assert {
    condition     = aws_ssm_parameter.public["admin-principal-arns"].type == "StringList" && aws_ssm_parameter.public["admin-principal-arns"].value == "arn:aws:iam::123456789012:user/admin"
    error_message = "modules/data-guard reads the admins from /account/public/admin-principal-arns."
  }
}

run "given_no_admins_when_planned_then_it_is_rejected" {
  command = plan

  variables {
    admin_principal_arns = []
  }

  expect_failures = [var.admin_principal_arns]
}

run "given_an_existing_provider_without_its_arn_when_planned_then_it_is_rejected" {
  command = plan

  variables {
    create_github_oidc_provider = false
  }

  expect_failures = [aws_s3_bucket_policy.state]
}
