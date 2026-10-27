# The root an administrator keeps in one central repository. It holds the
# account layer and one paddock per service. paddock-init.sh applies it:
# the first run keeps state on the admin's machine, then moves it into the
# bucket this root creates.

terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0"
    }
  }

  # Partial configuration. paddock-init.sh passes every value at init,
  # because the bucket name holds the account id.
  backend "s3" {}
}

variable "aws_region" {
  description = "Set by paddock-init.sh: the admin's default region on the first run, the state bucket's region after."
  type        = string
}

variable "state_bucket_prefix" {
  description = "Start of the state bucket name."
  type        = string
}

variable "admin_principal_arns" {
  description = "ARN patterns of the administrators."
  type        = list(string)
}

variable "dns" {
  description = "Domain for paddock hostnames, and the parent zone to delegate from."
  type = object({
    domain         = string
    parent_zone_id = optional(string)
  })
  default = null
}

variable "activate_cost_allocation_tag" {
  description = "Set to true once the Paddock tag shows in billing data."
  type        = bool
  default     = false
}

variable "budget_alert_emails" {
  description = "Addresses for every paddock's budget alerts."
  type        = list(string)
  default     = []
}

variable "paddocks" {
  description = "One entry per service. The key is the paddock name."
  type = map(object({
    github_repository     = string
    github_subject_prefix = optional(string)
    aws_services          = optional(list(string), ["lambda", "logs", "apigateway"])
    runtime_roles         = optional(list(string), ["app"])
    hostnames             = optional(list(string), [])
    reads_from            = optional(list(string), [])
    monthly_budget_usd    = optional(number)
  }))
  default = {}
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      ManagedBy = "paddock"
      Stack     = "account"
    }
  }
}

module "account" {
  source = "../../modules/account"

  state_bucket_prefix          = var.state_bucket_prefix
  admin_principal_arns         = var.admin_principal_arns
  dns                          = var.dns
  activate_cost_allocation_tag = var.activate_cost_allocation_tag
}

module "paddock" {
  source   = "../../modules/paddock"
  for_each = var.paddocks

  name                  = each.key
  account               = module.account
  github_repository     = each.value.github_repository
  github_subject_prefix = each.value.github_subject_prefix
  aws_services          = each.value.aws_services
  runtime_roles         = each.value.runtime_roles
  hostnames             = each.value.hostnames
  reads_from            = each.value.reads_from
  monthly_budget_usd    = each.value.monthly_budget_usd
  budget_alert_emails   = var.budget_alert_emails
}

output "state_bucket" {
  description = "Bucket that holds every state file in the account."
  value       = module.account.state_bucket
}

output "zone_name_servers" {
  description = "Add these as an NS record in the parent zone if dns.parent_zone_id is not set."
  value       = module.account.zone_name_servers
}

output "paddocks" {
  description = "Roles and repository variables per paddock."
  value = {
    for name, paddock in module.paddock : name => {
      deploy_role_arn   = paddock.deploy_role_arn
      plan_role_arn     = paddock.plan_role_arn
      runtime_role_arns = paddock.runtime_role_arns
      github_variables  = paddock.github_variables
    }
  }
}

# paddock-init.sh prints this after every apply.
output "github_variable_commands" {
  description = "gh commands that set each paddock repository's variables."
  value       = join("\n\n", [for paddock in module.paddock : paddock.github_variable_commands])
}
