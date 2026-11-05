# IAM policies for a shared account

Templates for an account administrator. They limit someone deploying this sample to resources
named with their own prefix, or tagged `Project=<prefix>`, in one account and Region. Render them
with your settings:

```bash
./scripts/render-iam-policies.sh
```

The script reads `scripts/env.sh`, takes the account ID from your credentials (or from
`ACCOUNT_ID`), and writes the filled-in policies to `.deploy/iam/`.

| Policy | For | Allows |
| --- | --- | --- |
| `deployer-core.json` | whoever deploys and cleans up | CloudFormation stacks `<prefix>-*`, SQS queues `<prefix>-*`, the DynamoDB table, the knowledge bucket, the Cognito user pool tagged `Project=<prefix>`, and the sample's log groups |
| `deployer-compute.json` | whoever deploys and cleans up | ECR repositories `<prefix>/*`, the ECS cluster `<prefix>`, IAM roles `<prefix>-*` (passed only to ECS, Bedrock and AgentCore), and VPC resources tagged `Project=<prefix>` |
| `deployer-ai.json` | whoever deploys and cleans up | The guardrail and knowledge base tagged `Project=<prefix>`; the AgentCore runtimes, gateway and the three OAuth credential providers (`<prefix>-runtime-oauth`, `-investigator`, `-applier`) and their secrets, named with the prefix; and a model call for the preflight check |
| `portal.json` | whoever runs the support portal | `GetItem`, `PutItem`, `UpdateItem` and `Scan` on the case table, `SendMessage` on the two queues, and `ReceiveMessage` on the two DLQs |

Each policy is below the 6,144-character limit for a managed policy.

## How the scoping works

- **By name:** stacks, queues, the table, the bucket, repositories, the cluster, IAM roles, log
  groups and AgentCore resources (including the credential providers and the secrets AgentCore
  Identity keeps for them) all carry the prefix in their name, so the policies match on ARNs.
  Where CloudFormation needs a family of bucket settings, the S3 wildcards apply to this one
  bucket only.
- **By tag:** some resources get an ID instead of a name (the VPC and its subnets, the security
  group, the Cognito user pool, the guardrail and the knowledge base). For the user pool, all
  Cognito actions are allowed, but only on a pool tagged `Project=<prefix>`. They can only be created
  with `Project=<prefix>` in the request (`aws:RequestTag`), and changed or deleted only when
  they carry that tag (`aws:ResourceTag`). The scripts tag every stack with `Project=<prefix>`
  and your owner tag, and pass the same tags when they create AgentCore and knowledge base
  resources.
- **Roles:** the deployer can create roles only under `<prefix>-*`, attach only the AWS managed
  `AmazonECSTaskExecutionRolePolicy`, and pass roles only to `ecs-tasks`, `bedrock` and
  `bedrock-agentcore`. With `PERMISSIONS_BOUNDARY_ARN` set in `env.sh`, the rendered policy also
  requires that boundary on every role it creates, and every template attaches it.
- **Not scoped:** read-only list and describe calls, `ecr:GetAuthorizationToken`,
  `ecs:RegisterTaskDefinition` (tag condition only), creating the ECS service-linked role if
  the account does not have it yet, and `bedrock-agentcore:CreateAgentRuntimeEndpoint` on
  `runtime/*`. `CreateAgentRuntime` creates the runtime's `DEFAULT` endpoint and checks that
  action against `runtime/*`, before the runtime has an ID, so a prefix cannot scope it. Reading,
  updating and deleting endpoints stays limited to your own runtimes.

## Check before you rely on them

These policies were checked with an IAM policy linter and against the AWS SDK's operation names.
They have not been tested against a live account. Before attaching them, the administrator can
run them through the IAM policy simulator or IAM Access Analyzer's policy validation. Points to
check:

- **TODO(verify)** that CloudFormation passes the stack tags at creation time for the VPC
  resources, the user pool (which also sets `Project` explicitly), the guardrail and the task
  definition, so the `aws:RequestTag` conditions match. If one does not, relax the tag condition
  for that one create action only.
- **TODO(verify)** the condition keys and resource types that Amazon Bedrock AgentCore supports.
  The policy scopes AgentCore by name pattern:
  - runtimes `<prefix with underscores>_*`,
  - the gateway `<prefix>-gateway-*`,
  - the credential provider `<prefix>-runtime-oauth`,
  - workload identities and the credential provider's secret, which AgentCore creates for the
    gateway.
- **TODO(verify)** whether the account already has the service-linked roles that ECS and AgentCore
  use. If not, the first deployment creates them, which needs `iam:CreateServiceLinkedRole`.
