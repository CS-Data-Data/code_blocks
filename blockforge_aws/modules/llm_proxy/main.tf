# Module: llm-proxy
# A small relay that receives the app's AI requests and forwards them to Anthropic, adding the secret API key on the server so it never reaches anyone's browser.

# aws_apigatewayv2_api.proxy — The public web address the app sends AI requests to.
resource "aws_apigatewayv2_api" "proxy" {
  name          = "${var.project_name}-${var.environment}-llm-proxy"
  protocol_type = "HTTP"

  cors_configuration {
    allow_origins = var.allowed_origins
    allow_methods = ["POST", "OPTIONS"]
    allow_headers = ["content-type", "x-api-key", "anthropic-version"]
    max_age       = 3600
  }
}

resource "aws_apigatewayv2_route" "messages" {
  api_id    = aws_apigatewayv2_api.proxy.id
  route_key = "POST /v1/messages"
  target    = "integrations/${aws_apigatewayv2_integration.lambda.id}"
}

# aws_lambda_function.proxy — The worker that actually relays each request to Anthropic and returns the answer.
resource "aws_lambda_function" "proxy" {
  function_name    = "${var.project_name}-${var.environment}-llm-proxy"
  role             = aws_iam_role.lambda.arn
  runtime          = "python3.12"
  handler          = "index.handler"
  filename         = data.archive_file.lambda.output_path
  source_code_hash = data.archive_file.lambda.output_base64sha256
  timeout          = 120

  environment {
    variables = {
      ANTHROPIC_API_KEY  = var.anthropic_api_key
      ANTHROPIC_BASE_URL = var.anthropic_base_url
    }
  }
}

# aws_iam_role.lambda — The permission badge the relay wears — it may write logs and nothing else.
resource "aws_iam_role" "lambda" {
  name               = "${var.project_name}-${var.environment}-llm-proxy-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
}

resource "aws_iam_role_policy_attachment" "lambda_basic_execution" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}
