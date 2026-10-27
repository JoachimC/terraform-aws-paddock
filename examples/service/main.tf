# A service's own root, applied by CI as the paddock's deploy role: one
# Lambda behind a Regional REST API on its own hostname, with a DynamoDB
# table that only the Lambda may use.
#
# Init from the repository variables that modules/paddock prints:
#   terraform init \
#     -backend-config="bucket=$TF_STATE_BUCKET" \
#     -backend-config="key=$TF_STATE_KEY" \
#     -backend-config="region=$AWS_REGION" \
#     -backend-config="use_lockfile=true" \
#     -backend-config="encrypt=true"

terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0"
    }
  }

  backend "s3" {}
}

variable "aws_region" {
  description = "Region of the account layer. CI passes the AWS_REGION repository variable."
  type        = string
}

variable "paddock" {
  description = "Paddock name. CI passes the PADDOCK repository variable."
  type        = string
  default     = "orders"
}

variable "hostname" {
  description = "One of the paddock's hostnames."
  type        = string
  default     = "api.apps.example.com"
}

variable "lambda_zip" {
  description = "Path to the built function package."
  type        = string
  default     = "build/bootstrap.zip"
}

provider "aws" {
  region = var.aws_region

  # The deploy role may create a resource only with this tag, and refuses
  # any other Paddock value. Every resource here gets it.
  default_tags {
    tags = {
      Paddock   = var.paddock
      ManagedBy = "terraform"
    }
  }
}

data "aws_caller_identity" "current" {}

data "aws_ssm_parameter" "zone_id" {
  name = "/account/public/zone-id"
}

data "aws_ssm_parameter" "wildcard_certificate_arn" {
  name = "/account/public/wildcard-certificate-arn"
}

locals {
  name = "${var.paddock}-api"
  # The bootstrap created this role; its ARN follows from the names.
  runtime_role_name = "${var.paddock}-app"
  runtime_role_arn  = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/paddock/runtime/${local.runtime_role_name}"
}

# --- Data ---------------------------------------------------------------------

resource "aws_dynamodb_table" "sessions" {
  name         = "${var.paddock}-sessions"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "pk"

  attribute {
    name = "pk"
    type = "S"
  }
}

module "sessions_guard" {
  source = "../../modules/data-guard"

  paddock        = var.paddock
  runtime_roles  = ["app"]
  resource_arns  = [aws_dynamodb_table.sessions.arn]
  use_actions    = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:DeleteItem", "dynamodb:Query", "dynamodb:Scan"]
  manage_actions = ["dynamodb:UpdateTable", "dynamodb:DeleteTable"]
}

resource "aws_dynamodb_resource_policy" "sessions" {
  resource_arn = aws_dynamodb_table.sessions.arn
  policy       = module.sessions_guard.policy_json
}

# The runtime role's own rights. The boundary from the bootstrap caps them.
resource "aws_iam_role_policy" "app" {
  name = "sessions"
  role = local.runtime_role_name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:DeleteItem", "dynamodb:Query"]
      Resource = aws_dynamodb_table.sessions.arn
    }]
  })
}

# --- Function -----------------------------------------------------------------

# Terraform creates the log group before the function, so it has a
# retention period and goes away with the stack.
resource "aws_cloudwatch_log_group" "api" {
  name              = "/aws/lambda/${local.name}"
  retention_in_days = 14
}

resource "aws_lambda_function" "api" {
  function_name    = local.name
  role             = local.runtime_role_arn
  filename         = var.lambda_zip
  source_code_hash = filebase64sha256(var.lambda_zip)
  runtime          = "provided.al2023"
  handler          = "bootstrap"
  architectures    = ["arm64"]
  publish          = true
  timeout          = 30

  environment {
    variables = {
      TABLE_NAME = aws_dynamodb_table.sessions.name
    }
  }

  depends_on = [aws_cloudwatch_log_group.api, aws_iam_role_policy.app]
}

resource "aws_lambda_alias" "live" {
  name             = "live"
  function_name    = aws_lambda_function.api.function_name
  function_version = aws_lambda_function.api.version
}

# --- API ----------------------------------------------------------------------

# Regional REST API: REST, not HTTP, because only REST APIs can stream a
# response. The default execute-api URL is off, so the API answers only on
# its own hostname.
resource "aws_api_gateway_rest_api" "this" {
  name                         = local.name
  disable_execute_api_endpoint = true

  endpoint_configuration {
    types = ["REGIONAL"]
  }
}

resource "aws_api_gateway_resource" "proxy" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  parent_id   = aws_api_gateway_rest_api.this.root_resource_id
  path_part   = "{proxy+}"
}

locals {
  # The root path and every sub-path go to the same function.
  api_resources = {
    root  = aws_api_gateway_rest_api.this.root_resource_id
    proxy = aws_api_gateway_resource.proxy.id
  }
}

resource "aws_api_gateway_method" "any" {
  for_each = local.api_resources

  rest_api_id   = aws_api_gateway_rest_api.this.id
  resource_id   = each.value
  http_method   = "ANY"
  authorization = "NONE" # The function checks the IdP token itself.
}

resource "aws_api_gateway_integration" "lambda" {
  for_each = local.api_resources

  rest_api_id             = aws_api_gateway_rest_api.this.id
  resource_id             = each.value
  http_method             = aws_api_gateway_method.any[each.key].http_method
  type                    = "AWS_PROXY"
  integration_http_method = "POST"
  uri                     = aws_lambda_alias.live.invoke_arn
  # For a streamed MCP response, switch this integration to the response
  # streaming mode; see the API Gateway response streaming guide.
}

resource "aws_api_gateway_deployment" "this" {
  rest_api_id = aws_api_gateway_rest_api.this.id

  triggers = {
    redeploy = sha1(jsonencode([aws_api_gateway_method.any, aws_api_gateway_integration.lambda]))
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_api_gateway_stage" "live" {
  rest_api_id   = aws_api_gateway_rest_api.this.id
  deployment_id = aws_api_gateway_deployment.this.id
  stage_name    = "live"
}

# A found endpoint must not be able to run up the bill.
resource "aws_api_gateway_method_settings" "throttle" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  stage_name  = aws_api_gateway_stage.live.stage_name
  method_path = "*/*"

  settings {
    throttling_rate_limit  = 10
    throttling_burst_limit = 20
  }
}

# Only this API may invoke the function. There is no function URL.
resource "aws_lambda_permission" "api" {
  statement_id  = "AllowThisApiOnly"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.api.function_name
  qualifier     = aws_lambda_alias.live.name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.this.execution_arn}/*/*"
}

# --- Hostname -----------------------------------------------------------------

resource "aws_api_gateway_domain_name" "this" {
  domain_name              = var.hostname
  regional_certificate_arn = data.aws_ssm_parameter.wildcard_certificate_arn.value
  security_policy          = "TLS_1_2"

  endpoint_configuration {
    types = ["REGIONAL"]
  }
}

resource "aws_api_gateway_base_path_mapping" "this" {
  api_id      = aws_api_gateway_rest_api.this.id
  stage_name  = aws_api_gateway_stage.live.stage_name
  domain_name = aws_api_gateway_domain_name.this.domain_name
}

resource "aws_route53_record" "this" {
  for_each = toset(["A", "AAAA"])

  zone_id = data.aws_ssm_parameter.zone_id.value
  name    = var.hostname
  type    = each.key

  alias {
    name                   = aws_api_gateway_domain_name.this.regional_domain_name
    zone_id                = aws_api_gateway_domain_name.this.regional_zone_id
    evaluate_target_health = false
  }
}

output "url" {
  description = "Public URL of the service."
  value       = "https://${var.hostname}/"
}
