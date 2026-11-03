# Infrastructure

| Path | Deployed by | Contents |
| --- | --- | --- |
| `cloudformation/foundation.yaml` | `scripts/01-foundation.sh` | SQS jobs and decisions queues (with DLQs), DynamoDB case table, knowledge bucket, ECR repositories, guardrail, Cognito machine clients, client-secret secret, IAM roles |
| `knowledge-base/*.json` | `scripts/02-knowledge-base.sh` | Request bodies for the managed knowledge base and its two data sources |
| `agentcore/*.json` | `scripts/03-mcp-servers.sh`, `scripts/04-agent.sh` | Request bodies for the AgentCore runtimes, the OAuth credential provider, the gateway and its targets |
| `cloudformation/dispatcher.yaml` | `scripts/05-dispatcher.sh` | Lambda dispatcher: investigate and apply functions, SQS event source mappings, role, log groups |
| `dispatcher/handler.py` | packaged with `dispatcher.yaml` | The two handlers |
| `dispatcher/tests/` | run locally | Handler tests against an in-memory DynamoDB (`moto`) |

AgentCore and the managed knowledge base are created with the AWS CLI rather than
CloudFormation because they are new. The scripts fill in the JSON templates with `jq`, so the
request shapes are easy to review in one place.

## Lambda dispatcher

- Python 3.12 on ARM64. Two functions share one package: `investigate_handler` on the jobs
  queue and `apply_handler` on the decisions queue.
- Event source mappings use batch size 1 with `ReportBatchItemFailures`. The investigate
  mapping caps concurrency at `MaxConcurrentInvestigations` (default 5), so a burst of jobs
  waits in the queue instead of exceeding the model's quotas.
- Function timeout 900 s, Lambda's maximum. The agent stops an investigation after 600 s, and the
  function stops waiting for the agent after 870 s. AgentCore Runtime also ends a synchronous
  request after 15 minutes.
- Both queues have a visibility timeout of 5400 s (6x the function timeout) and move a message to
  the DLQ after three receives.
- Role: `sqs:ReceiveMessage`, `DeleteMessage` and `GetQueueAttributes` on the two queues;
  `dynamodb:GetItem` and `UpdateItem` on the case table; `bedrock-agentcore:InvokeAgentRuntime`
  on the agent runtime only; and writes to its own two log groups (7-day retention).

Run the handler tests:

```bash
pip install -r infra/dispatcher/tests/requirements.txt
```

```bash
python -m pytest infra/dispatcher/tests
```

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
- `agentcore/mcp-runtime.json`, `agent-runtime.json`: **TODO(verify)** field names for
  `bedrock-agentcore-control create-agent-runtime`, including `environmentVariables`.
- `agentcore/oauth-provider.json`: **TODO(verify)** the shape of
  `create-oauth2-credential-provider` for a custom OAuth 2.0 provider (Cognito).
- `agentcore/gateway.json`, `gateway-target.json`: **TODO(verify)** the MCP server target
  type and OAuth outbound credentials for a runtime-hosted MCP server, and the endpoint URL
  format the scripts build for each runtime.
- `cloudformation/dispatcher.yaml`: **TODO(verify)** whether `InvokeAgentRuntime` also needs
  the runtime endpoint ARN as a resource, and that the Lambda runtime's bundled boto3 has the
  `bedrock-agentcore` client.
- **TODO(verify)**: whether the gateway can restrict tools by OAuth scope (for example with a
  gateway interceptor or AgentCore Policy). Today the read and write split is enforced by the
  agent (`permittedTools`, write-tool allow list) and by separate Cognito clients.
