# Module: Infrastructure
# All the AWS plumbing declared as code — DynamoDB table, two Lambda functions, an HTTP API via API Gateway, an EventBridge schedule for daily digests, SES sender verification, and a remote Terraform state backend with locking.

# variables.tf — Declares all tuneable inputs for the deployment: AWS region, DynamoDB table name, the sender email address, and the notification recipient. Sensitive values must be supplied at plan/apply time and must never be committed to source control.
# variables.tf
# ---------------------------------------------------------------
# All tuneable inputs for the TaskFlow deployment.
# Sensitive vars have no defaults — supply via terraform.tfvars
# (gitignored) or via TF_VAR_* environment variables in CI.
#
# terraform.tfvars.example (copy → terraform.tfvars, DO NOT COMMIT):
#   aws_region     = "us-east-1"
#   table_name     = "tasks"
#   ses_from_email = "sender@example.com"
#   notify_email   = "ops@example.com"
# ---------------------------------------------------------------

variable "aws_region" {
  description = "AWS region for all resources."
  type        = string
  default     = "us-east-1"
}

variable "table_name" {
  description = "Name of the DynamoDB tasks table."
  type        = string
  default     = "tasks"
}

variable "ses_from_email" {
  description = "SES-verified sender email address used by the notification Lambda."
  type        = string
  sensitive   = true
}

variable "notify_email" {
  description = "Recipient email address for the daily overdue-task digest."
  type        = string
  sensitive   = true
}

# backend.tf — Tells Terraform to store its state file safely in an S3 bucket with encryption, and use a DynamoDB table to prevent two people applying changes at the same time.
# backend.tf
# ---------------------------------------------------------------
# Remote state in S3 with DynamoDB locking.
# Prerequisites (provisioned once, outside this config):
#   - S3 bucket: versioning ON, server-side encryption ON,
#     Block Public Access ON.
#   - DynamoDB table: name = <lock-table>, hash key = LockID (S).
# Replace ALL <placeholder> values before running terraform init.
# ---------------------------------------------------------------

terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    # Replace with your pre-existing state bucket name.
    bucket = "<your-terraform-state-bucket>"

    # Path within the bucket for this workspace's state file.
    key = "taskflow/terraform.tfstate"

    # Must match the region where the bucket and lock table live.
    region = "<your-state-bucket-region>"

    # Replace with your pre-existing DynamoDB lock table name.
    dynamodb_table = "<your-terraform-lock-table>"

    # Encrypt state at rest using the bucket's default KMS/SSE key.
    encrypt = true
  }
}

provider "aws" {
  region = var.aws_region
}

# aws_dynamodb_table.tasks — Creates the DynamoDB table that stores all tasks. Uses on-demand billing so you only pay per request, enables automatic backups so you can restore to any point in the last 35 days, and encrypts all data at rest.
# dynamodb.tf
# ---------------------------------------------------------------
# DynamoDB table for TaskFlow task storage.
# ---------------------------------------------------------------

resource "aws_dynamodb_table" "tasks" {
  name         = var.table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "id"

  attribute {
    name = "id"
    type = "S"
  }

  attribute {
    name = "status"
    type = "S"
  }

  # GSI enables efficient status-filtered queries in TaskRepository.find().
  global_secondary_index {
    name            = "status-index"
    hash_key        = "status"
    projection_type = "KEYS_ONLY"
  }

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled = true
  }

  tags = {
    Project = "TaskFlow"
    ManagedBy = "Terraform"
  }
}

# aws_lambda_function.api — Packages and deploys the API Lambda that handles HTTP requests from API Gateway. Gives it just enough permissions to read/write the tasks table and nothing more, plus the ability to send emails via SES.
# lambda_api.tf
# ---------------------------------------------------------------
# IAM role shared by both Lambda functions (least-privilege).
# ---------------------------------------------------------------

data "aws_iam_policy_document" "lambda_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda_exec" {
  name               = "taskflow-lambda-exec"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
  tags = {
    Project   = "TaskFlow"
    ManagedBy = "Terraform"
  }
}

# Basic execution role — allows Lambda to write CloudWatch Logs.
resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Inline policy: DynamoDB PutItem + Scan scoped to the tasks table.
data "aws_iam_policy_document" "dynamodb_access" {
  statement {
    sid    = "TasksDynamoDBAccess"
    effect = "Allow"
    actions = [
      "dynamodb:PutItem",
      "dynamodb:Scan",
    ]
    resources = [
      aws_dynamodb_table.tasks.arn,
      "${aws_dynamodb_table.tasks.arn}/index/*",
    ]
  }
}

resource "aws_iam_role_policy" "dynamodb_access" {
  name   = "taskflow-dynamodb-access"
  role   = aws_iam_role.lambda_exec.id
  policy = data.aws_iam_policy_document.dynamodb_access.json
}

# Inline policy: SES SendEmail (SES does not support resource-level ARNs
# for send actions in all regions, so '*' is used per AWS documentation).
data "aws_iam_policy_document" "ses_access" {
  statement {
    sid       = "SESSendEmail"
    effect    = "Allow"
    actions   = ["ses:SendEmail"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "ses_access" {
  name   = "taskflow-ses-access"
  role   = aws_iam_role.lambda_exec.id
  policy = data.aws_iam_policy_document.ses_access.json
}

# ---------------------------------------------------------------
# Deployment package — zip the project root at plan time.
# In CI, replace with a pre-built zip uploaded to S3.
# ---------------------------------------------------------------

data "archive_file" "lambda_zip" {
  type        = "zip"
  source_dir  = "${path.root}/../"
  output_path = "${path.root}/dist/taskflow.zip"
  excludes = [
    ".git",
    ".terraform",
    "infra",
    "__pycache__",
    "*.pyc",
    "tests",
  ]
}

# ---------------------------------------------------------------
# API Lambda function.
# ---------------------------------------------------------------

resource "aws_lambda_function" "api" {
  function_name    = "taskflow-api"
  role             = aws_iam_role.lambda_exec.arn
  runtime          = "python3.12"
  handler          = "handler.lambda_handler"
  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  memory_size      = 256
  # 29 s = API Gateway maximum integration timeout.
  timeout          = 29

  environment {
    variables = {
      DYNAMODB_TABLE  = aws_dynamodb_table.tasks.name
      SES_FROM_EMAIL  = var.ses_from_email
      NOTIFY_EMAIL    = var.notify_email
      AWS_SES_REGION  = var.aws_region
    }
  }

  tags = {
    Project   = "TaskFlow"
    ManagedBy = "Terraform"
  }

  depends_on = [
    aws_iam_role_policy_attachment.lambda_basic,
    aws_iam_role_policy.dynamodb_access,
    aws_iam_role_policy.ses_access,
  ]
}

# ---------------------------------------------------------------
# Direct function URL — simple alternative to API Gateway,
# useful for testing or internal tooling (IAM auth disabled here;
# enable auth_type = "AWS_IAM" for production direct-URL use).
# ---------------------------------------------------------------

resource "aws_lambda_function_url" "api" {
  function_name      = aws_lambda_function.api.function_name
  authorization_type = "NONE"
}

output "lambda_api_function_url" {
  description = "Direct Lambda function URL (bypasses API Gateway)."
  value       = aws_lambda_function_url.api.function_url
}

# aws_lambda_function.notify — Deploys the scheduled Lambda that checks for overdue tasks and sends the daily digest email. An EventBridge Scheduler rule fires it every morning at 08:00 UTC with a 5-minute flexible window to smooth AWS capacity.
# lambda_notify.tf
# ---------------------------------------------------------------
# Notify Lambda + EventBridge Scheduler for daily digest.
# ---------------------------------------------------------------

resource "aws_lambda_function" "notify" {
  function_name    = "taskflow-notify"
  role             = aws_iam_role.lambda_exec.arn
  runtime          = "python3.12"
  handler          = "handler.notify_handler"
  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  memory_size      = 128
  timeout          = 60

  environment {
    variables = {
      DYNAMODB_TABLE = aws_dynamodb_table.tasks.name
      SES_FROM_EMAIL = var.ses_from_email
      NOTIFY_EMAIL   = var.notify_email
      AWS_SES_REGION = var.aws_region
    }
  }

  tags = {
    Project   = "TaskFlow"
    ManagedBy = "Terraform"
  }

  depends_on = [
    aws_iam_role_policy_attachment.lambda_basic,
    aws_iam_role_policy.dynamodb_access,
    aws_iam_role_policy.ses_access,
  ]
}

# ---------------------------------------------------------------
# IAM role for EventBridge Scheduler to invoke the notify Lambda.
# ---------------------------------------------------------------

data "aws_iam_policy_document" "scheduler_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["scheduler.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "scheduler_exec" {
  name               = "taskflow-scheduler-exec"
  assume_role_policy = data.aws_iam_policy_document.scheduler_assume_role.json
  tags = {
    Project   = "TaskFlow"
    ManagedBy = "Terraform"
  }
}

data "aws_iam_policy_document" "scheduler_invoke" {
  statement {
    sid     = "InvokeNotifyLambda"
    effect  = "Allow"
    actions = ["lambda:InvokeFunction"]
    resources = [
      aws_lambda_function.notify.arn,
    ]
  }
}

resource "aws_iam_role_policy" "scheduler_invoke" {
  name   = "taskflow-scheduler-invoke"
  role   = aws_iam_role.scheduler_exec.id
  policy = data.aws_iam_policy_document.scheduler_invoke.json
}

# ---------------------------------------------------------------
# EventBridge Scheduler: daily at 08:00 UTC, flexible window 5 min.
# ---------------------------------------------------------------

resource "aws_scheduler_schedule" "daily_digest" {
  name                         = "taskflow-daily-digest"
  schedule_expression          = "cron(0 8 * * ? *)"
  schedule_expression_timezone = "UTC"

  flexible_time_window {
    mode                      = "FLEXIBLE"
    maximum_window_in_minutes = 5
  }

  target {
    arn      = aws_lambda_function.notify.arn
    role_arn = aws_iam_role.scheduler_exec.arn

    # Pass an empty JSON object; notify_handler ignores event contents.
    input = "{}"

    retry_policy {
      maximum_retry_attempts = 2
    }
  }
}

# aws_apigatewayv2_api.taskflow — Sets up the public HTTP API that routes GET and POST requests on the /tasks path to the API Lambda, and outputs the URL you call from a browser or mobile app.
# apigw.tf
# ---------------------------------------------------------------
# HTTP API (API Gateway v2) routing /tasks to the API Lambda.
# ---------------------------------------------------------------

resource "aws_apigatewayv2_api" "taskflow" {
  name          = "taskflow-http-api"
  protocol_type = "HTTP"
  description   = "TaskFlow REST API"

  # CORS: tighten allow_origins for production.
  cors_configuration {
    allow_origins = ["*"]
    allow_methods = ["GET", "POST", "OPTIONS"]
    allow_headers = ["Content-Type", "Authorization"]
    max_age       = 300
  }

  tags = {
    Project   = "TaskFlow"
    ManagedBy = "Terraform"
  }
}

# ---------------------------------------------------------------
# Lambda integration (AWS_PROXY, payload format 2.0).
# ---------------------------------------------------------------

resource "aws_apigatewayv2_integration" "api_lambda" {
  api_id                 = aws_apigatewayv2_api.taskflow.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.api.invoke_arn
  payload_format_version = "2.0"
  timeout_milliseconds   = 29000
}

# ---------------------------------------------------------------
# Routes.
# ---------------------------------------------------------------

resource "aws_apigatewayv2_route" "get_tasks" {
  api_id    = aws_apigatewayv2_api.taskflow.id
  route_key = "GET /tasks"
  target    = "integrations/${aws_apigatewayv2_integration.api_lambda.id}"
}

resource "aws_apigatewayv2_route" "post_tasks" {
  api_id    = aws_apigatewayv2_api.taskflow.id
  route_key = "POST /tasks"
  target    = "integrations/${aws_apigatewayv2_integration.api_lambda.id}"
}

# ---------------------------------------------------------------
# Default stage with auto-deploy and access logging.
# ---------------------------------------------------------------

resource "aws_cloudwatch_log_group" "apigw_access" {
  name              = "/aws/apigateway/taskflow"
  retention_in_days = 30

  tags = {
    Project   = "TaskFlow"
    ManagedBy = "Terraform"
  }
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.taskflow.id
  name        = "$default"
  auto_deploy = true

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.apigw_access.arn
    format = jsonencode({
      requestId      = "$context.requestId"
      sourceIp       = "$context.identity.sourceIp"
      httpMethod     = "$context.httpMethod"
      routeKey       = "$context.routeKey"
      status         = "$context.status"
      responseLength = "$context.responseLength"
      durationMs     = "$context.responseLatency"
    })
  }

  tags = {
    Project   = "TaskFlow"
    ManagedBy = "Terraform"
  }
}

# ---------------------------------------------------------------
# Lambda permission: allow API Gateway to invoke the API Lambda.
# ---------------------------------------------------------------

resource "aws_lambda_permission" "apigw_invoke_api" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.api.function_name
  principal     = "apigateway.amazonaws.com"
  # Scope to this specific API's ARN to avoid confused-deputy risk.
  source_arn    = "${aws_apigatewayv2_api.taskflow.execution_arn}/*/*"
}

# ---------------------------------------------------------------
# Output the public invoke URL.
# ---------------------------------------------------------------

output "api_invoke_url" {
  description = "Public HTTPS base URL for the TaskFlow API (append /tasks)."
  value       = aws_apigatewayv2_stage.default.invoke_url
}

# aws_ses_email_identity.sender — Registers the sender email address with Amazon SES so AWS will allow email to be sent from it. AWS sends a verification link to that address — the owner must click it before any emails can go out. Note: new AWS accounts are in the SES sandbox, which means you can only send to verified addresses; request production access in the SES console when ready.
# ses.tf
# ---------------------------------------------------------------
# SES sender email identity verification.
#
# IMPORTANT — SES Sandbox:
#   New AWS accounts are placed in the SES sandbox automatically.
#   In sandbox mode:
#     - Only VERIFIED email addresses can receive mail.
#     - Daily send quota is 200 emails, 1 email/second.
#   To send to arbitrary recipients, request production access:
#   https://docs.aws.amazon.com/ses/latest/dg/request-production-access.html
#
# After applying, AWS sends a verification email to var.ses_from_email.
# The owner MUST click the link before Lambda can send via this identity.
# ---------------------------------------------------------------

resource "aws_ses_email_identity" "sender" {
  email = var.ses_from_email
}

output "ses_identity_arn" {
  description = "ARN of the SES sender email identity."
  value       = aws_ses_email_identity.sender.arn
}
