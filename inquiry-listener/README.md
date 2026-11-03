# Inquiry listener

A WSO2 Integrator (Ballerina) service on Amazon ECS (Fargate, ARM64, one task). It reads the
support console's two SQS queues, owns the case status in DynamoDB, and calls the inquiry agent
on Amazon Bedrock AgentCore Runtime (`../inquiry-agent`) for each job or approved decision. It
has no HTTP endpoints and needs no secrets.

| Listener | Queue | Work | At once per task |
| --- | --- | --- | --- |
| Jobs | `<project>-jobs` | Have the agent investigate, save the findings for approval | 5 |
| Decisions | `<project>-decisions` | Reject, or have the agent apply the approved change | 2 |

## Investigate (jobs queue)

1. Claims the case with a conditional update: `QUEUED` → `INVESTIGATING`. The claim records the
   SQS message ID and counts the attempt, so a redelivery of the same message may resume, but a
   second job for the same case is skipped.
2. Calls `InvokeAgentRuntime` with `{action: "investigate", caseId, job}`. The runtime session
   ID is `<caseId>-<attempt>`, padded to at least 33 characters.
3. Saves the agent's findings, proposed fix and draft reply, increments `proposalVersion`, and
   sets `PENDING_APPROVAL` (or `NO_ACTION_PROPOSED`).
4. Deletes the SQS message only after the save succeeds.

If the call fails, the message is not deleted. It becomes visible again after
`retryDelaySeconds`. After the third attempt the case is marked `FAILED`, and SQS moves the
message to the jobs DLQ.

## Apply (decisions queue)

The decision message carries only `caseId`, `decision` and `proposalVersion`.

- **Rejected:** `PENDING_APPROVAL` → `REJECTED`, if the version is current.
- **Approved:**
  1. Claim: `PENDING_APPROVAL` → `APPLYING`, if the version is current.
  2. If the case is already `APPLYING` (a redelivered decision), an earlier attempt may have
     made the change. The agent is not called again; the case becomes `NEEDS_REVIEW`.
  3. Load the proposal and findings from the case (never from the message) and call
     `InvokeAgentRuntime` with `{action: "apply", caseId, proposalVersion, proposedAction, findings}`.
  4. `APPLYING` → `APPLIED`, storing the agent's answer (the write tool's response).

If the agent call fails after the claim, the outcome is unknown: the case goes to
`NEEDS_REVIEW` and the decision is not retried.

## Calling AgentCore Runtime

No Ballerina connector covers AgentCore Runtime yet, so `agentcore.bal` sends the HTTPS request
itself and signs it with SigV4 (`ballerinax/aws.auth`, signing name `bedrock-agentcore`) using the
ECS task role:

```
POST https://bedrock-agentcore.<region>.amazonaws.com/runtimes/<URL-encoded runtime ARN>/invocations?qualifier=DEFAULT
X-Amzn-Bedrock-AgentCore-Runtime-Session-Id: <session ID>
```

The call is synchronous. AgentCore Runtime ends it after 15 minutes, and the agent stops an
investigation after 10. Both queues hide a received message for 20 minutes
(`jobVisibilitySeconds`, `decisionVisibilitySeconds`), longer than any call, so no other consumer
picks it up meanwhile. (A streaming response can run for up to 60 minutes; this sample does not
use streaming.)

## Layout

| File | Purpose |
| --- | --- |
| `listeners.bal` | The SQS listeners, message parsing, delete and retry |
| `investigate.bal` | Job handling |
| `apply.bal` | Reject and apply handling |
| `agentcore.bal` | SigV4-signed `InvokeAgentRuntime` call |
| `cases.bal` | DynamoDB reads and conditional status updates |
| `clients.bal`, `config.bal` | Clients and settings |
| `modules/core` | Types, message checks, session IDs, request path (unit tested) |

## Build and test

```bash
bal test
```

```bash
docker buildx build --platform linux/arm64 -t inquiry-listener .
```

To run locally, copy `Config.toml.example` to `Config.toml`, fill it in, and run `bal run` with
AWS credentials that can reach the same resources. Set the ECS service's desired count to 0
first, if you don't want it to compete for messages.
