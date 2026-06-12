"""Notification Service

Sends you an email listing every overdue task so nothing slips through the cracks — delivered via Amazon SES.

Technical notes: EmailNotifier reads AWS_SES_REGION and SES_FROM_EMAIL from environment variables. send_overdue_digest(overdue, to) renders a plaintext digest of overdue Task objects and delivers it via boto3 SES send_email. Returns 0 if the list is empty, 1 after a successful send.
"""

from __future__ import annotations

# ------------------------------------------------------------
# EmailNotifier (class)
# Composes and sends a single digest email via Amazon SES listing every overdue task. Does nothing if there are no overdue tasks.
# ------------------------------------------------------------
import os
import boto3

class EmailNotifier:
    """Sends overdue-task digest emails via Amazon SES."""

    def __init__(self):
        self.region = os.environ.get('AWS_SES_REGION', 'us-east-1')
        self.from_email = os.environ.get('SES_FROM_EMAIL', '')
        self.ses = boto3.client('ses', region_name=self.region)

    def send_overdue_digest(self, overdue: list, to: str) -> int:
        if not overdue:
            return 0
        body = 'Overdue tasks:\n' + '\n'.join(
            f'- {t.title} (due {t.due_date:%Y-%m-%d})' for t in overdue
        )
        subject = f'{len(overdue)} overdue task(s)'
        self.ses.send_email(
            Source=self.from_email,
            Destination={'ToAddresses': [to]},
            Message={
                'Subject': {'Data': subject, 'Charset': 'UTF-8'},
                'Body': {
                    'Text': {'Data': body, 'Charset': 'UTF-8'}
                }
            }
        )
        return 1
