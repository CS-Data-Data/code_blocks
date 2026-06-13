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

## Interactions

- **Storage Service → Storage Service** — hydrates via from_row: Inside find(), TaskRepository calls Task.from_row(item) for every item dict returned by DynamoDB table.scan(), converting raw DynamoDB item dicts into Task dataclass instances. (payload: DynamoDB item dict)
- **Storage Service → API Service** — provides list[Task]: TaskRepository.find(status='pending') produces the full list[Task] consumed by notify_handler, which then filters it to overdue tasks (due_date < utcnow()) and passes the resulting overdue list to EmailNotifier.send_overdue_digest(). The notifier accesses task.title and task.due_date from each Task instance to build the digest body. (payload: list[Task])
- **API Service → Notification Service** — send_overdue_digest: notify_handler filters the pending task list to overdue items and passes them to EmailNotifier.send_overdue_digest(overdue, to_email), which delivers the digest via Amazon SES. (payload: overdue task list + recipient)
- **API Service → Storage Service** — find / save: lambda_handler instantiates TaskRepository and calls either find(status) for GET /tasks or save(task) for POST /tasks, delegating all DynamoDB persistence to the repository. (payload: Task or status filter)
