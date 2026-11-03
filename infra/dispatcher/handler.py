"""Lambda dispatcher between the SQS queues and the inquiry agent on AgentCore Runtime.

Two handlers, each fed by its own SQS event source mapping (batch size 1, partial batch
responses on):

- investigate_handler (jobs queue): claims the case (QUEUED -> INVESTIGATING), calls the agent
  synchronously with action "investigate", saves the findings, and sets PENDING_APPROVAL.
- apply_handler (decisions queue): sets REJECTED, or claims the case
  (PENDING_APPROVAL -> APPLYING), loads the approved proposal from the case (never from the
  message), calls the agent with action "apply", and sets APPLIED.

A message that fails is reported in batchItemFailures, so SQS retries it after the visibility
timeout and moves it to the DLQ after three receives.

The agent call is synchronous. AgentCore Runtime ends such a request after 15 minutes, and so
does Lambda, so the agent stops an investigation after 10 minutes and this function waits at
most AGENT_READ_TIMEOUT seconds.
"""

import json
import logging
import os
from datetime import datetime, timezone

import boto3
from botocore.config import Config
from botocore.exceptions import ClientError

LOGGER = logging.getLogger()
LOGGER.setLevel(logging.INFO)

CASE_TABLE = os.environ["CASE_TABLE"]
AGENT_RUNTIME_ARN = os.environ["AGENT_RUNTIME_ARN"]
AGENT_RUNTIME_QUALIFIER = os.environ.get("AGENT_RUNTIME_QUALIFIER", "DEFAULT")
AGENT_READ_TIMEOUT = int(os.environ.get("AGENT_READ_TIMEOUT", "870"))
MAX_ATTEMPTS = int(os.environ.get("MAX_ATTEMPTS", "3"))
MIN_SESSION_ID_LENGTH = 33

TABLE = boto3.resource("dynamodb").Table(CASE_TABLE)
# One attempt per call: a retried InvokeAgentRuntime would run the work twice. SQS retries instead.
# TODO(verify): the Lambda runtime's bundled boto3 includes the bedrock-agentcore client; if not,
# package a newer boto3 with the function.
AGENT = boto3.client(
    "bedrock-agentcore",
    config=Config(read_timeout=AGENT_READ_TIMEOUT, connect_timeout=10, retries={"total_max_attempts": 1}),
)


class AgentError(Exception):
    """The agent answered with status "error"."""


# ---------------------------------------------------------------------------
# Handlers
# ---------------------------------------------------------------------------

def investigate_handler(event, _context):
    return _process_batch(event, process_job)


def apply_handler(event, _context):
    return _process_batch(event, process_decision)


def _process_batch(event, process):
    failures = []
    for record in event.get("Records", []):
        try:
            process(record)
        except Exception:  # noqa: BLE001 - every failure is retried by SQS
            LOGGER.exception("Message %s failed; SQS will retry it", record.get("messageId"))
            failures.append({"itemIdentifier": record["messageId"]})
    return {"batchItemFailures": failures}


# ---------------------------------------------------------------------------
# Investigation
# ---------------------------------------------------------------------------

def process_job(record):
    job = json.loads(record["body"])
    case_id = job["caseId"]
    message_id = record["messageId"]

    attempts = claim_for_investigation(case_id, message_id)
    if attempts is None:
        LOGGER.info("Case %s is not waiting for this job; skipping", case_id)
        return

    try:
        result = invoke_agent(
            {"action": "investigate", "caseId": case_id, "job": job},
            session_id(case_id, "investigate", f"attempt{attempts}"),
        )
    except Exception as err:
        if attempts >= MAX_ATTEMPTS:
            # Last attempt: SQS moves the message to the DLQ after this receive.
            mark_investigation_failed(case_id, str(err))
        raise

    findings = result["findings"]
    if not save_findings(case_id, message_id, findings):
        LOGGER.warning("Findings for %s not saved: the claim moved to another attempt", case_id)
        return
    LOGGER.info("Case %s investigated; proposal: %s", case_id,
                (findings.get("proposedAction") or {}).get("tool", "none"))


def claim_for_investigation(case_id, message_id):
    """QUEUED -> INVESTIGATING. A redelivery of the same job message may claim again.

    Returns the attempt count, or None if the case is not waiting for this job.
    """
    try:
        response = TABLE.update_item(
            Key={"caseId": case_id},
            UpdateExpression="SET #status = :investigating, jobMessageId = :mid, updatedAt = :now "
                             "ADD attempts :one",
            ConditionExpression="#status = :queued OR (#status = :investigating AND jobMessageId = :mid)",
            ExpressionAttributeNames={"#status": "status"},
            ExpressionAttributeValues={
                ":investigating": "INVESTIGATING", ":queued": "QUEUED",
                ":mid": message_id, ":one": 1, ":now": now(),
            },
            ReturnValues="ALL_NEW",
        )
    except ClientError as err:
        if is_condition_failure(err):
            return None
        raise
    return int(response["Attributes"]["attempts"])


def save_findings(case_id, message_id, findings):
    """INVESTIGATING -> PENDING_APPROVAL (or NO_ACTION_PROPOSED), new proposal version."""
    action = findings.get("proposedAction")
    try:
        TABLE.update_item(
            Key={"caseId": case_id},
            UpdateExpression="SET #status = :next, findings = :findings, proposedAction = :action, "
                             "draftReply = :reply, updatedAt = :now ADD proposalVersion :one",
            ConditionExpression="#status = :investigating AND jobMessageId = :mid",
            ExpressionAttributeNames={"#status": "status"},
            ExpressionAttributeValues={
                ":next": "PENDING_APPROVAL" if action else "NO_ACTION_PROPOSED",
                ":findings": json.dumps(findings),
                ":action": json.dumps(action),
                ":reply": findings.get("draftReply", ""),
                ":investigating": "INVESTIGATING", ":mid": message_id,
                ":one": 1, ":now": now(),
            },
        )
    except ClientError as err:
        if is_condition_failure(err):
            return False
        raise
    return True


def mark_investigation_failed(case_id, reason):
    conditional_status(case_id, "FAILED", ["QUEUED", "INVESTIGATING"], reason=reason)


# ---------------------------------------------------------------------------
# Decisions
# ---------------------------------------------------------------------------

def process_decision(record):
    decision = json.loads(record["body"])
    case_id = decision["caseId"]
    version = int(decision["proposalVersion"])
    choice = decision["decision"]

    if choice == "REJECTED":
        if conditional_status(case_id, "REJECTED", ["PENDING_APPROVAL"], version=version):
            LOGGER.info("Case %s rejected", case_id)
        else:
            LOGGER.warning("Rejection for %s ignored: case is not waiting for version %s", case_id, version)
        return
    if choice != "APPROVED":
        raise ValueError(f"Unknown decision {choice!r}")

    if not conditional_status(case_id, "APPLYING", ["PENDING_APPROVAL"], version=version):
        case = get_case(case_id)
        if case and case.get("status") == "APPLYING":
            # A redelivered decision: the earlier attempt's outcome is unknown. Do not call again.
            mark_needs_review(case_id, "The decision was received again while the case was APPLYING.")
            LOGGER.warning("Case %s marked NEEDS_REVIEW; the agent was not called again", case_id)
        else:
            LOGGER.warning("Approval for %s ignored: case is not waiting for version %s", case_id, version)
        return

    # From here on the case is APPLYING. Load the proposal from the case, never from the message.
    case = get_case(case_id)
    proposal = json.loads(case.get("proposedAction") or "null")
    findings = json.loads(case.get("findings") or "null")
    if not proposal:
        mark_needs_review(case_id, "The case has no stored proposal.")
        return

    payload = {"action": "apply", "caseId": case_id, "proposalVersion": version, "proposedAction": proposal}
    if findings:
        payload["findings"] = findings
    try:
        result = invoke_agent(payload, session_id(case_id, "apply", f"v{version}"))
    except Exception as err:  # noqa: BLE001 - the outcome of the write is unknown
        mark_needs_review(case_id, f"Apply failed: {err}")
        LOGGER.error("Apply for %s failed; case marked NEEDS_REVIEW: %s", case_id, err)
        return

    # If this update fails, SQS retries the decision, which then finds the case APPLYING and
    # marks it NEEDS_REVIEW without calling the agent again.
    if not conditional_status(case_id, "APPLIED", ["APPLYING"], apply_result=result):
        LOGGER.warning("Case %s left APPLYING before it could be marked APPLIED", case_id)
        return
    LOGGER.info("Case %s applied", case_id)


def mark_needs_review(case_id, reason):
    conditional_status(case_id, "NEEDS_REVIEW", ["APPLYING"], reason=reason)


# ---------------------------------------------------------------------------
# Shared
# ---------------------------------------------------------------------------

def invoke_agent(payload, runtime_session_id):
    """Calls the inquiry agent synchronously and returns its JSON answer."""
    response = AGENT.invoke_agent_runtime(
        agentRuntimeArn=AGENT_RUNTIME_ARN,
        qualifier=AGENT_RUNTIME_QUALIFIER,
        runtimeSessionId=runtime_session_id,
        contentType="application/json",
        accept="application/json",
        payload=json.dumps(payload).encode("utf-8"),
    )
    body = json.loads(response["response"].read() or b"{}")
    if body.get("status") != "ok":
        raise AgentError(f"{body.get('code', 'UnknownError')}: {body.get('message', body)}")
    return body


def session_id(case_id, action, suffix):
    """A runtime session ID per case and attempt. AgentCore requires at least 33 characters."""
    value = f"{case_id}-{action}-{suffix}"
    if len(value) < MIN_SESSION_ID_LENGTH:
        value = value + "-" + "0" * (MIN_SESSION_ID_LENGTH - len(value) - 1)
    return value


def conditional_status(case_id, new_status, expected, version=None, reason=None, apply_result=None):
    """Moves a case to new_status if its status is in expected (and the version matches).

    Returns False if the condition did not hold.
    """
    names = {"#status": "status"}
    values = {":new": new_status, ":now": now()}
    update = "SET #status = :new, updatedAt = :now"
    placeholders = []
    for index, status in enumerate(expected):
        values[f":s{index}"] = status
        placeholders.append(f":s{index}")
    condition = f"#status IN ({', '.join(placeholders)})"
    if version is not None:
        condition += " AND proposalVersion = :version"
        values[":version"] = version
    if reason is not None:
        update += ", failureReason = :reason"
        values[":reason"] = reason[:1000]
    if apply_result is not None:
        update += ", applyResult = :result"
        values[":result"] = json.dumps(apply_result)
    try:
        TABLE.update_item(
            Key={"caseId": case_id},
            UpdateExpression=update,
            ConditionExpression=condition,
            ExpressionAttributeNames=names,
            ExpressionAttributeValues=values,
        )
    except ClientError as err:
        if is_condition_failure(err):
            return False
        raise
    return True


def get_case(case_id):
    return TABLE.get_item(Key={"caseId": case_id}, ConsistentRead=True).get("Item")


def is_condition_failure(err):
    return err.response.get("Error", {}).get("Code") == "ConditionalCheckFailedException"


def now():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
