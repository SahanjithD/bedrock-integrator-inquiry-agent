"""Lambda dispatcher between Step Functions and the inquiry agent on AgentCore Runtime.

Step Functions calls this function with the `.waitForTaskToken` pattern. The function starts
one invocation of the agent and returns as soon as the agent answers "accepted". The agent
reports the real result to Step Functions with the task token.

Why a dispatcher: the Step Functions integration for Amazon Bedrock AgentCore supports only
the Request Response pattern, not Wait for a Callback with a task token.
TODO(verify): replace this function with a direct state machine task if the integration
gains callback support.
"""

import json
import logging
import os
import uuid

import boto3
from botocore.exceptions import BotoCoreError, ClientError

LOGGER = logging.getLogger()
LOGGER.setLevel(logging.INFO)

AGENT_RUNTIME_ARN = os.environ.get("AGENT_RUNTIME_ARN", "")
AGENT_RUNTIME_QUALIFIER = os.environ.get("AGENT_RUNTIME_QUALIFIER", "DEFAULT")
REQUIRED_FIELDS = ("action", "taskToken", "caseId")

_client = boto3.client("bedrock-agentcore")


class DispatchFailed(Exception):
    """The runtime did not accept the invocation. The state machine retries this error."""


class InvalidInvocation(Exception):
    """The state machine passed a malformed payload. Not retried."""


def handler(event, _context):
    payload = event.get("payload") or {}
    missing = [name for name in REQUIRED_FIELDS if not payload.get(name)]
    if missing:
        raise InvalidInvocation(f"payload is missing {', '.join(missing)}")
    if not AGENT_RUNTIME_ARN:
        raise InvalidInvocation("AGENT_RUNTIME_ARN is not set")

    # A new runtime session per invocation keeps every run isolated.
    # Session IDs must be at least 33 characters long.
    session_id = f"{payload['caseId']}-{payload['action']}-{uuid.uuid4().hex}"
    LOGGER.info("Dispatching %s for case %s (session %s)", payload["action"], payload["caseId"], session_id)

    try:
        response = _client.invoke_agent_runtime(
            agentRuntimeArn=AGENT_RUNTIME_ARN,
            qualifier=AGENT_RUNTIME_QUALIFIER,
            runtimeSessionId=session_id,
            contentType="application/json",
            accept="application/json",
            payload=json.dumps(payload).encode("utf-8"),
        )
        body = response["response"].read()
    except (ClientError, BotoCoreError) as err:
        raise DispatchFailed(f"InvokeAgentRuntime failed: {err}") from err

    try:
        ack = json.loads(body or b"{}")
    except json.JSONDecodeError as err:
        raise DispatchFailed("The agent's reply was not JSON") from err
    if ack.get("status") != "accepted":
        raise DispatchFailed(f"The agent did not accept the invocation: {ack}")

    return {"runtimeSessionId": session_id, "caseId": payload["caseId"], "action": payload["action"]}
