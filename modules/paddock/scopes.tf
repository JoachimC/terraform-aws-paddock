data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

data "aws_partition" "current" {}

locals {
  n         = var.name
  account   = data.aws_caller_identity.current.account_id
  region    = data.aws_region.current.region
  partition = data.aws_partition.current.partition
  arn       = "arn:${local.partition}"

  # Same paths as modules/account. The state bucket policy lets every role
  # under the CI path through; this module's own policies narrow each role to
  # its prefix.
  ci_role_path      = "/paddock/ci/"
  runtime_role_path = "/paddock/runtime/"

  state_bucket_arn  = "${local.arn}:s3:::${var.account.state_bucket}"
  state_prefix      = local.n
  state_key         = "${local.n}/terraform.tfstate"
  runtime_role_arns = "${local.arn}:iam::${local.account}:role${local.runtime_role_path}${local.n}-*"

  # Services whose resources carry a name the paddock chooses. The deploy
  # role may manage, and runtime roles may use, only resources whose name
  # starts with the paddock name. "named" lists those ARNs. "read" is what the
  # plan role may do on them. "global" lists the list and describe actions
  # that take no resource; they reveal names, not contents.
  named_services = {
    lambda = {
      named = [
        "${local.arn}:lambda:${local.region}:${local.account}:function:${local.n}-*",
        "${local.arn}:lambda:${local.region}:${local.account}:layer:${local.n}-*",
      ]
      read   = ["lambda:Get*", "lambda:List*"]
      global = ["lambda:List*", "lambda:GetAccountSettings", "lambda:GetLayerVersion"]
    }
    logs = {
      named = [
        "${local.arn}:logs:${local.region}:${local.account}:log-group:/aws/lambda/${local.n}-*",
        "${local.arn}:logs:${local.region}:${local.account}:log-group:/aws/apigateway/${local.n}-*",
        "${local.arn}:logs:${local.region}:${local.account}:log-group:/paddock/${local.n}/*",
      ]
      read   = ["logs:Describe*", "logs:ListTagsForResource", "logs:ListTagsLogGroup"]
      global = ["logs:DescribeLogGroups"]
    }
    dynamodb = {
      named = [
        "${local.arn}:dynamodb:${local.region}:${local.account}:table/${local.n}-*",
      ]
      read   = ["dynamodb:Describe*", "dynamodb:List*", "dynamodb:GetResourcePolicy"]
      global = ["dynamodb:ListTables", "dynamodb:DescribeLimits", "dynamodb:DescribeEndpoints"]
    }
    s3 = {
      # Bucket names are global, so the paddock name alone may clash with a
      # bucket in another account. Add the account id: <name>-<purpose>-<account>.
      named = [
        "${local.arn}:s3:::${local.n}-*",
        "${local.arn}:s3:::${local.n}-*/*",
      ]
      read   = ["s3:Get*", "s3:List*"]
      global = ["s3:ListAllMyBuckets"]
    }
    sqs = {
      named  = ["${local.arn}:sqs:${local.region}:${local.account}:${local.n}-*"]
      read   = ["sqs:Get*", "sqs:List*"]
      global = ["sqs:ListQueues"]
    }
    sns = {
      named  = ["${local.arn}:sns:${local.region}:${local.account}:${local.n}-*"]
      read   = ["sns:Get*", "sns:List*"]
      global = ["sns:ListTopics"]
    }
    secretsmanager = {
      # Secret names use a path: <name>/<secret>. The ARN ends in a random
      # suffix, which the trailing wildcard covers.
      named = ["${local.arn}:secretsmanager:${local.region}:${local.account}:secret:${local.n}/*"]
      # No GetSecretValue: a pull request workflow could print it. Set
      # secret values outside Terraform, or plan with the deploy role.
      read   = ["secretsmanager:Describe*", "secretsmanager:GetResourcePolicy", "secretsmanager:List*"]
      global = ["secretsmanager:ListSecrets", "secretsmanager:GetRandomPassword"]
    }
    ssm = {
      named  = ["${local.arn}:ssm:${local.region}:${local.account}:parameter/${local.n}/*"]
      read   = ["ssm:Get*", "ssm:Describe*", "ssm:ListTagsForResource"]
      global = ["ssm:DescribeParameters"]
    }
    ecr = {
      named  = ["${local.arn}:ecr:${local.region}:${local.account}:repository/${local.n}-*"]
      read   = ["ecr:Describe*", "ecr:Get*", "ecr:List*", "ecr:BatchGetImage", "ecr:BatchCheckLayerAvailability"]
      global = ["ecr:GetAuthorizationToken", "ecr:DescribeRegistry"]
    }
    events = {
      named  = ["${local.arn}:events:${local.region}:${local.account}:rule/${local.n}-*"]
      read   = ["events:Describe*", "events:List*"]
      global = ["events:ListRules"]
    }
    cloudwatch = {
      named  = ["${local.arn}:cloudwatch:${local.region}:${local.account}:alarm:${local.n}-*"]
      read   = ["cloudwatch:Describe*", "cloudwatch:Get*", "cloudwatch:ListTagsForResource"]
      global = ["cloudwatch:DescribeAlarms"]
    }
  }

  chosen_named_services = { for service, scope in local.named_services : service => scope if contains(var.aws_services, service) }

  # Every runtime role may write its function's logs, whether or not the
  # deploy role manages log groups, so a new function works on its first run.
  function_log_groups = [
    "${local.arn}:logs:${local.region}:${local.account}:log-group:/aws/lambda/${local.n}-*",
  ]

  apigateway       = contains(var.aws_services, "apigateway")
  kms              = contains(var.aws_services, "kms")
  publishes_dns    = length(var.hostnames) > 0
  apigateway_arn   = "${local.arn}:apigateway:${local.region}::"
  kms_key_arns     = "${local.arn}:kms:${local.region}:${local.account}:key/*"
  kms_alias_arns   = "${local.arn}:kms:${local.region}:${local.account}:alias/${local.n}-*"
  hosted_zone_arn  = "${local.arn}:route53:::hostedzone/${coalesce(var.account.zone_id, "none")}"
  domain_name_arns = flatten([for hostname in var.hostnames : ["${local.apigateway_arn}/domainnames/${hostname}", "${local.apigateway_arn}/domainnames/${hostname}/*"]])

  # API Gateway and KMS assign ids at creation, so a name cannot scope them.
  # The Paddock tag does: required on create, and checked on every later
  # call. REST API child resources (resources, methods, integrations,
  # deployments, stages) inherit the API's tags for this check.
  own_tag     = { StringEquals = { "aws:ResourceTag/Paddock" = local.n } }
  request_tag = { StringEquals = { "aws:RequestTag/Paddock" = local.n } }

  public_parameter_arns = concat(
    [
      "${local.arn}:ssm:${local.region}:${local.account}:parameter/account/public",
      "${local.arn}:ssm:${local.region}:${local.account}:parameter/account/public/*",
    ],
    flatten([for owner in var.reads_from : [
      "${local.arn}:ssm:${local.region}:${local.account}:parameter/${owner}/public",
      "${local.arn}:ssm:${local.region}:${local.account}:parameter/${owner}/public/*",
    ]]),
  )

  # Untag actions that could strip the Paddock tag, for the chosen services.
  # Adding the tag with another value is caught by the request-tag statement
  # instead.
  untag_actions = [for action in local.all_untag_actions : action if contains(var.aws_services, split(":", action)[0])]
  all_untag_actions = [
    "lambda:UntagResource",
    "dynamodb:UntagResource",
    "sqs:UntagQueue",
    "sns:UntagResource",
    "secretsmanager:UntagResource",
    "ssm:RemoveTagsFromResource",
    "logs:UntagResource",
    "logs:UntagLogGroup",
    "ecr:UntagResource",
    "kms:UntagResource",
    "events:UntagResource",
    "cloudwatch:UntagResource",
  ]
}
