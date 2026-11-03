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
2. An **inquiry agent** on Amazon ECS, built with WSO2 Integrator (Ballerina), looks up the reservation,
   loyalty and payment records with **read-only tools**, and searches runbooks, policies and
   past cases in a **knowledge base**.
3. It returns **findings**, **one proposed fix** and a **draft reply**. Personal data is masked
   in its output by an Amazon Bedrock guardrail.
4. The representative **approves or rejects**. Only an approved fix is applied, exactly as
   stored, and only once.
5. The resolved case is added to the knowledge base, so similar inquiries are faster next time.

## Architecture

![Architecture: inquiry agents on Amazon ECS](docs/figure-2-architecture.png)

- **Support portal:** representatives work cases in a support portal. In this sample a small
  command-line console (`scripts/console.py`) stands in for it, and each case is an item in an
  Amazon DynamoDB table. In production, this record would be the ticket in the team's support
  system.
- **Queues:** the portal sends investigation jobs to an Amazon SQS standard queue, and approve
  or reject decisions to a second queue. Each queue has a dead-letter queue (DLQ), used after
  three failed receives.
- **Inquiry agents on Amazon ECS:** WSO2 Integrator (Ballerina) services on AWS Fargate (ARM64,
  two tasks), each with two SQS listeners, one per queue.
  - Investigation: the agent claims the case with a conditional update (`QUEUED` →
    `INVESTIGATING`). It calls the model, retrieves from the knowledge base and uses read-only
    tools. It saves findings, a proposed fix and a draft reply, and sets `PENDING_APPROVAL`.
    It deletes the job message only after the save succeeds.
  - Apply: a rejection sets `REJECTED`. An approval claims the case (`PENDING_APPROVAL` →
    `APPLYING`), loads the proposal from the case (never from the message), calls one write
    tool, sets `APPLIED`, and adds the resolved case to the knowledge base. If a retry finds the
    case already `APPLYING`, the case becomes `NEEDS_REVIEW` and the tool is not called again.
- **Amazon Bedrock:** the Converse API with a guardrail that masks personal data, and a managed
  knowledge base. It has an S3 data source for runbooks and policies, and a custom data source
  for resolved cases.
- **Tools through Amazon Bedrock AgentCore Gateway:** every tool call goes through one MCP
  endpoint, with Amazon Cognito client-credentials auth. The client secret comes from AWS
  Secrets Manager and is injected into the ECS task. Its targets are reservation, loyalty and
  payment MCP servers built with WSO2 Integrator and hosted on AgentCore Runtime. Each serves
  its own synthetic data. Investigations can use only the read-only tools; write tools are used
  only after approval.

An investigation can take several minutes, so the jobs queue hides a received message for
15 minutes, longer than the longest expected run.

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
| [`inquiry-agent/`](inquiry-agent/) | WSO2 Integrator (Ballerina) inquiry agent for Amazon ECS, with SQS listeners for jobs and decisions |
| [`mcp-servers/`](mcp-servers/) | Reservation, loyalty and payment MCP servers (WSO2 Integrator) for AgentCore Runtime, with bundled synthetic data |
| [`data/`](data/) | Runbooks, policies, seed resolved cases and the three sample inquiries |
| [`infra/`](infra/) | CloudFormation templates (foundation, knowledge, MCP servers, agent on ECS) and request templates for the knowledge base and AgentCore |
| [`scripts/`](scripts/) | Deploy steps, demo, clean-up and the support console (`console.py`) |
| [`docs/`](docs/) | Architecture and security notes, and the architecture figure |

## Prerequisites

- An AWS account and a Region where Amazon Bedrock AgentCore and managed knowledge bases are
  available. The defaults use `us-east-1`.
- Access to Claude Sonnet 5.5 in Amazon Bedrock through the US cross-Region inference profile
  (`us.anthropic.claude-sonnet-5-5`). To use another model, set `MODEL_ID` in `scripts/env.sh`.
- Permissions to create the resources listed in [`infra/README.md`](infra/README.md),
  including IAM roles, a VPC and an ECS cluster.
- A recent AWS CLI v2 with the `bedrock-agent` and `bedrock-agentcore-control` commands.
- Docker with `buildx` and ARM64 support (QEMU emulation works on x86 machines). All four
  images are ARM64: the MCP servers for AgentCore Runtime, and the agent for Graviton Fargate.
- `jq`, and Python 3.11 or later with `boto3` (`pip install -r scripts/requirements.txt`).
- Optional, for local builds and tests: [WSO2 Integrator](https://wso2.com/integrator/) or
  Ballerina 2201.14.0.

## Deploy

1. Copy the settings file and edit it. Choose a unique Cognito domain prefix.

   ```bash
   cp scripts/env.example.sh scripts/env.sh
   ```

2. Install the console's dependency.

   ```bash
   pip install -r scripts/requirements.txt
   ```

3. Run the deploy script. It runs steps 01 to 04. Each step can also be run on its own, and
   saves what it creates to `.deploy/outputs.env`.

   ```bash
   ./scripts/deploy.sh
   ```

   | Step | Script | Creates |
   | --- | --- | --- |
   | 1 | `01-foundation.sh` | SQS queues and DLQs, DynamoDB case table, S3 bucket, Cognito clients and their secret |
   | 2 | `02-knowledge-base.sh` | Guardrail, managed knowledge base, S3 and custom data sources, seeded content |
   | 3 | `03-mcp-servers.sh` | Three ARM64 MCP server images, their AgentCore runtimes, the gateway and its targets |
   | 4 | `04-agent.sh` | Agent image in ECR, and the ECS stack (`agent-ecs.yaml`) running two agent tasks |
   | 5 | `05-demo.sh` | Not part of `deploy.sh`: creates the three sample cases and waits for their investigations |

Some AgentCore and managed knowledge base requests are marked `TODO(verify)` because those
APIs are new. If a step fails, check the request template it uses in `infra/` against the
current AWS CLI reference. See [Known limits](#known-limits).

To follow the agents while they work:

```bash
aws logs tail /ecs/inquiry-agent/inquiry-agent --follow
```

## Try it

Run the demo. It creates one case for each sample inquiry and waits until each investigation
is saved:

```bash
./scripts/05-demo.sh
```

Or submit a single sample and watch it:

```bash
python3 scripts/console.py submit --sample 1
```

```bash
python3 scripts/console.py show <caseId> --watch
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

Review the findings and draft reply, then approve (or `--reject`):

```bash
python3 scripts/console.py decide <caseId> --approve
```

```bash
python3 scripts/console.py show <caseId> --watch
```

Check the result in two places on the case:

- the status is `APPLIED`, and
- the **write tool response** shows the receipt, for example a new confirmation number for
  version 3, the points adjustment for `S-90551`, or the refund of `CH-7003`.

Do not check by reading the records again through the tools. Each MCP server keeps its data in
memory, and AgentCore Runtime runs each session in its own microVM, so a later read may not see
the change.

Other useful commands:

```bash
python3 scripts/console.py list
```

```bash
python3 scripts/console.py failures
```

## Clean up

To avoid ongoing charges, delete everything the deploy scripts created:

```bash
./scripts/cleanup.sh
```

The script works in reverse order. It deletes:

1. the agent's ECR images and the ECS stack,
2. the gateway targets, gateway, credential provider and MCP runtimes, their ECR images, and
   the MCP servers stack,
3. the knowledge base, its data sources and the guardrail stack,
4. the bucket contents, the gateway client secret and the foundation stack.

Check its output for anything it reports as skipped.

## Known limits

- **Not compiled in this repository's history.** The Ballerina code was written against the
  current source of these modules, but has not been built with `bal build` here. Run
  `bal build` and `bal test` in each package before you deploy.
  - `ballerina/ai`, `ballerina/mcp`
  - `ballerinax/ai.aws.bedrock`, `ballerinax/aws.sqs`, `ballerinax/aws.dynamodb`
- **Items marked `TODO(verify)`:** search the repository for `TODO(verify)`. They cover:
  - the AgentCore CLI request shapes (runtimes, gateway, targets, OAuth credential provider),
  - the runtime endpoint URL used for gateway targets,
  - the gateway tool-name prefix (`<target>___<tool>`),
  - the S3 data source parameters for a managed knowledge base,
  - IAM details for managed knowledge bases and the gateway,
  - how the DynamoDB connector reports a failed condition,
  - the Ballerina and Java image tags,
  - whether the Ballerina MCP stateless mode accepts the `Mcp-Session-Id` header AgentCore
    Runtime adds.
- **One message at a time per listener.** Each agent task runs at most one investigation and
  one decision at a time. Scale with the ECS service's desired count.
- **Visibility timeout, not heartbeats.** The jobs queue hides a received job for 15 minutes.
  An investigation that runs longer can be picked up by another task. The claim on the case
  makes only that same message able to resume it, but the work may run twice. Raise the
  timeout (queue and `jobVisibilitySeconds`) if your investigations take longer.
- **Listener stops on polling errors.** The current `ballerinax/aws.sqs` listener stops polling
  after an unexpected error while receiving messages. The task keeps running but idle. If the
  logs show a polling error, restart the ECS service (`aws ecs update-service --force-new-deployment`).
- **A job that reaches its DLQ before it is claimed stays `QUEUED`;** one that fails after its
  third claimed attempt is marked `FAILED`. Use `console.py failures` to see both.
- **In-memory tool data:** each MCP server loads its synthetic data at startup and keeps
  changes in memory for its runtime session only. Verify fixes through the case status and the
  stored write-tool response.
- **Scopes are not enforced per tool at the gateway.** The read and write split is enforced by
  the agent (tool allow lists) and by separate Cognito clients, not by gateway policy.
- **Guardrail scope:** personal data is masked in model output only; input is checked but not
  changed. Card security codes are blocked.
- **No approver identity:** the console does not record who approved a change. A real support
  system would.
- **A failed or interrupted apply stops at `NEEDS_REVIEW`.** A person must check whether the
  change was made.
- **Public subnets** for the agent tasks, public network mode for the runtimes, and AWS owned or
  managed encryption keys.

## License

This sample is licensed under the Apache License 2.0. See [LICENSE](LICENSE).
