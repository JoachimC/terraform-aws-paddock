# No bucket in the account can be made public, by any paddock or by hand.
resource "aws_s3_account_public_access_block" "this" {
  count = var.enable_account_public_access_block ? 1 : 0

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Budgets and Cost Explorer can filter by a tag only once it is a cost
# allocation tag. See the variable for why this is a second apply.
resource "aws_ce_cost_allocation_tag" "paddock" {
  count = var.activate_cost_allocation_tag ? 1 : 0

  tag_key = "Paddock"
  status  = "Active"
}

# API Gateway writes logs to CloudWatch through one role per account and
# region. A paddock cannot own a setting that every other paddock shares.
resource "aws_iam_role" "api_gateway_cloudwatch" {
  count = var.api_gateway_cloudwatch_logging ? 1 : 0

  name = "paddock-api-gateway-cloudwatch"
  path = "/paddock/"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "apigateway.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = {
        StringEquals = { "aws:SourceAccount" = local.account }
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "api_gateway_cloudwatch" {
  count = var.api_gateway_cloudwatch_logging ? 1 : 0

  role       = aws_iam_role.api_gateway_cloudwatch[0].name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AmazonAPIGatewayPushToCloudWatchLogs"
}

resource "aws_api_gateway_account" "this" {
  count = var.api_gateway_cloudwatch_logging ? 1 : 0

  cloudwatch_role_arn = aws_iam_role.api_gateway_cloudwatch[0].arn
}

# API Gateway needs this role before it creates the first custom domain in
# the account. A paddock's deploy role may not create IAM roles, so without
# it the first custom domain fails. AWS keeps one per account.
resource "aws_iam_service_linked_role" "api_gateway" {
  count = var.create_api_gateway_service_linked_role ? 1 : 0

  aws_service_name = "ops.apigateway.amazonaws.com"
}
