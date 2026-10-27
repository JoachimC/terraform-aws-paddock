variable "name" {
  description = "Paddock name. It starts every resource name the paddock may manage, is the value of its Paddock tag, and is its state key prefix."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,22}[a-z0-9]$", var.name))
    error_message = "name must be 3 to 24 characters: lower-case letters, digits and hyphens, starting with a letter and ending with a letter or digit."
  }

  # The account layer keeps its state under account/ and publishes under
  # /account/public/. A paddock with this name would own both.
  validation {
    condition     = var.name != "account"
    error_message = "name must not be \"account\"; the account layer uses that name."
  }
}

variable "account" {
  description = "Outputs of modules/account. Pass the whole module: account = module.account."
  type = object({
    state_bucket             = string
    oidc_provider_arn        = string
    zone_id                  = optional(string)
    wildcard_certificate_arn = optional(string)
  })
}

variable "github_repository" {
  description = "The one repository whose workflows may assume this paddock's roles, as owner/name."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", var.github_repository))
    error_message = "github_repository must read owner/name."
  }
}

# GitHub can name the owner and repository by numeric id in the token
# subject, so a renamed or transferred repository cannot inherit a role. A
# token then reads "repo:OWNER@ID/NAME@ID:..." instead of "repo:OWNER/NAME:...".
# Read what a repository sends with:
#   gh api repos/OWNER/NAME/actions/oidc/customization/sub --jq .sub_claim_prefix
variable "github_subject_prefix" {
  description = "Immutable subject prefix that GitHub sends, if it sends one. Null means the plain repo:OWNER/NAME form only."
  type        = string
  default     = null

  validation {
    condition     = var.github_subject_prefix == null || can(regex("^repo:", var.github_subject_prefix))
    error_message = "github_subject_prefix must start with repo:, or be null."
  }
}

variable "deploy_branch" {
  description = "The one branch whose workflow runs may assume the deploy role."
  type        = string
  default     = "main"
}

variable "github_environment" {
  description = "GitHub environment that the deploy job runs in, if any. A job with an environment sends an environment subject, not a branch subject, so the trust policy must name it. Null means the job uses no environment."
  type        = string
  default     = null
}

variable "plan_role" {
  description = "Create a read-only plan role that pull request workflows may assume to run plan."
  type        = bool
  default     = true
}

variable "runtime_roles" {
  description = "Runtime role names. Each becomes <name>-<role> and is trusted by runtime_service. Give a function with different needs its own role."
  type        = list(string)
  default     = ["app"]

  validation {
    condition     = alltrue([for role in var.runtime_roles : can(regex("^[a-z][a-z0-9-]{0,30}$", role))])
    error_message = "Each runtime role name must be 1 to 31 characters: lower-case letters, digits and hyphens, starting with a letter."
  }

  validation {
    condition     = length(var.runtime_roles) == length(distinct(var.runtime_roles))
    error_message = "runtime_roles must not repeat a name."
  }

  # The deploy and plan roles are <name>-deploy and <name>-plan. A runtime
  # role with either name would collide with them.
  validation {
    condition     = !contains(var.runtime_roles, "deploy") && !contains(var.runtime_roles, "plan")
    error_message = "runtime_roles must not contain \"deploy\" or \"plan\"."
  }
}

variable "runtime_service" {
  description = "Service principal that runtime roles trust. Only Lambda is supported in this version."
  type        = string
  default     = "lambda.amazonaws.com"

  validation {
    condition     = var.runtime_service == "lambda.amazonaws.com"
    error_message = "runtime_service must be lambda.amazonaws.com in this version."
  }
}

variable "aws_services" {
  description = "AWS services this paddock may use. The deploy role may manage, and runtime roles may use, only resources of these services that carry the paddock's name or tag. See the README for each service's naming rule."
  type        = list(string)
  default     = ["lambda", "logs", "apigateway"]

  validation {
    condition = alltrue([for service in var.aws_services : contains([
      "apigateway", "cloudwatch", "dynamodb", "ecr", "events", "kms",
      "lambda", "logs", "s3", "secretsmanager", "sns", "sqs", "ssm",
    ], service)])
    error_message = "aws_services may contain only: apigateway, cloudwatch, dynamodb, ecr, events, kms, lambda, logs, s3, secretsmanager, sns, sqs, ssm."
  }
}

variable "hostnames" {
  description = "Hostnames the paddock may publish, each one level under the account's domain, for example api.apps.example.com. The deploy role may change DNS records and API Gateway custom domains for these names only."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for hostname in var.hostnames : can(regex("^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$", hostname))])
    error_message = "Each hostname must be a lower-case DNS name with no trailing dot."
  }
}

variable "reads_from" {
  description = "Other paddocks whose public data this paddock may read: SSM parameters under /<paddock>/public/, and secrets under <paddock>/shared/ that the owner's own resource policy also grants."
  type        = list(string)
  default     = []
}

variable "monthly_budget_usd" {
  description = "Monthly cost limit in US dollars for resources tagged with this paddock. Null creates no budget. The Paddock tag must be active as a cost allocation tag (modules/account) for the budget to see any cost."
  type        = number
  default     = null
}

variable "budget_alert_emails" {
  description = "Addresses that get the budget alerts: actual cost above 80% of the limit, and forecast above 100%."
  type        = list(string)
  default     = []
}
