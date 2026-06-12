"""Storage Service

The filing cabinet. Saves tasks to DynamoDB so they survive Lambda cold starts, and finds them again on request.

Technical notes: Repository pattern over AWS DynamoDB via boto3. Maps Task dataclasses to DynamoDB items; UUID-based partition keys; optional FilterExpression scans for status filtering. Table is provisioned externally (Terraform).
"""

from __future__ import annotations

# ------------------------------------------------------------
# TaskRepository (class)
# Saves tasks to DynamoDB and retrieves them, with optional filtering by status.
# ------------------------------------------------------------
import os
import uuid
import boto3
from boto3.dynamodb.conditions import Attr

class TaskRepository:
    """DynamoDB persistence for tasks."""

    def __init__(self, table_name: str = None):
        if table_name is None:
            table_name = os.environ.get('DYNAMODB_TABLE', 'tasks')
        self.table_name = table_name
        self.table = boto3.resource('dynamodb').Table(table_name)

    def save(self, task: 'Task') -> 'Task':
        if task.id is None:
            task.id = uuid.uuid4().hex
        item = {
            'id': task.id,
            'title': task.title,
            'due_date': task.due_date.isoformat(),
            'priority': task.priority,
            'status': task.status,
        }
        self.table.put_item(Item=item)
        return task

    def find(self, status: str | None = None) -> list:
        if status:
            response = self.table.scan(
                FilterExpression=Attr('status').eq(status)
            )
        else:
            response = self.table.scan()
        return [Task.from_row(item) for item in response.get('Items', [])]

# ------------------------------------------------------------
# Task (class)
# The shape of a single task: its id, title, due date, priority level, and whether it's done.
# ------------------------------------------------------------
from dataclasses import dataclass
from datetime import datetime

@dataclass
class Task:
    id: str | None
    title: str
    due_date: datetime
    priority: int = 2
    status: str = 'pending'

    @classmethod
    def from_row(cls, row) -> 'Task':
        return cls(
            id=row['id'],
            title=row['title'],
            due_date=datetime.fromisoformat(row['due_date']),
            priority=int(row['priority']),
            status=row['status']
        )
