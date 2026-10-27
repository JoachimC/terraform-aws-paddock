output "account_id" {
  description = "AWS account id."
  value       = local.account
}

output "region" {
  description = "Region of the state bucket, the zone's certificate and every paddock."
  value       = local.region
}

output "state_bucket" {
  description = "Bucket that holds the state of the account layer and of every paddock."
  value       = aws_s3_bucket.state.bucket
}

output "state_bucket_arn" {
  description = "ARN of the state bucket."
  value       = aws_s3_bucket.state.arn
}

output "account_state_key" {
  description = "State key of the account layer. No paddock role can reach it."
  value       = local.account_state_key
}

output "oidc_provider_arn" {
  description = "GitHub Actions OpenID Connect provider that every paddock's roles trust."
  value       = local.oidc_provider_arn
}

output "admin_principal_arns" {
  description = "ARN patterns of the administrators."
  value       = var.admin_principal_arns
}

output "domain" {
  description = "Domain that paddock hostnames live under, or null."
  value       = var.dns == null ? null : var.dns.domain
}

output "zone_id" {
  description = "Hosted zone id for the domain, or null."
  value       = var.dns == null ? null : aws_route53_zone.this[0].zone_id
}

output "zone_name_servers" {
  description = "Name servers of the zone. Add them as an NS record in the parent zone when parent_zone_id is not set."
  value       = var.dns == null ? [] : aws_route53_zone.this[0].name_servers
}

output "wildcard_certificate_arn" {
  description = "Validated wildcard certificate for *.<domain>, or null."
  value       = var.dns == null ? null : aws_acm_certificate_validation.wildcard[0].certificate_arn
}
