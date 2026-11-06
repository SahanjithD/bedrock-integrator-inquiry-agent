# Inquiry agent

A WSO2 Integrator (Ballerina) service on Amazon Bedrock AgentCore Runtime (HTTP protocol, ARM64,
port 8080). It has no queue listener and holds no case state, and it has no access to SQS or
DynamoDB. The inquiry listener on Amazon ECS (`../inquiry-listener`) calls it once per job or
approved decision with `InvokeAgentRuntime`, and waits for the result.

| Endpoint | Behavior |
| --- | --- |
| `POST /invocations` | Runs the action synchronously and returns the result as JSON: `{"status": "ok", ...}` or `{"status": "error", "code": ..., "message": ...}`. |
| `GET /ping` | Returns `{"status": "Healthy"}`. |

## Time limit

AgentCore Runtime ends a synchronous `InvokeAgentRuntime` request after 15 minutes. (A streaming
response can run for up to 60 minutes, but this sample returns one JSON answer.) The agent
therefore gives up on an investigation after `investigationTimeoutSeconds` (600 seconds by
default) and returns an `InvestigationTimeout` error, which the listener retries. Keep this value
well under 15 minutes.

## Gateway tokens

The inquiry listener names the representative as the runtime user ID, so AgentCore Runtime
passes each request a workload access token in the `WorkloadAccessToken` header. The agent
exchanges it with AgentCore Identity (`GetResourceOauth2Token`, M2M flow) for a gateway token
from the investigator or applier credential provider (`identity.bal`). The Cognito client
secrets stay in AgentCore Identity. A request without the header gets an `InvalidRequest` error.

## Actions

**`investigate`**: request `{action, caseId, job}`. Each job gets a new `ai:Agent` with its own
in-memory history, so nothing carries over between jobs. It uses:

- the Bedrock Converse API (`ballerinax/ai.aws.bedrock`) with a guardrail that masks personal data,
- `searchKnowledge`, which retrieves runbooks, policies and resolved cases from the managed
  knowledge base,
- the gateway's read-only tools only (`ai:McpToolKit` with `permittedTools`), with a token from
  the investigator credential provider, whose Cognito client has the read scope only.

It returns `{status: "ok", caseId, findings}`. `findings` holds the summary, evidence, root
cause, at most one proposed change and a draft reply. The model gives its final answer through a
tool whose parameters are the findings schema. If the answer leaves out a required field or has
a wrong value, the agent logs it and asks the model once, in the same conversation, to correct
it, so the evidence is not gathered again (`modules/core/findings.bal`). Proposals are checked
first (`modules/core/tools.bal`):

- the tool must be a known write tool,
- the required arguments must be present,
- every ID must appear in the evidence,
- the model must not set `approvalId`.

**`apply`**: request `{action, caseId, proposalVersion, proposedAction, findings}`. The
listener loads the approved proposal from the case item; the decision message never carries
it. The agent:

1. checks that the tool is on the write list,
2. calls exactly that one write tool through the gateway with a token from the applier
   credential provider (write scope) and `approvalId = <caseId>#<proposalVersion>`,
3. adds a resolved-case summary to the knowledge base's custom data source,
4. returns `{status: "ok", caseId, applyResult, knowledgeBaseUpdated}`.

The listener, not the agent, moves the case through `APPLYING`, `APPLIED` and `NEEDS_REVIEW`.

## Layout

| File | Purpose |
| --- | --- |
| `service.bal` | HTTP listener and response shape |
| `investigate.bal` | Investigation agent, time limit, and the `searchKnowledge` tool |
| `apply.bal` | Write-tool call and knowledge base ingestion |
| `identity.bal` | Gateway tokens from AgentCore Identity (SigV4, runtime execution role) |
| `clients.bal`, `config.bal`, `prompts.bal` | Clients, settings, prompts |
| `modules/core` | Types, tool lists, request and proposal checks (unit tested) |

## Build and test

```bash
bal test
```

```bash
docker buildx build --platform linux/arm64 -t inquiry-agent .
```

To run locally, copy `Config.toml.example` to `Config.toml`, fill it in, and run `bal run` with
AWS credentials that can reach the same resources. A local run gets no `WorkloadAccessToken`
header, so set `localWorkloadName` to a workload identity you created; the agent then fetches a
workload access token for it and `localUserId`. Then post a request:

```bash
curl -s localhost:8080/invocations -H 'content-type: application/json' -d '{"action":"investigate","caseId":"CASE-LOCAL-1","job":{"caseId":"CASE-LOCAL-1","customerRef":"G-15562","inquiry":"I stayed last weekend, but my loyalty points never showed up.","context":{"memberId":"M-77310"}}}'
```
