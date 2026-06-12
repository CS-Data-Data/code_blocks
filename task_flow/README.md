# TaskFlow

A task management web application with a REST API, persistent storage, and email notifications for due tasks — deployed as AWS Lambda functions.

## Architecture

AWS Lambda handlers routed via API Gateway proxy events; repository pattern over DynamoDB via boto3; EventBridge Scheduler triggers overdue-task notifications via Amazon SES.

## Services

### Storage Service (`storage_service.py`)

The filing cabinet. Saves tasks to DynamoDB so they survive Lambda cold starts, and finds them again on request.

- **TaskRepository** (class): Saves tasks to DynamoDB and retrieves them, with optional filtering by status.
- **Task** (class): The shape of a single task: its id, title, due date, priority level, and whether it's done.

### Notification Service (`notification_service.py`)

Sends you an email listing every overdue task so nothing slips through the cracks — delivered via Amazon SES.

- **EmailNotifier** (class): Composes and sends a single digest email via Amazon SES listing every overdue task. Does nothing if there are no overdue tasks.

### API Service (`api_service.py`)

The front door. Handles incoming HTTP requests from API Gateway and scheduled EventBridge events to manage tasks and send overdue notifications.

- **lambda_handler** (function): Receives HTTP requests from API Gateway and routes them to the right task operation — listing tasks or creating a new one.
- **notify_handler** (function): Runs on a schedule to find all pending tasks that are past due and emails a digest to the configured recipient.

### Infrastructure (`infrastructure.py`)

All the AWS plumbing declared as code — DynamoDB table, two Lambda functions, an HTTP API via API Gateway, an EventBridge schedule for daily digests, SES sender verification, and a remote Terraform state backend with locking.

- **variables.tf** (config): Declares all tuneable inputs for the deployment: AWS region, DynamoDB table name, the sender email address, and the notification recipient. Sensitive values must be supplied at plan/apply time and must never be committed to source control.
- **backend.tf** (config): Tells Terraform to store its state file safely in an S3 bucket with encryption, and use a DynamoDB table to prevent two people applying changes at the same time.
- **aws_dynamodb_table.tasks** (config): Creates the DynamoDB table that stores all tasks. Uses on-demand billing so you only pay per request, enables automatic backups so you can restore to any point in the last 35 days, and encrypts all data at rest.
- **aws_lambda_function.api** (config): Packages and deploys the API Lambda that handles HTTP requests from API Gateway. Gives it just enough permissions to read/write the tasks table and nothing more, plus the ability to send emails via SES.
- **aws_lambda_function.notify** (config): Deploys the scheduled Lambda that checks for overdue tasks and sends the daily digest email. An EventBridge Scheduler rule fires it every morning at 08:00 UTC with a 5-minute flexible window to smooth AWS capacity.
- **aws_apigatewayv2_api.taskflow** (config): Sets up the public HTTP API that routes GET and POST requests on the /tasks path to the API Lambda, and outputs the URL you call from a browser or mobile app.
- **aws_ses_email_identity.sender** (config): Registers the sender email address with Amazon SES so AWS will allow email to be sent from it. AWS sends a verification link to that address — the owner must click it before any emails can go out. Note: new AWS accounts are in the SES sandbox, which means you can only send to verified addresses; request production access in the SES console when ready.

## Interactions

- **Storage Service → Storage Service** — hydrates via from_row: Inside find(), TaskRepository calls Task.from_row(item) for every item dict returned by DynamoDB table.scan(), converting raw DynamoDB item dicts into Task dataclass instances. (payload: DynamoDB item dict)
- **Storage Service → API Service** — provides list[Task]: TaskRepository.find(status='pending') produces the full list[Task] consumed by notify_handler, which then filters it to overdue tasks (due_date < utcnow()) and passes the resulting overdue list to EmailNotifier.send_overdue_digest(). The notifier accesses task.title and task.due_date from each Task instance to build the digest body. (payload: list[Task])
- **API Service → Notification Service** — send_overdue_digest: notify_handler filters the pending task list to overdue items and passes them to EmailNotifier.send_overdue_digest(overdue, to_email), which delivers the digest via Amazon SES. (payload: overdue task list + recipient)
- **API Service → Storage Service** — find / save: lambda_handler instantiates TaskRepository and calls either find(status) for GET /tasks or save(task) for POST /tasks, delegating all DynamoDB persistence to the repository. (payload: Task or status filter)
- **Infrastructure → Infrastructure** — routes HTTP → Lambda: aws_apigatewayv2_integration wires the HTTP API's GET /tasks and POST /tasks routes to aws_lambda_function.api via an AWS_PROXY integration. aws_lambda_permission grants API Gateway the right to invoke the function. (payload: Terraform resource reference)
- **Infrastructure → Infrastructure** — reads tasks table: aws_lambda_function.notify receives aws_dynamodb_table.tasks.name as the DYNAMODB_TABLE environment variable and is granted dynamodb:Scan on the table ARN via the shared IAM inline policy. (payload: Terraform resource reference)
- **Infrastructure → Infrastructure** — reads/writes tasks table: aws_lambda_function.api receives aws_dynamodb_table.tasks.name as the DYNAMODB_TABLE environment variable and is granted dynamodb:PutItem and dynamodb:Scan on the table ARN via the shared IAM inline policy. (payload: Terraform resource reference)
- **Infrastructure → Infrastructure** — sends via verified identity: aws_lambda_function.api is granted ses:SendEmail on '*' via the shared IAM inline policy and uses the SES_FROM_EMAIL env var matching the verified aws_ses_email_identity.sender address. (payload: Terraform resource reference)
- **Infrastructure → Infrastructure** — sends via verified identity: aws_lambda_function.notify is granted ses:SendEmail on '*' via the shared IAM inline policy and uses the SES_FROM_EMAIL env var matching the verified aws_ses_email_identity.sender address. (payload: Terraform resource reference)
