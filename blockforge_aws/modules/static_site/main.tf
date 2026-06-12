# Module: static-site
# Hosts the BlockForge web page itself: a locked filing cabinet (S3) and a worldwide delivery network (CloudFront) that is the only one with a key.

# aws_s3_bucket.site — Private storage holding the app's single HTML file.
resource "aws_s3_bucket" "site" {
  bucket_prefix = "${var.project_name}-${var.environment}-site-"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "site" {
  bucket                  = aws_s3_bucket.site.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_object" "app" {
  bucket       = aws_s3_bucket.site.id
  key          = "index.html"
  source       = var.app_source_path
  content_type = "text/html"
  etag         = filemd5(var.app_source_path)
}

# aws_cloudfront_distribution.site — The delivery network that serves the page quickly and securely anywhere in the world.
resource "aws_cloudfront_distribution" "site" {
  enabled             = true
  default_root_object = "index.html"
  aliases             = var.aliases

  origin {
    domain_name              = aws_s3_bucket.site.bucket_regional_domain_name
    origin_id                = "s3-site"
    origin_access_control_id = aws_cloudfront_origin_access_control.site.id
  }

  default_cache_behavior {
    target_origin_id       = "s3-site"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD", "OPTIONS"]
    cached_methods         = ["GET", "HEAD"]
    cache_policy_id        = data.aws_cloudfront_cache_policy.caching_optimized.id
    compress               = true
  }

  viewer_certificate {
    cloudfront_default_certificate = var.acm_certificate_arn == "" ? true : false
  }
}
