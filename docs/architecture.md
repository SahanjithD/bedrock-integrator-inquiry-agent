# Architecture (SQS → Lambda → AgentCore Runtime)

![Architecture: SQS, Lambda dispatcher and the inquiry agent on AgentCore Runtime](figure-2-architecture-lambda.png)

## Components

| Component | Service | Role |
| --- | --- | --- |
| Support portal (stand-in) | `scripts/console.py` | Creates the case, sends the job, shows findings, sends the decision |
| Case item | Amazon DynamoDB | One item per case. Stands in for the ticket in the team's support system |
| Jobs queue, decisions queue | Amazon SQS (standard, each with a DLQ) | Carry work from the portal |
| Dispatcher | AWS Lambda (Python 3.12), two functions | Own the case status; call the agent and wait for its answer |
| Inquiry agent | WSO2 Integrator on Amazon Bedrock AgentCore Runtime | Investigates (read-only) or applies one approved change; holds no state |
| Model and guardrail | Amazon Bedrock (Converse API) | Reasoning; personal data masked in output |
| Knowledge base | Amazon Bedrock managed knowledge base | Runbooks and policies (S3 data source), resolved cases (custom data source) |
| Tool endpoint | Amazon Bedrock AgentCore Gateway | One MCP endpoint for all tools, Cognito client-credentials inbound |
| Internal systems | WSO2 Integrator MCP servers on AgentCore Runtime | Reservation, loyalty and payment tools over synthetic data |

## Time limits

The dispatcher calls the agent synchronously and waits for the answer, so both 15-minute
limits apply:

| Limit | Value |
| --- | --- |
| AgentCore Runtime synchronous request | 15 minutes (fixed) |
| Lambda function timeout | 900 s (Lambda's maximum) |
| Dispatcher waits for the agent (`AGENT_READ_TIMEOUT`) | 870 s |
| Agent investigation budget (`investigationTimeoutSeconds`) | 600 s |
| Queue visibility timeout | 5400 s (6x the function timeout) |

An investigation that needs longer than 10 minutes does not fit this design; see the ECS
variant on the main branch.

## Investigation flow (jobs queue)

1. The portal writes the case item (`QUEUED`) and sends the job to the jobs queue.
2. The jobs queue's event source mapping invokes the `investigate` function with one message.
3. The function claims the case with a conditional update: `QUEUED` → `INVESTIGATING`. The claim
   records the SQS message ID and counts the attempt. A redelivery of the same message may claim
   again; a second job for the same case is skipped.
4. It calls `InvokeAgentRuntime` with `{action: "investigate", caseId, job}`. The runtime
   session ID is the case ID plus the attempt (at least 33 characters).
5. The agent calls the model through the guardrail, searches the knowledge base, and uses only
   the gateway's read-only tools. It checks its proposal and returns
   `{status: "ok", findings}`.
6. The function saves the findings, the proposed fix and the draft reply, increments
   `proposalVersion`, and sets `PENDING_APPROVAL` (or `NO_ACTION_PROPOSED`).
7. On any error the function reports the message as failed, and SQS retries it. After the
   third attempt the case is marked `FAILED` and SQS moves the message to the jobs DLQ.

## Approval flow (decisions queue)

1. The representative reviews the case and approves or rejects. The portal sends
   `{caseId, decision, proposalVersion}` to the decisions queue. Nothing else travels.
2. The decisions queue's event source mapping invokes the `apply` function.
3. **Rejected:** `PENDING_APPROVAL` → `REJECTED`, if the version is current.
4. **Approved:**
   1. `PENDING_APPROVAL` → `APPLYING` with a conditional update (status and version must match).
   2. Load the proposal from the case (never from the message).
   3. Call `InvokeAgentRuntime` with `{action: "apply", caseId, proposalVersion, proposedAction, findings}`.
   4. The agent calls exactly that one write tool through the gateway with
      `approvalId = <caseId>#<proposalVersion>`, adds the resolved case to the knowledge base,
      and returns the tool's response.
   5. `APPLYING` → `APPLIED`, storing the response.
5. If a redelivered decision finds the case already `APPLYING`, an earlier attempt may have made
   the change. The function does not call the agent again; it sets `NEEDS_REVIEW`.
6. If the agent call fails or returns an error after the claim, the outcome is unknown, so the
   case goes to `NEEDS_REVIEW` and the decision is not retried.
7. A decision that no longer matches the case (stale version, already decided) is logged and
   dropped.

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
| `status` | S | portal, dispatcher |
| `job` | S (JSON) | portal |
| `jobMessageId`, `attempts` | S, N | dispatcher (investigation claim) |
| `findings`, `proposedAction` | S (JSON) | dispatcher, from the agent's answer |
| `draftReply` | S | dispatcher, from the agent's answer |
| `proposalVersion` | N | dispatcher (incremented per saved investigation) |
| `applyResult` | S (JSON) | dispatcher, from the agent's answer |
| `failureReason` | S | dispatcher |
| `createdAt`, `updatedAt` | S | portal, dispatcher |

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

## Scaling

- Each job is one Lambda invocation that waits for one agent session. AgentCore Runtime starts a
  separate session for each invocation.
- The investigate event source mapping caps concurrent investigations at
  `MaxConcurrentInvestigations` (default 5). Extra jobs wait in the queue, so a burst does not
  exceed the model's quotas.
- Lambda is billed for the whole time it waits for the agent.

## Read-only during investigation

1. The investigation loads only the read tools (`ai:McpToolKit` with `permittedTools`).
2. It gets gateway tokens from the investigator Cognito client, which has only the read scope.
3. A proposal is only data until approved. The apply action receives the stored proposal from
   the dispatcher and calls it only if it names a tool on the write list. It uses tokens from
   the applier client (write scope).
4. Write tools require an `approvalId` and are idempotent per `approvalId`.

Gateway-side enforcement of scopes per tool is not configured in this sample (see Known limits
in the main README).
