# Infrastructure

| Path | Deployed by | Contents |
| --- | --- | --- |
| `cloudformation/foundation.yaml` | `scripts/01-foundation.sh` | SQS job, decision and failure queues (with DLQs), DynamoDB case table, knowledge bucket, ECR repositories, guardrail, Cognito machine clients, client-secret secret, IAM roles |
| `knowledge-base/*.json` | `scripts/03-knowledge-base.sh` | Request bodies for the managed knowledge base and its two data sources |
| `agentcore/*.json` | `scripts/04`–`06` | Request bodies for the AgentCore runtimes, the OAuth credential provider, the gateway and its targets |
| `cloudformation/workflows.yaml` | `scripts/07-workflows.sh` | Lambda dispatcher, the two Step Functions state machines, the two EventBridge Pipes |
| `statemachines/*.asl.json` | packaged with `workflows.yaml` | State machine definitions (JSONata) |
| `dispatcher/handler.py` | packaged with `workflows.yaml` | Starts one agent invocation and returns |

AgentCore and the managed knowledge base are created with the AWS CLI rather than
CloudFormation because they are new. The scripts fill in the JSON templates with `jq`, so the
request shapes are easy to review in one place.

## Items to verify before relying on them

The request shapes below come from the AWS documentation available when the sample was
written and from the `ballerinax/ai.aws.bedrock` module source. Check them against the current
API reference for your AWS CLI version:

- `knowledge-base/knowledge-base-configuration.json` and `custom-data-source.json` mirror the
  requests the Ballerina module sends for a `MANAGED` knowledge base and its custom source.
- `knowledge-base/s3-data-source.json`: **TODO(verify)** the connector parameters for an S3
  source on a managed knowledge base (`type`, `version`, `bucketArn`, `inclusionPrefixes`).
  If they differ, add the S3 source in the console and set `S3_DATA_SOURCE_ID` in
  `.deploy/outputs.env`.
- `agentcore/mcp-runtime.json`, `agent-runtime.json`: **TODO(verify)** field names for
  `bedrock-agentcore-control create-agent-runtime`, including `environmentVariables`.
- `agentcore/oauth-provider.json`: **TODO(verify)** the shape of
  `create-oauth2-credential-provider` for a custom OAuth 2.0 provider (Cognito).
- `agentcore/gateway.json`, `gateway-target.json`: **TODO(verify)** the MCP server target
  type and OAuth outbound credentials for a runtime-hosted MCP server, and the endpoint URL
  format the scripts build for each runtime.
- **TODO(verify)**: whether the gateway can restrict tools by OAuth scope (for example with a
  gateway interceptor or AgentCore Policy). Today the read and write split is enforced by the
  agent (`permittedTools`, write-tool allow list) and by separate Cognito clients.
