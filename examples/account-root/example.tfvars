# Copy to account.tfvars and fill in. *.tfvars other than this file are
# ignored by git, because the real values name your account.

state_bucket_prefix = "example"

# Read your own ARN with: aws sts get-caller-identity
# An IAM user goes in as it is. An assumed role reads as
# arn:aws:sts::ACCOUNT:assumed-role/ROLE/SESSION; write it here as
# arn:aws:iam::ACCOUNT:role/ROLE, or arn:aws:iam::ACCOUNT:role/*ROLE when the
# role has a path.
admin_principal_arns = ["arn:aws:iam::123456789012:user/admin"]

dns = {
  domain = "apps.example.com"
  # The Route 53 zone of the parent domain, example.com, when it is in this
  # account. Leave it out to add the NS record by hand from the
  # zone_name_servers output.
  parent_zone_id = "Z0123456789ABCDEFGHIJ"
}

budget_alert_emails = ["you@example.com"]

paddocks = {
  identity = {
    github_repository  = "example-org/identity"
    aws_services       = ["lambda", "logs", "apigateway", "dynamodb", "secretsmanager", "ssm"]
    runtime_roles      = ["api", "token"]
    hostnames          = ["auth.apps.example.com"]
    monthly_budget_usd = 10
  }

  orders = {
    github_repository  = "example-org/orders"
    aws_services       = ["lambda", "logs", "apigateway", "dynamodb", "secretsmanager"]
    hostnames          = ["api.apps.example.com"]
    reads_from         = ["identity"]
    monthly_budget_usd = 5
  }
}
