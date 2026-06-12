# Module: dns
# Optional: gives the site a friendly custom name (like blockforge.example.com) with a proper certificate.

# aws_acm_certificate.site — The certificate proving the custom domain really belongs to this site.
resource "aws_acm_certificate" "site" {
  provider          = aws.us_east_1
  domain_name       = var.domain_name
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

# aws_route53_record.site_a — The signpost pointing the custom name at the delivery network.
resource "aws_route53_record" "site_a" {
  zone_id = data.aws_route53_zone.this.zone_id
  name    = var.domain_name
  type    = "A"

  alias {
    name                   = var.distribution_domain_name
    zone_id                = var.distribution_hosted_zone_id
    evaluate_target_health = false
  }
}
