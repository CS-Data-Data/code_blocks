# blockforge-aws

Serverless AWS deployment for BlockForge: the app is served from a private S3 bucket through CloudFront, and an API Gateway + Lambda proxy keeps the LLM API key on the server.

## Architecture

Three Terraform feature modules: static-site (S3 + CloudFront OAC), llm-proxy (HTTP API + Python Lambda forwarding to Anthropic), dns (optional ACM cert in us-east-1 + Route53 aliases). A dev environment wires them together.

## Modules

### llm-proxy (`modules/llm_proxy/`)

A small relay that receives the app's AI requests and forwards them to Anthropic, adding the secret API key on the server so it never reaches anyone's browser.

- **aws_apigatewayv2_api.proxy** (resource): The public web address the app sends AI requests to.
- **aws_lambda_function.proxy** (resource): The worker that actually relays each request to Anthropic and returns the answer.
- **aws_iam_role.lambda** (resource): The permission badge the relay wears — it may write logs and nothing else.
- **var.anthropic_api_key** (variable): The secret key for the AI service, kept out of the code and out of browsers.

### static-site (`modules/static_site/`)

Hosts the BlockForge web page itself: a locked filing cabinet (S3) and a worldwide delivery network (CloudFront) that is the only one with a key.

- **aws_s3_bucket.site** (resource): Private storage holding the app's single HTML file.
- **aws_cloudfront_distribution.site** (resource): The delivery network that serves the page quickly and securely anywhere in the world.
- **aws_iam_policy_document.site_bucket_policy** (data): The rule saying 'only our delivery network may open the filing cabinet'.
- **output.site_url** (output): The finished website address, printed after deployment.

### dns (`modules/dns/`)

Optional: gives the site a friendly custom name (like blockforge.example.com) with a proper certificate.

- **aws_acm_certificate.site** (resource): The certificate proving the custom domain really belongs to this site.
- **aws_route53_record.site_a** (resource): The signpost pointing the custom name at the delivery network.

## References between blocks

- **static-site → static-site** — origin fetch (OAC): On a cache miss, CloudFront fetches index.html from the private bucket using a SigV4-signed request via the Origin Access Control. (value: Signed S3 GetObject)
- **static-site → static-site** — SourceArn condition: The bucket policy references the distribution's ARN so only this distribution can read objects. (value: distribution_arn)
- **llm-proxy → llm-proxy** — AWS_PROXY invoke: API Gateway wraps each HTTP request in a v2.0 event and invokes the Lambda synchronously. (value: APIGW HTTP event v2.0)
- **llm-proxy → llm-proxy** — env injection: The sensitive variable lands in the function's environment at deploy time; never in source or state outputs. (value: Lambda environment)
- **dns → static-site** — certificate_arn: The validated certificate ARN flows into the distribution's viewer_certificate so the custom domain serves real TLS. (value: acm_certificate_arn)
- **dns → static-site** — alias target: The Route53 alias record points the friendly domain at the distribution's domain name and zone. (value: alias)
