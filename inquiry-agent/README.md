# Inquiry agent

A WSO2 Integrator (Ballerina) service that runs on Amazon Bedrock AgentCore Runtime with the
HTTP protocol. It is not a long-running worker and has no queue listener. Step Functions calls
it once per job, through a small Lambda dispatcher, and waits on a task token.

| Endpoint | Behavior |
| --- | --- |
| `POST /invocations` | Checks the request, replies `{"status": "accepted"}` at once, and runs the action in the background. |
| `GET /ping` | `Healthy` when idle, `HealthyBusy` while an action runs. `time_of_last_update` changes only when the status changes. |

## Actions

**`investigate`**: a stateless `ai:Agent` (`memory = ()`) with:

- the Bedrock Converse API (`ballerinax/ai.aws.bedrock`) with a guardrail that masks personal data,
- the gateway's read-only tools only (`ai:McpToolKit` with `permittedTools`), using the
  investigator app client, which is granted the read scope only,
- `searchKnowledge`, which retrieves runbooks, policies and resolved cases from the managed
  knowledge base.

It returns findings, at most one proposed change and a draft reply through `SendTaskSuccess`.
Proposals are checked first (`modules/core/tools.bal`): the tool must be a known write tool,
required arguments must be present, every ID must appear in the evidence, and `approvalId`
must not be set by the model.

**`apply`**: runs after a representative approves. It reads the stored proposal from the case
item; the decision message carries only `caseId`, `decision` and `proposalVersion`.

1. Conditional update `PENDING_APPROVAL` → `APPLYING` (the version must match).
2. If the case is already `APPLYING`, an earlier attempt may have made the change: the tool is
   not called again, the case becomes `NEEDS_REVIEW`, and the task fails with `CaseNeedsReview`.
3. Calls the stored write tool through the gateway with `approvalId = <caseId>#<version>`.
4. Conditional update `APPLYING` → `APPLIED`, storing the tool's response.
5. Adds a resolved-case summary to the knowledge base's custom data source.

## Layout

| File | Purpose |
| --- | --- |
| `service.bal` | HTTP listener, background execution, failure reporting |
| `investigate.bal` | Investigation agent and the `searchKnowledge` tool |
| `apply.bal` | Approved-change flow and knowledge base ingestion |
| `cases.bal` | DynamoDB reads and conditional status updates |
| `aws_json.bal` | SigV4-signed calls to Step Functions and Secrets Manager |
| `clients.bal`, `config.bal`, `prompts.bal` | Clients, settings, prompts |
| `modules/core` | Types, tool lists, request and proposal checks, ping status (unit tested) |

## Build and test

```bash
bal test
```

```bash
docker buildx build --platform linux/arm64 -t inquiry-agent .
```

To run outside AgentCore, copy `Config.toml.example` to `Config.toml`, fill it in, and run
`bal run` with AWS credentials that can reach the same resources. You can then call it like the
dispatcher does, with a task token from a waiting Step Functions execution.
