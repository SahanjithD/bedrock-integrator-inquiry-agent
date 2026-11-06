# Customer inquiry agent with Amazon Bedrock and WSO2 Integrator

Sample code for the AWS blog post "[article title]".

An inquiry agent built with WSO2 Integrator picks up investigation jobs from
Amazon SQS, reasons with Amazon Bedrock models behind a guardrail, and
retrieves runbooks and past cases from an Amazon Bedrock Managed Knowledge Base.
It gathers evidence through Amazon Bedrock AgentCore Gateway, and every change
it proposes waits for a person's approval.

> Work in progress. Uses synthetic data only.

## Overview

Support teams at a hotel and resort group spend much of their time on questions like "why
does my confirmation show the old dates?" Answering them means checking several internal
systems, finding the right runbook, and then making a small correction. This sample hands
the checking to an agent and keeps the correction with a person:

1. A representative sends an **investigation job** from a support portal.
2. An **inquiry listener** on Amazon ECS picks up the job and calls the **inquiry agent** on
   Amazon Bedrock AgentCore Runtime. Both are built with WSO2 Integrator (Ballerina). The agent
   looks up the reservation,
   loyalty and payment records with **read-only tools**, and searches runbooks, policies and
   past cases in a **knowledge base**.
3. It returns **findings**, **one proposed fix** and a **draft reply**. Personal data is masked
   in its output by an Amazon Bedrock guardrail.
4. The representative **approves or rejects**. Only an approved fix is applied, exactly as
   stored, and only once.
5. The resolved case is added to the knowledge base, so similar inquiries are faster next time.

## Architecture

![Architecture: inquiry listener on Amazon ECS, inquiry agent on AgentCore Runtime](docs/figure-2-architecture.png)

- **Support portal:** representatives work cases in a support portal. In this sample a small
  WSO2 Integrator service (`support-portal/`) stands in for it. You run it on your machine; it
  serves a web page and a REST API. Each case is an item in an Amazon DynamoDB table. In
  production, this record would be the ticket in the team's support system.
- **Queues:** the portal sends investigation jobs to an Amazon SQS standard queue, and approve
  or reject decisions to a second queue. Each queue has a dead-letter queue (DLQ), used after
  three failed receives.
- **Inquiry listener on Amazon ECS:** a WSO2 Integrator (Ballerina) service on AWS Fargate
  (ARM64, one task) with SQS listeners for both queues. It owns the case status and calls the
  agent with a SigV4-signed `InvokeAgentRuntime` request, using its task role. Each call names
  the representative who sent the job or decision as the runtime user ID.
  - Investigation: the listener claims the case with a conditional update (`QUEUED` →
    `INVESTIGATING`) and calls the agent. It saves the findings, proposed fix and draft reply,
    sets `PENDING_APPROVAL`, and only then deletes the message. On error it leaves the message
    for SQS to retry.
  - Apply: a rejection sets `REJECTED`. An approval claims the case (`PENDING_APPROVAL` →
    `APPLYING`), loads the proposal from the case (never from the message), calls the agent
    with it, and sets `APPLIED`. If a retry of the same decision finds the case already
    `APPLYING`, the case becomes `NEEDS_REVIEW` and the agent is not called again. A second
    approval of the same proposal is ignored while the first is applied.
  - Five listeners serve the jobs queue and two the decisions queue, so one task keeps at most
    five investigations and two decisions open at once.
- **Inquiry agent on Amazon Bedrock AgentCore Runtime:** a WSO2 Integrator HTTP service (ARM64,
  port 8080). `POST /invocations` does the work synchronously and returns the result as JSON.
  `GET /ping` returns `Healthy`. The agent holds no state and has no access to SQS or DynamoDB.
- **Amazon Bedrock:** the Converse API with a guardrail that masks personal data, and a managed
  knowledge base. It has an S3 data source for runbooks and policies, and a custom data source
  for resolved cases, which the agent adds to after applying a fix.
- **Tools through Amazon Bedrock AgentCore Gateway:** every tool call goes through one MCP
  endpoint, with Amazon Cognito client-credentials auth. The agent gets its tokens from AgentCore
  Identity: AgentCore Runtime passes it a workload access token for the runtime user, and the
  agent exchanges that for a token from the investigator (read scope) or applier (write scope)
  credential provider. The Cognito client secrets stay in AgentCore Identity. The gateway
  validates each token against Cognito, and uses a third credential provider for its own calls
  to the targets. The gateway's targets are reservation, loyalty and
  payment MCP servers built with WSO2 Integrator and hosted on AgentCore Runtime. Each serves its
  own synthetic data. Investigations can use only the read-only tools; write tools are used only
  after approval.

**Time limits.** A synchronous `InvokeAgentRuntime` call can last at most 15 minutes. A streaming
response can run for up to 60 minutes, but this sample does not stream. The agent therefore
stops an investigation after 10 minutes. Both queues hide a received message for 20 minutes,
longer than any call, so no other consumer picks it up while the call is open.

See [docs/architecture.md](docs/architecture.md) for the flows, statuses and message formats,
and [docs/security.md](docs/security.md) for the security notes.

### Optional gateway targets

The gateway can front more than the internal MCP servers in this sample. As in the figure, a
team could add targets for Salesforce (cases and contacts), Elastic (application logs) or
ServiceNow (incidents and outages) to widen the evidence the agent can gather. These are not
built here. If you add one, list its read-only tools in `inquiry-agent/modules/core/tools.bal`.

## What's in this repo

| Path | Contents |
| --- | --- |
| [`support-portal/`](support-portal/) | WSO2 Integrator (Ballerina) support portal you run locally: a web page and REST API to create cases, review findings, and approve or reject |
| [`inquiry-listener/`](inquiry-listener/) | WSO2 Integrator (Ballerina) SQS listener for Amazon ECS: owns the case status and calls the agent |
| [`inquiry-agent/`](inquiry-agent/) | WSO2 Integrator (Ballerina) inquiry agent for AgentCore Runtime: synchronous investigate and apply actions |
| [`mcp-servers/`](mcp-servers/) | Reservation, loyalty and payment MCP servers (WSO2 Integrator) for AgentCore Runtime, with bundled synthetic data |
| [`data/`](data/) | Runbooks, policies, seed resolved cases and the three sample inquiries |
| [`infra/`](infra/) | CloudFormation templates (foundation, knowledge, MCP servers, agent runtime, listener on ECS) and request templates for the knowledge base and AgentCore |
| [`scripts/`](scripts/) | Deploy steps, portal configuration, demo and clean-up (Bash, AWS CLI, `jq`, `curl`) |
| [`docs/`](docs/) | Architecture and security notes, and the architecture figure |

## Prerequisites

- An AWS account and a Region where Amazon Bedrock AgentCore and managed knowledge bases are
  available. The defaults use `us-east-1`.
- Access to Claude Sonnet 5.5 in Amazon Bedrock through the US cross-Region inference profile
  (`us.anthropic.claude-sonnet-5-5`). To use another model, set `MODEL_ID` in `scripts/env.sh`.
- Permissions to create the resources listed in [`infra/README.md`](infra/README.md),
  including IAM roles, a VPC and an ECS cluster.
- A recent AWS CLI v2 with the `bedrock-agent` and `bedrock-agentcore-control` commands.
- Docker with Buildx and ARM64 support (QEMU emulation works on x86 machines). All five images
  are ARM64: the agent and MCP servers for AgentCore Runtime, and the listener for Graviton
  Fargate.
- `jq`, `curl` and Git.
- [WSO2 Integrator](https://wso2.com/integrator/) 5.0.0 or later (Ballerina 2201.14.0), to run
  the support portal and to build and test the packages locally.
- AWS credentials for the support portal, which runs on your machine. They need:
  - `dynamodb:GetItem`, `dynamodb:PutItem`, `dynamodb:UpdateItem` and `dynamodb:Scan` on the
    case table,
  - `sqs:SendMessage` on the jobs and decisions queues,
  - `sqs:ReceiveMessage` on the two dead-letter queues (for `GET /failures`).

## Deploy

1. Copy the settings file and edit it. Choose a unique Cognito domain prefix.

   ```bash
   cp scripts/env.example.sh scripts/env.sh
   ```

2. Run the deploy script. It runs steps 01 to 05 and then writes the support portal's
   `Config.toml` (`portal-config.sh`). Each step can also be run on its own, and saves what it
   creates to `.deploy/outputs.env`.

   ```bash
   ./scripts/deploy.sh
   ```

   | Step | Script | Creates |
   | --- | --- | --- |
   | 1 | `01-foundation.sh` | SQS queues and DLQs, DynamoDB case table, S3 bucket, Cognito clients |
   | 2 | `02-knowledge-base.sh` | Guardrail, managed knowledge base, S3 and custom data sources, seeded content |
   | 3 | `03-mcp-servers.sh` | Three ARM64 MCP server images, their AgentCore runtimes, the gateway's outbound credential provider, the gateway and its targets |
   | 4 | `04-agent.sh` | The agent's investigator and applier credential providers, the ARM64 agent image and the inquiry agent runtime (`agent-runtime.yaml`, `inquiry-agent.json`) |
   | 5 | `05-listener.sh` | Listener image and the ECS stack (`listener-ecs.yaml`) running one listener task |
   | | `portal-config.sh` | `support-portal/Config.toml`, from the deploy outputs |
   | 6 | `06-demo.sh` | Not part of `deploy.sh`: creates the three sample cases through the running portal and waits for their investigations |

Some AgentCore and managed knowledge base requests are marked `TODO(verify)` because those
APIs are new. If a step fails, check the request template it uses in `infra/` against the
current AWS CLI reference. See [Known limits](#known-limits).

To follow the listener while it works:

```bash
aws logs tail /ecs/inquiry-agent/inquiry-listener --follow
```

The agent's logs are in CloudWatch under `/aws/bedrock-agentcore/runtimes/`.

## Try it

### Run the support portal

```bash
cd support-portal
```

```bash
bal run
```

Open http://localhost:9090. You can also open `support-portal/` in WSO2 Integrator and choose
**Run**. The portal uses your default AWS credentials and the `Config.toml` that
`deploy.sh` wrote. Run `./scripts/portal-config.sh` to write it again.

On the page, choose one of the three sample inquiries, or type a guest's message. The case
appears in the list as **Queued**, then **Investigating**. When the agent finishes, it shows as
**Awaiting approval**. Select it to see the summary, root cause, evidence, proposed change and
draft reply.

To create all three samples at once and wait for their investigations, run the demo in a
second terminal while the portal is running:

```bash
./scripts/06-demo.sh
```

The same steps with `curl`:

```bash
curl -s -X POST localhost:9090/cases -H 'content-type: application/json' -d '{"sample": 1}'
```

```bash
curl -s localhost:9090/cases | jq
```

```bash
curl -s localhost:9090/cases/<caseId> | jq '{status, findings, proposedAction, draftReply}'
```

### 1. "I changed my booking dates in the app, but my confirmation still shows the old dates."

Expected findings: reservation `R-48213` is at version 3 with the new dates, the confirmation
job for that change failed, and the latest confirmation is still version 2. Proposed change:
`reservation___reissueConfirmation` for `R-48213`.

### 2. "I stayed last weekend, but my loyalty points never showed up."

Expected findings: stay `S-90551` for member `M-77310` closed after the nightly accrual batch
ran, so its accrual is `FAILED`. Proposed change: `loyalty___creditPoints` with 3,465 points
(630.00 qualifying spend × 5 base points, plus the 10% Gold bonus).

### 3. "There's a charge on my card from the resort that I don't recognize."

Expected findings: `CH-7003` (`RESORT INCIDENTALS 0423`) is the check-in hold `CH-7001`
captured by the reconciliation job, although the folio shows no incidentals. Proposed change:
`payment___refundCharge` for `CH-7003`, 250.00.

### Approve and check the result

Review the findings and draft reply, then choose **Approve** (or **Reject**) on the page. With
`curl`:

```bash
curl -s -X POST localhost:9090/cases/<caseId>/decision -H 'content-type: application/json' -d '{"decision": "approve"}'
```

The portal sends `{caseId, decision, proposalVersion}` to the decisions queue. Only a case that
is awaiting approval accepts a decision.

Check the result in two places on the case, on the page or with
`curl -s localhost:9090/cases/<caseId> | jq '{status, applyResult}'`:

- the status is **Applied** (`APPLIED`), and
- the **write tool response** shows the receipt, for example a new confirmation number for
  version 3, the points adjustment for `S-90551`, or the refund of `CH-7003`.

Do not check by reading the records again through the tools. Each MCP server keeps its data in
memory, and AgentCore Runtime runs each session in its own microVM, so a later read may not see
the change.

Messages that ended up in a dead-letter queue are listed on the page, and with:

```bash
curl -s localhost:9090/failures | jq
```

## Clean up

To avoid ongoing charges, delete everything the deploy scripts created:

```bash
./scripts/cleanup.sh
```

The script works in reverse order. It deletes:

1. the listener's ECR images and the ECS stack,
2. the agent runtime and its two credential providers, the gateway targets, gateway and its
   credential provider, and the MCP runtimes,
3. the agent's and MCP servers' ECR images and stacks,
4. the knowledge base, its data sources and the guardrail stack,
5. the bucket contents and the foundation stack.

Check its output for anything it reports as skipped.

## Known limits

- **Not compiled in this repository's history.** The Ballerina code was written against the
  current source of these modules, but has not been built with `bal build` here. Run
  `bal build` and `bal test` in each package before you deploy.
  - `ballerina/ai`, `ballerina/mcp`
  - `ballerinax/ai.aws.bedrock`, `ballerinax/aws`, `ballerinax/aws.sqs`, `ballerinax/aws.dynamodb`
- **Items marked `TODO(verify)`:** search the repository for `TODO(verify)`. They cover:
  - the AgentCore CLI request shapes (runtimes, gateway, targets, OAuth credential providers),
  - the `WorkloadAccessToken` header AgentCore Runtime passes to the agent, and the IAM actions
    for the runtime user ID (`InvokeAgentRuntimeForUser`) and for `GetResourceOauth2Token`,
  - the gateway tool-name prefix (`<target>___<tool>`),
  - IAM details for managed knowledge bases and the gateway,
  - how the DynamoDB connector reports a failed condition,
  - attaching one SQS service to several `sqs:Listener` objects, which the listener uses to
    bound concurrency,
  - the Ballerina and Java image tags,
  - whether the Ballerina MCP stateless mode accepts the `Mcp-Session-Id` header AgentCore
    Runtime adds.
- **15-minute calls.** Each agent call is synchronous and must finish within 15 minutes. The
  agent stops at 10 minutes and the job is retried, up to three times. Longer work would need a
  streaming response (up to 60 minutes) or an asynchronous pattern.
- **Bounded concurrency.** One listener task keeps at most five investigations and two decisions
  open at once. To raise the limit, add listener declarations in `inquiry-listener/listeners.bal`.
- **Visibility timeout, not heartbeats.** Both queues hide a received message for 20 minutes,
  above the 15-minute call limit. If the listener task stops while a call is open, the message
  becomes visible again after the timeout and is retried.
- **Listener stops on polling errors.** The current `ballerinax/aws.sqs` listener stops polling
  after an unexpected error while receiving messages. The task keeps running but idle. If the
  logs show a polling error, restart the ECS service (`aws ecs update-service --force-new-deployment`).
- **A job that reaches its DLQ before it is claimed stays `QUEUED`;** one that fails after its
  third claimed attempt is marked `FAILED`. The portal's dead-letter list (`GET /failures`)
  shows both.
- **In-memory tool data:** each MCP server loads its synthetic data at startup and keeps
  changes in memory for its runtime session only. Verify fixes through the case status and the
  stored write-tool response.
- **Scopes are not enforced per tool at the gateway.** The read and write split is enforced by
  the agent (tool allow lists) and by separate Cognito clients, not by gateway policy.
- **Guardrail scope:** personal data is masked in model output only; input is checked but not
  changed. Card security codes are blocked.
- **No approver identity:** the portal has no sign-in and does not record who approved a change.
  A real support system would.
- **A failed or interrupted apply stops at `NEEDS_REVIEW`.** A person must check whether the
  change was made.
- **Public subnet** for the listener task, public network mode for the runtimes, and AWS owned
  or managed encryption keys.

## License

This sample is licensed under the Apache License 2.0. See [LICENSE](LICENSE).
