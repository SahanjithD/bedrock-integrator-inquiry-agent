# Customer inquiry agent with Amazon Bedrock and WSO2 Integrator

> **Branch: SQS -> Lambda -> AgentCore Runtime.** The simplest variant: each investigation must
> finish within Lambda's 15-minute limit, and Lambda is billed while it waits for the agent. The
> main branch runs the agents on Amazon ECS.

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
2. A Lambda dispatcher passes it to the **inquiry agent**, built with WSO2 Integrator (Ballerina)
   and hosted on Amazon Bedrock AgentCore Runtime. The agent looks up the reservation,
   loyalty and payment records with **read-only tools**, and searches runbooks, policies and
   past cases in a **knowledge base**.
3. It returns **findings**, **one proposed fix** and a **draft reply**. Personal data is masked
   in its output by an Amazon Bedrock guardrail.
4. The representative **approves or rejects**. Only an approved fix is applied, exactly as
   stored, and only once.
5. The resolved case is added to the knowledge base, so similar inquiries are faster next time.

## Architecture

![Architecture: SQS, Lambda dispatcher and the inquiry agent on AgentCore Runtime](docs/figure-2-architecture-lambda.png)

- **Support portal:** representatives work cases in a support portal. In this sample a small
  command-line console (`scripts/console.py`) stands in for it, and each case is an item in an
  Amazon DynamoDB table. In production, this record would be the ticket in the team's support
  system.
- **Queues:** the portal sends investigation jobs to an Amazon SQS standard queue, and approve
  or reject decisions to a second queue. Each queue has a dead-letter queue (DLQ), used after
  three failed receives.
- **Lambda dispatcher:** two AWS Lambda functions (Python 3.12), one per queue, own the case
  status. Each SQS event source mapping delivers one message at a time.
  - `investigate` claims the case with a conditional update (`QUEUED` → `INVESTIGATING`) and
    calls the agent with `InvokeAgentRuntime`, waiting for the answer. It saves the findings,
    proposed fix and draft reply, and sets `PENDING_APPROVAL`. On error it fails the message,
    so SQS retries it.
  - `apply` sets `REJECTED`, or claims the case (`PENDING_APPROVAL` → `APPLYING`). It loads the
    proposal from the case (never from the message), calls the agent to apply it, and sets
    `APPLIED`. If a retry finds the case already `APPLYING`, the case becomes `NEEDS_REVIEW`
    and the agent is not called again.
- **Inquiry agent:** a WSO2 Integrator (Ballerina) HTTP service on Amazon Bedrock AgentCore
  Runtime (ARM64, port 8080). `POST /invocations` does the work synchronously and returns the
  result as JSON. `GET /ping` returns `Healthy`. The agent holds no state and has no access to
  the case table.
- **Amazon Bedrock:** the Converse API with a guardrail that masks personal data, and a managed
  knowledge base. It has an S3 data source for runbooks and policies, and a custom data source
  for resolved cases, which the agent adds to after applying a fix.
- **Tools through Amazon Bedrock AgentCore Gateway:** every tool call goes through one MCP
  endpoint, with Amazon Cognito client-credentials auth. Its targets are reservation, loyalty
  and payment MCP servers built with WSO2 Integrator and hosted on AgentCore Runtime. Each
  serves its own synthetic data. Investigations can use only the read-only tools; write tools
  are used only after approval.

**Time limits.** AgentCore Runtime ends a synchronous request after 15 minutes, and a Lambda
function can run for at most 15 minutes (900 s). The agent therefore stops an investigation
after 10 minutes, and the dispatcher stops waiting after 870 s. Both queues hide a received
message for 5400 s, 6x the function timeout.

See [docs/architecture.md](docs/architecture.md) for the flows, statuses and message formats,
and [docs/security.md](docs/security.md) for the security notes.

### Optional gateway targets

The gateway can front more than the internal MCP servers in this sample. For example, a team
could add targets for Salesforce (cases and contacts), Elastic (application logs) or
ServiceNow (incidents and outages) to widen the evidence the agent can gather. These are not
built here. If you add one, list its read-only tools in `inquiry-agent/modules/core/tools.bal`.

## What's in this repo

| Path | Contents |
| --- | --- |
| [`inquiry-agent/`](inquiry-agent/) | WSO2 Integrator (Ballerina) inquiry agent for AgentCore Runtime: synchronous investigate and apply actions |
| [`mcp-servers/`](mcp-servers/) | Reservation, loyalty and payment MCP servers (WSO2 Integrator) with bundled synthetic data |
| [`data/`](data/) | Runbooks, policies, seed resolved cases and the three sample inquiries |
| [`infra/`](infra/) | CloudFormation templates, the Lambda dispatcher and its tests, AgentCore and knowledge base request templates |
| [`scripts/`](scripts/) | Deploy steps, clean-up and the support console (`console.py`) |
| [`docs/`](docs/) | Architecture and security notes, and the architecture figure |

## Prerequisites

- An AWS account and a Region where Amazon Bedrock AgentCore and managed knowledge bases are
  available. The defaults use `us-east-1`.
- Access to Claude Sonnet 5.5 in Amazon Bedrock through the US cross-Region inference profile
  (`us.anthropic.claude-sonnet-5-5`). To use another model, set `MODEL_ID` in `scripts/env.sh`.
- Permissions to create the resources listed in [`infra/README.md`](infra/README.md),
  including IAM roles.
- A recent AWS CLI v2 with the `bedrock-agent` and `bedrock-agentcore-control` commands.
- Docker with `buildx` and ARM64 support (QEMU emulation works on x86 machines).
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

3. Run the deploy script. It runs five steps. Each step can also be run on its own, and saves
   what it creates to `.deploy/outputs.env`.

   ```bash
   ./scripts/deploy.sh
   ```

   | Step | Script | Creates |
   | --- | --- | --- |
   | 1 | `01-foundation.sh` | Queues and DLQs, case table, bucket, ECR repositories, guardrail, Cognito clients, IAM roles |
   | 2 | `02-knowledge-base.sh` | Managed knowledge base, S3 and custom data sources, seeded content |
   | 3 | `03-mcp-servers.sh` | Three ARM64 MCP server images, their AgentCore runtimes, the gateway and its targets |
   | 4 | `04-agent.sh` | Agent image and the inquiry agent runtime |
   | 5 | `05-dispatcher.sh` | Lambda dispatcher (`dispatcher.yaml`): two functions and their SQS event source mappings |

Some AgentCore and managed knowledge base requests are marked `TODO(verify)` because those
APIs are new. If a step fails, check the request template it uses in `infra/` against the
current AWS CLI reference. See [Known limits](#known-limits).

To follow the dispatcher while it works:

```bash
aws logs tail /aws/lambda/inquiry-agent-investigate --follow
```

## Try it

Submit each sample inquiry and watch the case. Each command prints the case ID to use in the
next one.

### 1. "I changed my booking dates in the app, but my confirmation still shows the old dates."

```bash
python3 scripts/console.py submit --sample 1
```

```bash
python3 scripts/console.py show <caseId> --watch
```

Expected findings: reservation `R-48213` is at version 3 with the new dates, the confirmation
job for that change failed, and the latest confirmation is still version 2. Proposed change:
`reservation___reissueConfirmation` for `R-48213`.

### 2. "I stayed last weekend, but my loyalty points never showed up."

```bash
python3 scripts/console.py submit --sample 2
```

Expected findings: stay `S-90551` for member `M-77310` closed after the nightly accrual batch
ran, so its accrual is `FAILED`. Proposed change: `loyalty___creditPoints` with 3,465 points
(630.00 qualifying spend × 5 base points, plus the 10% Gold bonus).

### 3. "There's a charge on my card from the resort that I don't recognize."

```bash
python3 scripts/console.py submit --sample 3
```

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

1. the dispatcher stack,
2. the agent runtime, gateway targets, gateway, credential provider and MCP runtimes,
3. the knowledge base and its data sources,
4. the bucket contents, the gateway client secret and the foundation stack, whose ECR
   repositories are emptied on delete.

Check its output for anything it reports as skipped.

## Known limits

- **15-minute ceiling.** The dispatcher waits for the agent inside one Lambda invocation, so an
  investigation must finish within 15 minutes. The agent stops at 10 minutes and the job is
  retried, up to three times. Longer investigations need the ECS variant on the main branch.
- **Lambda waits and is billed.** Each investigation keeps one Lambda invocation running for as
  long as the agent works.
- **Concurrency cap.** `MaxConcurrentInvestigations` (default 5) limits how many investigations
  run at once. Raise it within your Bedrock and AgentCore quotas.
- **Not compiled in this repository's history.** The Ballerina code was written against the
  current source of these modules, but has not been built with `bal build` here. Run
  `bal build` and `bal test` in each package before you deploy.
  - `ballerina/ai`, `ballerina/mcp`
  - `ballerinax/ai.aws.bedrock`, `ballerinax/aws`
- **Dispatcher tests use a stand-in.** The dispatcher's tests run against an in-memory DynamoDB
  (`moto`) and a fake agent.
- **Items marked `TODO(verify)`:** search the repository for `TODO(verify)`. They cover:
  - the AgentCore CLI request shapes (runtimes, gateway, targets, OAuth credential provider),
  - the runtime endpoint URL used for gateway targets,
  - the gateway tool-name prefix (`<target>___<tool>`),
  - the S3 data source parameters for a managed knowledge base,
  - IAM details for managed knowledge bases, the gateway and `InvokeAgentRuntime`,
  - the Lambda runtime's bundled boto3,
  - the Ballerina and Java image tags,
  - whether the Ballerina MCP stateless mode accepts the `Mcp-Session-Id` header AgentCore
    Runtime adds.
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
- **Public network mode** for the runtimes, and AWS owned or managed encryption keys.

## License

This sample is licensed under the Apache License 2.0. See [LICENSE](LICENSE).
