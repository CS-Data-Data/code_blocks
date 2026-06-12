# Module: static-site
# Hosts the BlockForge web page itself: a locked filing cabinet (S3) and a worldwide delivery network (CloudFront) that is the only one with a key.

# output.site_url — The finished website address, printed after deployment.
output "site_url" {
  description = "URL of the deployed site"
  value       = "https://${aws_cloudfront_distribution.site.domain_name}"
}
