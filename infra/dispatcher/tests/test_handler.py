"""Tests for the dispatcher's case handling, against an in-memory DynamoDB (moto) and a fake agent.

    pip install -r infra/dispatcher/tests/requirements.txt
    python -m pytest infra/dispatcher/tests
"""

import importlib
import json
import os
import sys
from pathlib import Path

import boto3
import pytest
from moto import mock_aws

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

TABLE_NAME = "test-cases"
FINDINGS = {
    "summary": "Points for a completed stay were never posted.",
    "evidence": [{"source": "loyalty___listStays", "detail": "Stay S-90551 for M-77310: accrual FAILED"}],
    "rootCause": "The accrual batch skipped the stay.",
    "proposedAction": {
        "tool": "loyalty___creditPoints",
        "arguments": {"memberId": "M-77310", "stayId": "S-90551", "points": 3465},
        "rationale": "Credit the missing accrual.",
    },
    "draftReply": "We have added the missing points.",
    "confidence": "high",
    "knowledgeSources": ["runbooks/loyalty-points.md"],
}


class FakeAgent:
    """Stands in for the bedrock-agentcore client and records each call."""

    def __init__(self, answer=None, error=None):
        self.answer = answer
        self.error = error
        self.calls = []

    def invoke_agent_runtime(self, **kwargs):
        self.calls.append({"session": kwargs["runtimeSessionId"], "payload": json.loads(kwargs["payload"])})
        if self.error:
            raise self.error

        class Body:
            def __init__(self, data):
                self.data = data

            def read(self):
                return json.dumps(self.data).encode()

        return {"response": Body(self.answer)}


@pytest.fixture()
def handler():
    os.environ.update({
        "AWS_DEFAULT_REGION": "us-east-1",
        "AWS_ACCESS_KEY_ID": "testing",
        "AWS_SECRET_ACCESS_KEY": "testing",
        "CASE_TABLE": TABLE_NAME,
        "AGENT_RUNTIME_ARN": "arn:aws:bedrock-agentcore:us-east-1:111122223333:runtime/test",
    })
    with mock_aws():
        boto3.client("dynamodb").create_table(
            TableName=TABLE_NAME,
            AttributeDefinitions=[{"AttributeName": "caseId", "AttributeType": "S"}],
            KeySchema=[{"AttributeName": "caseId", "KeyType": "HASH"}],
            BillingMode="PAY_PER_REQUEST",
        )
        module = importlib.import_module("handler")
        module = importlib.reload(module)
        yield module


def put_case(module, case_id="CASE-20261103-abc123", **attributes):
    module.TABLE.put_item(Item={"caseId": case_id, "status": "QUEUED", **attributes})
    return case_id


def job_record(case_id, message_id="msg-1"):
    body = {"caseId": case_id, "customerRef": "G-15562", "inquiry": "My points never showed up."}
    return {"Records": [{"messageId": message_id, "body": json.dumps(body)}]}


def decision_record(case_id, decision="APPROVED", version=1, message_id="dec-1"):
    body = {"caseId": case_id, "decision": decision, "proposalVersion": version}
    return {"Records": [{"messageId": message_id, "body": json.dumps(body)}]}


def case(module, case_id):
    return module.TABLE.get_item(Key={"caseId": case_id})["Item"]


def test_investigation_saves_findings(handler):
    case_id = put_case(handler)
    handler.AGENT = FakeAgent({"status": "ok", "caseId": case_id, "findings": FINDINGS})

    result = handler.investigate_handler(job_record(case_id), None)

    assert result == {"batchItemFailures": []}
    item = case(handler, case_id)
    assert item["status"] == "PENDING_APPROVAL"
    assert int(item["proposalVersion"]) == 1
    assert json.loads(item["proposedAction"])["tool"] == "loyalty___creditPoints"
    session = handler.AGENT.calls[0]["session"]
    assert session.startswith(case_id) and len(session) >= 33


def test_investigation_error_is_retried_then_failed(handler):
    case_id = put_case(handler)
    handler.AGENT = FakeAgent({"status": "error", "code": "InvestigationTimeout", "message": "too slow"})

    for _ in range(3):  # the same message, redelivered by SQS
        result = handler.investigate_handler(job_record(case_id), None)
        assert result == {"batchItemFailures": [{"itemIdentifier": "msg-1"}]}

    item = case(handler, case_id)
    assert item["status"] == "FAILED"
    assert int(item["attempts"]) == 3
    assert [c["session"][-1] for c in handler.AGENT.calls] == ["1", "2", "3"]


def test_second_job_for_same_case_is_skipped(handler):
    case_id = put_case(handler, status="INVESTIGATING", jobMessageId="msg-1")
    handler.AGENT = FakeAgent({"status": "ok", "findings": FINDINGS})

    result = handler.investigate_handler(job_record(case_id, message_id="msg-2"), None)

    assert result == {"batchItemFailures": []}
    assert handler.AGENT.calls == []


def test_reject(handler):
    case_id = put_case(handler, status="PENDING_APPROVAL", proposalVersion=1)
    handler.AGENT = FakeAgent()

    handler.apply_handler(decision_record(case_id, "REJECTED"), None)

    assert case(handler, case_id)["status"] == "REJECTED"
    assert handler.AGENT.calls == []


def test_approve_sends_stored_proposal_and_marks_applied(handler):
    case_id = put_case(handler, status="PENDING_APPROVAL", proposalVersion=1,
                       proposedAction=json.dumps(FINDINGS["proposedAction"]), findings=json.dumps(FINDINGS))
    handler.AGENT = FakeAgent({"status": "ok", "applyResult": {"outcome": "CREDITED"}, "knowledgeBaseUpdated": True})

    result = handler.apply_handler(decision_record(case_id), None)

    assert result == {"batchItemFailures": []}
    item = case(handler, case_id)
    assert item["status"] == "APPLIED"
    assert json.loads(item["applyResult"])["applyResult"]["outcome"] == "CREDITED"
    payload = handler.AGENT.calls[0]["payload"]
    assert payload["action"] == "apply"
    assert payload["proposedAction"] == FINDINGS["proposedAction"]


def test_stale_version_is_ignored(handler):
    case_id = put_case(handler, status="PENDING_APPROVAL", proposalVersion=2,
                       proposedAction=json.dumps(FINDINGS["proposedAction"]))
    handler.AGENT = FakeAgent({"status": "ok"})

    handler.apply_handler(decision_record(case_id, version=1), None)

    assert case(handler, case_id)["status"] == "PENDING_APPROVAL"
    assert handler.AGENT.calls == []


def test_redelivered_approval_marks_needs_review_without_calling_agent(handler):
    case_id = put_case(handler, status="APPLYING", proposalVersion=1,
                       proposedAction=json.dumps(FINDINGS["proposedAction"]))
    handler.AGENT = FakeAgent({"status": "ok"})

    result = handler.apply_handler(decision_record(case_id), None)

    assert result == {"batchItemFailures": []}
    assert case(handler, case_id)["status"] == "NEEDS_REVIEW"
    assert handler.AGENT.calls == []


def test_failed_apply_marks_needs_review(handler):
    case_id = put_case(handler, status="PENDING_APPROVAL", proposalVersion=1,
                       proposedAction=json.dumps(FINDINGS["proposedAction"]))
    handler.AGENT = FakeAgent({"status": "error", "code": "ApplyFailed", "message": "tool error"})

    result = handler.apply_handler(decision_record(case_id), None)

    assert result == {"batchItemFailures": []}
    item = case(handler, case_id)
    assert item["status"] == "NEEDS_REVIEW"
    assert "ApplyFailed" in item["failureReason"]
