# Architecture

![Architecture: inquiry agents on Amazon ECS](figure-2-architecture.png)

## Components

| Component | Service | Role |
| --- | --- | --- |
| Support portal (stand-in) | `scripts/console.py` | Creates the case, sends the job, shows findings, sends the decision |
| Case item | Amazon DynamoDB | One item per case. Stands in for the ticket in the team's support system |
| Jobs queue, decisions queue | Amazon SQS (standard, each with a DLQ) | Carry work from the portal to the agents |
| Inquiry agents | WSO2 Integrator on Amazon ECS (Fargate, ARM64, two tasks) | Investigate (read-only) and apply one approved change |
| Model and guardrail | Amazon Bedrock (Converse API) | Reasoning; personal data masked in output |
| Knowledge base | Amazon Bedrock managed knowledge base | Runbooks and policies (S3 data source), resolved cases (custom data source) |
| Tool endpoint | Amazon Bedrock AgentCore Gateway | One MCP endpoint for all tools, Cognito client-credentials inbound |
| Internal systems | WSO2 Integrator MCP servers on AgentCore Runtime | Reservation, loyalty and payment tools over synthetic data |

In the figure, the MCP servers sit in front of internal services. In this sample each MCP
server serves its own synthetic data from bundled JSON, so there are no separate internal
services to deploy. Salesforce, Elastic and ServiceNow are optional external gateway targets
and are not built here.

## Investigation flow (jobs queue)

1. The portal writes the case item (`QUEUED`) and sends the job to the jobs queue.
2. An agent task's jobs listener receives the message. The message stays hidden from other
   tasks for 15 minutes (visibility timeout), longer than the longest expected run.
3. The agent claims the case with a conditional update: `QUEUED` → `INVESTIGATING`, recording
   the SQS message ID and counting the attempt. A redelivery of the same message may claim the
   case again; a second job for the same case is skipped and deleted.
4. A stateless agent calls the model through the guardrail, searches the knowledge base, and
   uses only the gateway's read-only tools. Its proposal is then checked.
5. The agent saves findings, the proposed fix and the draft reply on the case, increments
   `proposalVersion`, and sets `PENDING_APPROVAL` (or `NO_ACTION_PROPOSED`).
6. Only after the save succeeds does it delete the SQS message.
7. If an attempt fails, the message becomes visible again after 60 seconds. After the third
   attempt the case is marked `FAILED` and SQS moves the message to the jobs DLQ.

## Approval flow (decisions queue)

1. The representative reviews the case and approves or rejects. The portal sends
   `{caseId, decision, proposalVersion}` to the decisions queue. Nothing else travels.
2. An agent task's decisions listener receives the message.
3. **Rejected:** `PENDING_APPROVAL` → `REJECTED`, if the version is current.
4. **Approved:**
   1. `PENDING_APPROVAL` → `APPLYING` with a conditional update (status and version must match).
   2. Load the proposal from the case (never from the message) and call that one write tool
      through the gateway with `approvalId = <caseId>#<proposalVersion>`.
   3. `APPLYING` → `APPLIED`, storing the tool's response.
   4. Add a resolved-case summary to the knowledge base's custom data source.
   5. Delete the message.
5. If a redelivered decision finds the case already `APPLYING`, an earlier attempt may have
   made the change. The agent does not call the tool again; it sets `NEEDS_REVIEW`.
6. If the write tool call fails, the outcome is unknown, so the case goes to `NEEDS_REVIEW`
   and the decision is not retried.
7. A decision that no longer matches the case (stale version, already decided) is logged and
   deleted. Other failures are retried after 60 seconds and go to the decisions DLQ after
   three receives.

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
| `status` | S | portal, agent |
| `job` | S (JSON) | portal |
| `jobMessageId`, `attempts` | S, N | agent (investigation claim) |
| `findings` | S (JSON) | agent |
| `proposedAction` | S (JSON, or `null`) | agent |
| `draftReply` | S | agent |
| `proposalVersion` | N | agent (incremented per saved investigation) |
| `applyResult` | S (JSON) | agent (apply) |
| `failureReason` | S | agent |
| `createdAt`, `updatedAt` | S | portal, agent |

In production this record would be the ticket in the team's support system, and the portal
would be that system's user interface.

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

Findings (saved on the case):

```json
{
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
```

## Long-running investigations

An investigation can take several minutes: several model turns, tool calls through the
gateway, and knowledge base searches. Two settings keep a job from being picked up twice:

- The jobs queue's visibility timeout and the listener's `jobVisibilitySeconds` are both
  900 seconds, above the longest expected run. Raise both together if needed.
- The investigation claim records the SQS message ID. If a job does become visible again while
  it is still running (or after a task stopped part way), only the same message can resume it,
  and the save is conditional on that claim.

Each listener receives one message at a time and waits for it to finish, so each task runs at
most one investigation and one decision at a time. Scale with the ECS service's desired count.

## Read-only during investigation

1. The investigation loads only the read tools (`ai:McpToolKit` with `permittedTools`).
2. It gets gateway tokens from the investigator Cognito client, which has only the read scope.
3. A proposal is only data until approved. The apply step calls the stored proposal, only if
   it names a tool on the write list, with tokens from the applier client (write scope).
4. Write tools require an `approvalId` and are idempotent per `approvalId`.

Gateway-side enforcement of scopes per tool is not configured in this sample (see Known limits
in the main README).
