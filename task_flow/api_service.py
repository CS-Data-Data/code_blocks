"""API Service

The front door. Handles incoming HTTP requests from API Gateway and scheduled EventBridge events to manage tasks and send overdue notifications.

Technical notes: Two AWS Lambda handler functions. lambda_handler routes API Gateway proxy events: GET /tasks calls TaskRepository.find() and returns a JSON list; POST /tasks parses the body, constructs a Task, calls TaskRepository.save(), and returns the saved task as JSON. notify_handler is triggered by EventBridge Scheduler: calls TaskRepository.find(status='pending'), filters tasks where due_date < datetime.utcnow(), and calls EmailNotifier.send_overdue_digest().
"""

from __future__ import annotations

# ------------------------------------------------------------
# lambda_handler (function)
# Receives HTTP requests from API Gateway and routes them to the right task operation — listing tasks or creating a new one.
# ------------------------------------------------------------
import json
import os
from datetime import datetime
from decimal import Decimal

def _serialize(obj):
    """JSON serializer for objects not serializable by default."""
    if isinstance(obj, datetime):
        return obj.isoformat()
    if isinstance(obj, Decimal):
        return int(obj) if obj % 1 == 0 else float(obj)
    raise TypeError(f'Type {type(obj)} not serializable')

def lambda_handler(event: dict, context) -> dict:
    """API Gateway proxy handler for task CRUD operations."""
    repo = TaskRepository()
    method = event.get('httpMethod', '')
    path = event.get('path', '')
    headers = {'Content-Type': 'application/json'}

    try:
        if path == '/tasks' and method == 'GET':
            params = event.get('queryStringParameters') or {}
            status = params.get('status', None)
            tasks = repo.find(status=status)
            body = json.dumps(
                [{'id': t.id, 'title': t.title, 'due_date': t.due_date,
                  'priority': t.priority, 'status': t.status}
                 for t in tasks],
                default=_serialize
            )
            return {'statusCode': 200, 'headers': headers, 'body': body}

        elif path == '/tasks' and method == 'POST':
            payload = json.loads(event.get('body') or '{}')
            task = Task(
                id=None,
                title=payload['title'],
                due_date=datetime.fromisoformat(payload['due_date']),
                priority=int(payload.get('priority', 2)),
                status=payload.get('status', 'pending')
            )
            saved = repo.save(task)
            body = json.dumps(
                {'id': saved.id, 'title': saved.title,
                 'due_date': saved.due_date, 'priority': saved.priority,
                 'status': saved.status},
                default=_serialize
            )
            return {'statusCode': 201, 'headers': headers, 'body': body}

        else:
            return {'statusCode': 405, 'headers': headers,
                    'body': json.dumps({'error': 'Method Not Allowed'})}

    except Exception as exc:
        return {'statusCode': 500, 'headers': headers,
                'body': json.dumps({'error': str(exc)})}

# ------------------------------------------------------------
# notify_handler (function)
# Runs on a schedule to find all pending tasks that are past due and emails a digest to the configured recipient.
# ------------------------------------------------------------
import os
from datetime import datetime

def notify_handler(event: dict, context) -> dict:
    """EventBridge-triggered handler that sends overdue task digest via SES."""
    repo = TaskRepository()
    notifier = EmailNotifier()
    to_email = os.environ['NOTIFY_EMAIL']

    pending = repo.find(status='pending')
    now = datetime.utcnow()
    overdue = [t for t in pending if t.due_date.replace(tzinfo=None) < now]

    sent = notifier.send_overdue_digest(overdue, to_email)
    return {'overdue_count': len(overdue), 'sent': sent}
