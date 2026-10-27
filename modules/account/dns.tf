# One hosted zone for every paddock hostname. A separate zone, not records in
# the parent zone, keeps a paddock's DNS rights away from the parent's other
# records, such as mail.
resource "aws_route53_zone" "this" {
  count = var.dns == null ? 0 : 1

  name    = var.dns.domain
  comment = "Paddock hostnames. Each paddock may change only its own names."
}

resource "aws_route53_record" "delegation" {
  count = var.dns == null ? 0 : (var.dns.parent_zone_id == null ? 0 : 1)

  zone_id = var.dns.parent_zone_id
  name    = var.dns.domain
  type    = "NS"
  ttl     = 172800
  records = aws_route53_zone.this[0].name_servers
}

# One wildcard certificate for every paddock. Certificate Transparency logs
# publish every name on a public certificate; a wildcard publishes only the
# wildcard, so the paddock hostnames stay out of the logs. ACM keeps the key,
# so sharing the certificate shares no key file.
resource "aws_acm_certificate" "wildcard" {
  count = var.dns == null ? 0 : 1

  domain_name               = "*.${var.dns.domain}"
  subject_alternative_names = [var.dns.domain]
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

# ACM validates *.<domain> and <domain> with the same DNS record, so one
# record covers both names. Taking either option is correct; a count keeps
# the plan free of keys that are unknown until the certificate exists.
locals {
  certificate_validation = var.dns == null ? null : tolist(aws_acm_certificate.wildcard[0].domain_validation_options)[0]
}

resource "aws_route53_record" "certificate_validation" {
  count = var.dns == null ? 0 : 1

  zone_id         = aws_route53_zone.this[0].zone_id
  name            = local.certificate_validation.resource_record_name
  type            = local.certificate_validation.resource_record_type
  ttl             = 300
  records         = [local.certificate_validation.resource_record_value]
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "wildcard" {
  count = var.dns == null ? 0 : 1

  certificate_arn         = aws_acm_certificate.wildcard[0].arn
  validation_record_fqdns = [aws_route53_record.certificate_validation[0].fqdn]
}
