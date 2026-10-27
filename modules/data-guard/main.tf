terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0"
    }
  }
}

variable "paddock" {
  description = "Name of the paddock that owns the resource."
  type        = string
}

variable "runtime_roles" {
  description = "Runtime roles of the paddock that may use the data. Names as given to modules/paddock, for example [\"app\"]."
  type        = list(string)
}

variable "resource_arns" {
  description = "ARNs the statements apply to. For an S3 bucket, give both the bucket ARN and <bucket ARN>/*."
  type        = list(string)
}

variable "use_actions" {
  description = "Actions that read or write the data, for example [\"dynamodb:GetItem\", \"dynamodb:PutItem\"]. Only the runtime roles and the admins may do them."
  type        = list(string)
}

variable "manage_actions" {
  description = "Actions that manage the resource itself, for example [\"dynamodb:UpdateTable\"]. Only the deploy role, the plan role and the admins may do them. Leave out the actions that change this policy, so a mistake in the lists can never lock everyone out of fixing it."
  type        = list(string)
  default     = []
}

variable "extra_use_principal_arns" {
  description = "Other principals that may use the data, such as another paddock's runtime role that reads a shared secret."
  type        = list(string)
  default     = []
}

data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

# The admins are published by modules/account. Reading them here keeps the
# list in one place.
data "aws_ssm_parameter" "admins" {
  name = "/account/public/admin-principal-arns"
}

locals {
  role_prefix = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:role"
  admins      = split(",", nonsensitive(data.aws_ssm_parameter.admins.value))

  use_principals = concat(
    [for role in var.runtime_roles : "${local.role_prefix}/paddock/runtime/${var.paddock}-${role}"],
    var.extra_use_principal_arns,
    local.admins,
  )

  manage_principals = concat(
    [
      "${local.role_prefix}/paddock/ci/${var.paddock}-deploy",
      "${local.role_prefix}/paddock/ci/${var.paddock}-plan",
    ],
    local.admins,
  )

  # AWS services that act on a resource, such as CloudFront reading a bucket
  # through origin access control, carry no principal ARN. Without this
  # condition the Deny would block them too. They still need an Allow from
  # the resource's owner.
  not_a_service = { BoolIfExists = { "aws:PrincipalIsAWSService" = "false" } }

  statements = concat(
    [{
      Sid       = "OnlyRuntimeRolesUseTheData"
      Effect    = "Deny"
      Principal = "*"
      Action    = var.use_actions
      Resource  = var.resource_arns
      Condition = merge(local.not_a_service, {
        StringNotLike = { "aws:PrincipalArn" = local.use_principals }
      })
    }],
    length(var.manage_actions) == 0 ? [] : [{
      Sid       = "OnlyCiRolesManageTheResource"
      Effect    = "Deny"
      Principal = "*"
      Action    = var.manage_actions
      Resource  = var.resource_arns
      Condition = merge(local.not_a_service, {
        StringNotLike = { "aws:PrincipalArn" = local.manage_principals }
      })
    }],
  )
}

output "statements" {
  description = "The Deny statements, to merge with the resource's own Allow statements."
  value       = local.statements
}

output "policy_json" {
  description = "A complete resource policy that holds only the Deny statements."
  value       = jsonencode({ Version = "2012-10-17", Statement = local.statements })
}

output "use_principal_arns" {
  description = "Principals that may use the data."
  value       = local.use_principals
}

output "manage_principal_arns" {
  description = "Principals that may manage the resource."
  value       = local.manage_principals
}
