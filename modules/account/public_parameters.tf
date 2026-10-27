# What a paddock's own Terraform needs from the account layer, published
# under /account/public/. Every deploy role may read this path. A paddock
# never reads the account layer's state, which holds more than it needs.
locals {
  public_parameters = merge(
    {
      "region"               = local.region
      "state-bucket"         = aws_s3_bucket.state.bucket
      "admin-principal-arns" = join(",", var.admin_principal_arns)
    },
    # Decided from the inputs, not from the ARN, which is unknown until the
    # provider exists: for_each needs its keys at plan time.
    !var.create_github_oidc_provider && var.existing_github_oidc_provider_arn == null ? {} : {
      "oidc-provider-arn" = local.oidc_provider_arn
    },
    var.dns == null ? {} : {
      "domain"                   = var.dns.domain
      "zone-id"                  = aws_route53_zone.this[0].zone_id
      "wildcard-certificate-arn" = aws_acm_certificate_validation.wildcard[0].certificate_arn
    },
  )
}

resource "aws_ssm_parameter" "public" {
  for_each = local.public_parameters

  name  = "/account/public/${each.key}"
  type  = each.key == "admin-principal-arns" ? "StringList" : "String"
  value = each.value
}
