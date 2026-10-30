variable "state_bucket_prefix" {
  description = "Start of the state bucket name. The bucket is <prefix>-terraform-state-<account id>, so the name is unique without a random suffix."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,30}[a-z0-9]$", var.state_bucket_prefix))
    error_message = "state_bucket_prefix must be 3 to 32 characters: lower-case letters, digits and hyphens, with no hyphen at either end."
  }
}

variable "admin_principal_arns" {
  description = "ARN patterns of the people who may run Terraform by hand and read any state. An IAM user reads as arn:aws:iam::ACCOUNT:user/NAME. An assumed role reads as arn:aws:iam::ACCOUNT:role/NAME, or arn:aws:iam::ACCOUNT:role/*NAME when the role has a path."
  type        = list(string)

  validation {
    condition     = length(var.admin_principal_arns) > 0
    error_message = "Name at least one administrator. Without one, nobody can run the account layer by hand."
  }

  validation {
    condition     = alltrue([for arn in var.admin_principal_arns : can(regex("^arn:aws[a-z-]*:iam::[0-9]{12}:(user|role)/", arn))])
    error_message = "Each admin_principal_arns entry must be an IAM user or role ARN (or pattern): arn:aws:iam::ACCOUNT:user/NAME or arn:aws:iam::ACCOUNT:role/NAME."
  }
}

variable "create_github_oidc_provider" {
  description = "Create the GitHub Actions OpenID Connect provider. An account holds one provider per issuer, so set this to false when the account already has one, and pass its ARN in existing_github_oidc_provider_arn."
  type        = bool
  default     = true
}

variable "existing_github_oidc_provider_arn" {
  description = "ARN of a GitHub Actions OpenID Connect provider that already exists in the account. Used only when create_github_oidc_provider is false."
  type        = string
  default     = null
}

variable "enable_account_public_access_block" {
  description = "Block public access for every S3 bucket in the account. A paddock can then never make a bucket public by mistake. Turn this off only if something else in the account needs a public bucket."
  type        = bool
  default     = true
}

variable "dns" {
  description = "The domain that paddock hostnames live under, for example apps.example.com. The module creates a hosted zone for it and a wildcard certificate. Set parent_zone_id to a Route 53 zone in this account to add the NS delegation there; leave it null to delegate by hand. Null skips DNS altogether."
  type = object({
    domain         = string
    parent_zone_id = optional(string)
  })
  default = null

  validation {
    condition     = var.dns == null || can(regex("^([a-z0-9]([a-z0-9-]*[a-z0-9])?\\.)+[a-z]{2,}$", var.dns.domain))
    error_message = "dns.domain must be a lower-case DNS name with no trailing dot, for example apps.example.com."
  }
}

variable "noncurrent_state_version_days" {
  description = "Days to keep a replaced version of a state file. Old versions are the way back from a bad apply."
  type        = number
  default     = 90

  validation {
    condition     = var.noncurrent_state_version_days >= 1
    error_message = "noncurrent_state_version_days must be at least 1."
  }
}

variable "activate_cost_allocation_tag" {
  description = "Activate the Paddock tag as a cost allocation tag, so budgets and Cost Explorer can filter by paddock. AWS only accepts this once the tag appears in billing data, up to 24 hours after the first tagged resource exists. Apply once with false, then set true."
  type        = bool
  default     = false
}

variable "create_api_gateway_service_linked_role" {
  description = "Create the API Gateway service-linked role. API Gateway needs it before the first custom domain, and a paddock's deploy role may not create it. An account holds one, so set this to false when the account already has it, or import it."
  type        = bool
  default     = true
}

variable "api_gateway_cloudwatch_logging" {
  description = "Create the account-wide role that lets API Gateway write access logs and execution logs to CloudWatch. It is one setting per account and region, so it lives here and not in a paddock."
  type        = bool
  default     = false
}
