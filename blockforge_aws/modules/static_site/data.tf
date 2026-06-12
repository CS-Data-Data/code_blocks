# Module: static-site
# Hosts the BlockForge web page itself: a locked filing cabinet (S3) and a worldwide delivery network (CloudFront) that is the only one with a key.

# aws_iam_policy_document.site_bucket_policy — The rule saying 'only our delivery network may open the filing cabinet'.
data "aws_iam_policy_document" "site_bucket_policy" {
  statement {
    sid       = "AllowCloudFrontServicePrincipalReadOnly"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.site.arn}/*"]

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.site.arn]
    }
  }
}
