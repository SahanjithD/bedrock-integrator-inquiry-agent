# Infrastructure

| Path | Deployed by | Contents |
| --- | --- | --- |
| `cloudformation/foundation.yaml` | `scripts/01-foundation.sh` | SQS jobs and decisions queues with DLQs, DynamoDB case table, knowledge bucket, Cognito machine clients, client-secret secret |
| `cloudformation/knowledge.yaml` | `scripts/02-knowledge-base.sh` | Guardrail (PII masking) and the knowledge base service role |
| `knowledge-base/*.json` | `scripts/02-knowledge-base.sh` | Request bodies for the managed knowledge base and its two data sources |
| `cloudformation/mcp-servers.yaml` | `scripts/03-mcp-servers.sh` | ECR repositories and IAM roles for the MCP server runtimes and the gateway |
| `agentcore/*.json` | `scripts/03-mcp-servers.sh` | Request bodies for the MCP runtimes, the OAuth credential provider, the gateway and its targets |
| `cloudformation/agent-ecs.yaml` | `scripts/04-agent.sh` | Inquiry agent on Amazon ECS: VPC with public subnets, security group (outbound only), ECR repository, cluster, Fargate task definition and service, task and execution roles, log group |

AgentCore and the managed knowledge base are created with the AWS CLI rather than
CloudFormation because they are new. The scripts fill in the JSON templates with `jq`, so the
request shapes are easy to review in one place.

## Inquiry agent on ECS

- Fargate, ARM64, two tasks by default. Each task runs one investigation and one decision at a
  time, so scale with `DesiredCount`.
- Public subnets with `AssignPublicIp`, and a security group with outbound HTTPS only. The
  agent has no inbound ports. This keeps the sample small. For production, use private
  subnets with VPC endpoints or a NAT gateway.
- Settings reach the agent in `BAL_CONFIG_DATA`. The two Cognito client secrets are injected
  from AWS Secrets Manager by ECS (`secrets` in the task definition), using the execution role.
- Task role permissions:
  - `bedrock:InvokeModel` on Anthropic models and US inference profiles, and
    `bedrock:ApplyGuardrail` on the guardrail.
  - `bedrock:Retrieve` and `bedrock:IngestKnowledgeBaseDocuments` on the knowledge base.
    The Ballerina client also needs `GetKnowledgeBase`, `GetDataSource` and
    `GetKnowledgeBaseDocuments`.
  - `sqs:ReceiveMessage`, `DeleteMessage`, `ChangeMessageVisibility` and `GetQueueAttributes`
    on the two queues.
  - `dynamodb:GetItem` and `UpdateItem` on the case table.

## Items to verify before relying on them

The request shapes below come from the AWS documentation available when the sample was
written and from the `ballerinax/ai.aws.bedrock` module source. Check them against the current
API reference for your AWS CLI version:

- `knowledge-base/knowledge-base-configuration.json` and `custom-data-source.json` mirror the
  requests the Ballerina module sends for a `MANAGED` knowledge base and its custom source.
- `knowledge-base/s3-data-source.json`: **TODO(verify)** the connector parameters for an S3
  source on a managed knowledge base (`type`, `version`, `bucketArn`, `inclusionPrefixes`).
  If they differ, add the S3 source in the console (prefix `knowledge/`) and set
  `S3DataSourceId` in `.deploy/outputs.env`.
- `agentcore/mcp-runtime.json`: **TODO(verify)** field names for
  `bedrock-agentcore-control create-agent-runtime`.
- `agentcore/oauth-provider.json`: **TODO(verify)** the shape of
  `create-oauth2-credential-provider` for a custom OAuth 2.0 provider (Cognito).
- `agentcore/gateway.json`, `gateway-target.json`: **TODO(verify)** the MCP server target
  type and OAuth outbound credentials for a runtime-hosted MCP server, and the endpoint URL
  format the scripts build for each runtime.
- **TODO(verify)**: whether the gateway can restrict tools by OAuth scope (for example with a
  gateway interceptor or AgentCore Policy). Today the read and write split is enforced by the
  agent (`permittedTools`, write-tool allow list) and by separate Cognito clients.
