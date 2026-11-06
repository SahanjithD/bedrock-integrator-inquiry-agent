# Infrastructure

| Path | Deployed by | Contents |
| --- | --- | --- |
| `cloudformation/foundation.yaml` | `scripts/01-foundation.sh` | SQS jobs and decisions queues with DLQs, DynamoDB case table, knowledge bucket, Cognito machine clients |
| `cloudformation/knowledge.yaml` | `scripts/02-knowledge-base.sh` | Guardrail (PII masking) and the knowledge base service role |
| `knowledge-base/*.json` | `scripts/02-knowledge-base.sh` | Request bodies for the managed knowledge base and its two data sources |
| `cloudformation/mcp-servers.yaml` | `scripts/03-mcp-servers.sh` | ECR repositories and IAM roles for the MCP server runtimes and the gateway |
| `agentcore/mcp-runtime.json`, `oauth-provider.json`, `gateway*.json` | `scripts/03-mcp-servers.sh` | Request bodies for the MCP runtimes, the gateway's outbound OAuth credential provider, the gateway and its targets |
| `agentcore/oauth-provider.json` | `scripts/04-agent.sh` | Request body for the agent's investigator and applier credential providers |
| `cloudformation/agent-runtime.yaml` | `scripts/04-agent.sh` | ECR repository and execution role for the inquiry agent on AgentCore Runtime |
| `agentcore/inquiry-agent.json` | `scripts/04-agent.sh` | Request body for the inquiry agent runtime (HTTP protocol) |
| `cloudformation/listener-ecs.yaml` | `scripts/05-listener.sh` | Inquiry listener on Amazon ECS: VPC with public subnets, outbound-only security group, ECR repository, cluster, Fargate task definition and service (one task), task and execution roles, log group |

AgentCore and the managed knowledge base are created with the AWS CLI rather than
CloudFormation because they are new. The scripts fill in the JSON templates with `jq`, so the
request shapes are easy to review in one place.

## Inquiry listener on ECS

- Fargate, ARM64, one task. It runs up to five investigations and two decisions at once, each
  waiting for one synchronous agent call.
- Public subnets with `AssignPublicIp`, and a security group with outbound HTTPS only. The
  listener has no inbound ports. This keeps the sample small. For production, use private
  subnets with VPC endpoints or a NAT gateway.
- Settings reach the listener in `BAL_CONFIG_DATA`. It needs no secrets.
- Task role:
  - `sqs:ReceiveMessage`, `DeleteMessage`, `ChangeMessageVisibility` and `GetQueueAttributes`
    on the two queues,
  - `dynamodb:GetItem` and `UpdateItem` on the case table,
  - `bedrock-agentcore:InvokeAgentRuntime` and `InvokeAgentRuntimeForUser` on the agent runtime
    ARN only. The second is needed because every call sends a runtime user ID.
- Both queues hide a received message for 20 minutes, above AgentCore Runtime's 15-minute limit
  for a synchronous request.

## Inquiry agent on AgentCore Runtime

- HTTP protocol, ARM64, port 8080. Each setting reaches the agent in its own
  `BAL_CONFIG_VAR_<NAME>` environment variable, because AgentCore Runtime rejects line breaks in
  values. It holds no secrets: it gets gateway tokens from two AgentCore Identity credential
  providers, which `scripts/04-agent.sh` creates before the stack.
- Execution role (`agent-runtime.yaml`):
  - `bedrock:InvokeModel` on Anthropic models and US inference profiles,
  - `bedrock:ApplyGuardrail` on the guardrail,
  - `bedrock:Retrieve` and `bedrock:IngestKnowledgeBaseDocuments` on the knowledge base,
  - `bedrock-agentcore:GetWorkloadAccessToken*` and `GetResourceOauth2Token` on the workload
    identity directory and token vault,
  - `secretsmanager:GetSecretValue` on the two secrets AgentCore Identity created for the
    agent's providers (passed in as stack parameters), and not on the gateway's.

  Two groups of extra permissions are also required:
  - `GetKnowledgeBase`, `GetDataSource` and `GetKnowledgeBaseDocuments`, which the Ballerina
    knowledge base client calls,
  - ECR pull and CloudWatch Logs, which AgentCore Runtime needs to start the container and keep
    its logs.
  - X-Ray write actions, for the collector in the agent's image that sends its traces to
    CloudWatch.

  The role has no access to SQS or DynamoDB.

## Items to verify before relying on them

The request shapes below come from the AWS documentation available when the sample was
written and from the `ballerinax/ai.aws.bedrock` module source. Check them against the current
API reference for your AWS CLI version:

- `knowledge-base/knowledge-base-configuration.json` and `custom-data-source.json` mirror the
  requests the Ballerina module sends for a `MANAGED` knowledge base and its custom source.
- `knowledge-base/s3-data-source.json` follows the S3 connector for managed knowledge bases:
  `connectionConfiguration.bucketName` and `bucketOwnerAccountId` (required even for a bucket in
  the same account), and `filterConfiguration.inclusionPrefixes`
  (`knowledge/`). Data sources are created asynchronously; `02-knowledge-base.sh` waits until
  each is `AVAILABLE`, and creates one again if it is `FAILED`.
- `agentcore/mcp-runtime.json`, `inquiry-agent.json` follow `create-agent-runtime`. Environment
  variable values may not contain line breaks, so each agent setting is its own variable.
- `cloudformation/listener-ecs.yaml`: `InvokeAgentRuntime` is checked against both the runtime
  ARN and its endpoint ARN (`<runtime ARN>/runtime-endpoint/DEFAULT`), so the task role allows both.
- `cloudformation/agent-runtime.yaml`: **TODO(verify)** the actions and resources AgentCore
  Identity checks for `GetResourceOauth2Token`, and that AgentCore Runtime passes the
  `WorkloadAccessToken` header when the caller sends a runtime user ID.
- `agentcore/oauth-provider.json`: **TODO(verify)** the shape of
  `create-oauth2-credential-provider` for a custom OAuth 2.0 provider (Cognito).
- `agentcore/gateway.json`, `gateway-target.json`: **TODO(verify)** the MCP server target
  type and OAuth outbound credentials for a runtime-hosted MCP server, and the endpoint URL
  format the scripts build for each runtime.
- **TODO(verify)**: whether the gateway can restrict tools by OAuth scope (for example with a
  gateway interceptor or AgentCore Policy). Today the read and write split is enforced by the
  agent (`permittedTools`, write-tool allow list) and by separate Cognito clients.
