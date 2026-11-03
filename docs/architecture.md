# Architecture

![Architecture: inquiry listener on Amazon ECS, inquiry agent on AgentCore Runtime](figure-2-architecture.png)

## Components

| Component | Service | Role |
| --- | --- | --- |
| Support portal (stand-in) | `scripts/console.py` | Creates the case, sends the job, shows findings, sends the decision |
| Case item | Amazon DynamoDB | One item per case. Stands in for the ticket in the team's support system |
| Jobs queue, decisions queue | Amazon SQS (standard, each with a DLQ) | Carry work from the portal |
| Inquiry listener | WSO2 Integrator on Amazon ECS (Fargate, ARM64, one task) | Reads both queues, owns the case status, calls the agent |
| Inquiry agent | WSO2 Integrator on Amazon Bedrock AgentCore Runtime | Investigates (read-only) or applies one approved change; holds no state |
| Model and guardrail | Amazon Bedrock (Converse API) | Reasoning; personal data masked in output |
| Knowledge base | Amazon Bedrock managed knowledge base | Runbooks and policies (S3 data source), resolved cases (custom data source) |
| Tool endpoint | Amazon Bedrock AgentCore Gateway | One MCP endpoint for all tools, Cognito client-credentials inbound |
| Internal systems | WSO2 Integrator MCP servers on AgentCore Runtime | Reservation, loyalty and payment tools over synthetic data |

The listener and the agent are separate projects with separate permissions:

- **Listener** (task role): the two queues, the case table, and `InvokeAgentRuntime` on the agent
  runtime.
- **Agent** (execution role): the model, the guardrail, the knowledge base, and the Cognito
  client secret.

Neither can do the other's job.

## Calling the agent

The listener calls `InvokeAgentRuntime` synchronously. It sends a SigV4-signed HTTPS request
with the ECS task role and waits for one JSON answer.

| Limit | Value |
| --- | --- |
| AgentCore Runtime synchronous request | 15 minutes (fixed). A streaming response may run for up to 60 minutes; this sample does not stream. |
| Agent investigation budget (`investigationTimeoutSeconds`) | 600 s |
| Listener waits for the agent (`agentTimeoutSeconds`) | 900 s |
| Queue visibility timeout (jobs and decisions) | 1200 s, above the 15-minute call limit |

Each agent call is a new runtime session with the session ID `<caseId>-<attempt>` (or
`<caseId>-apply-v<version>`), padded to at least 33 characters.

## Investigation flow (jobs queue)

1. The portal writes the case item (`QUEUED`) and sends the job to the jobs queue.
2. A jobs listener receives the message, which stays hidden for 20 minutes.
3. The listener claims the case with a conditional update: `QUEUED` → `INVESTIGATING`. The claim
   records the SQS message ID and counts the attempt. A redelivery of the same message may claim
   again; a second job for the same case is skipped and deleted.
4. It calls the agent with `{action: "investigate", caseId, job}`. The agent:
   - calls the model through the guardrail,
   - searches the knowledge base,
   - uses only the gateway's read-only tools,
   - checks its proposal and returns `{status: "ok", findings}`.
5. The listener saves the findings, the proposed fix and the draft reply, increments
   `proposalVersion`, and sets `PENDING_APPROVAL` (or `NO_ACTION_PROPOSED`).
6. Only after the save succeeds does it delete the SQS message.
7. If the call fails, the message is not deleted and becomes visible again after 60 seconds.
   After the third attempt the case is marked `FAILED` and SQS moves the message to the jobs DLQ.

## Approval flow (decisions queue)

1. The representative reviews the case and approves or rejects. The portal sends
   `{caseId, decision, proposalVersion}` to the decisions queue. Nothing else travels.
2. A decisions listener receives the message.
3. **Rejected:** `PENDING_APPROVAL` → `REJECTED`, if the version is current.
4. **Approved:**
   1. `PENDING_APPROVAL` → `APPLYING` with a conditional update (status and version must match).
   2. Load the proposal and findings from the case (never from the message).
   3. Call the agent with `{action: "apply", caseId, proposalVersion, proposedAction, findings}`.
   4. The agent calls exactly that one write tool through the gateway with
      `approvalId = <caseId>#<proposalVersion>`, adds the resolved case to the knowledge base,
      and returns the tool's response.
   5. `APPLYING` → `APPLIED`, storing the response. Then delete the message.
5. If a redelivered decision finds the case already `APPLYING`, an earlier attempt may have
   made the change. The listener does not call the agent again; it sets `NEEDS_REVIEW`.
6. If the agent call fails after the claim, the outcome is unknown, so the case goes to
   `NEEDS_REVIEW` and the decision is not retried.
7. A decision that no longer matches the case (stale version, already decided) is logged and
   deleted.

## Concurrency

An `sqs:Listener` receives one message at a time and waits until it is handled. The jobs service
is attached to five listeners and the decisions service to two, so one task keeps at most five
investigations and two decisions open at once. Extra messages wait in the queues, which keeps
the load on the model within its quotas. AgentCore Runtime starts a separate session for each
call.

## Case statuses

```
QUEUED -> INVESTIGATING -> PENDING_APPROVAL -> APPLYING -> APPLIED
                       \-> NO_ACTION_PROPOSED  |        \-> NEEDS_REVIEW
                       \-> FAILED              \-> REJECTED
```

## Case item

| Attribute | Type | Written by |
| --- | --- | --- |
| `caseId` | S (key) | portal |
| `status` | S | portal, listener |
| `job` | S (JSON) | portal |
| `jobMessageId`, `attempts` | S, N | listener (investigation claim) |
| `findings`, `proposedAction` | S (JSON) | listener, from the agent's answer |
| `draftReply` | S | listener, from the agent's answer |
| `proposalVersion` | N | listener (incremented per saved investigation) |
| `applyResult` | S (JSON) | listener, from the agent's answer |
| `failureReason` | S | listener |
| `createdAt`, `updatedAt` | S | portal, listener |

In production this record would be the ticket in the team's support system, and the portal
would be that system's user interface. The agent never reads or writes it.

## Messages

Job (jobs queue, and `job` on the case):

```json
{
  "caseId": "CASE-20261103-1a2b3c",
  "customerRef": "G-15562",
  "inquiry": "I stayed last weekend, but my loyalty points never showed up.",
  "channel": "chat",
  "context": {"memberId": "M-77310"},
  "submittedAt": "2026-11-03T09:15:00Z"
}
```

Decision (decisions queue):

```json
{"caseId": "CASE-20261103-1a2b3c", "decision": "APPROVED", "proposalVersion": 1}
```

Agent answer to `investigate`:

```json
{
  "status": "ok",
  "caseId": "CASE-20261103-1a2b3c",
  "findings": {
    "summary": "...",
    "evidence": [{"source": "loyalty___listStays", "detail": "Stay S-90551 ... accrual FAILED"}],
    "rootCause": "...",
    "proposedAction": {
      "tool": "loyalty___creditPoints",
      "arguments": {"memberId": "M-77310", "stayId": "S-90551", "points": 3465},
      "rationale": "..."
    },
    "draftReply": "...",
    "confidence": "high",
    "knowledgeSources": ["runbooks/loyalty-points.md", "policies/points-earning.md"]
  }
}
```

Agent error answer (either action):

```json
{"status": "error", "caseId": "CASE-20261103-1a2b3c", "code": "InvestigationTimeout", "message": "..."}
```

## Read-only during investigation

1. The investigation loads only the read tools (`ai:McpToolKit` with `permittedTools`).
2. It gets gateway tokens from the investigator Cognito client, which has only the read scope.
3. A proposal is only data until approved. The apply action receives the stored proposal from
   the listener. It calls the proposal only if it names a tool on the write list, using tokens
   from the applier client (write scope).
4. Write tools require an `approvalId` and are idempotent per `approvalId`.

Gateway-side enforcement of scopes per tool is not configured in this sample (see Known limits
in the main README).
