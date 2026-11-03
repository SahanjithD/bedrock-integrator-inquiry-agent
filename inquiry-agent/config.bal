// Settings. On Amazon ECS they arrive in the `BAL_CONFIG_DATA` environment variable, set by
// infra/cloudformation/agent-ecs.yaml. The Cognito client secrets are not settings: ECS injects
// them from AWS Secrets Manager as environment variables (see clients.bal).

# AWS Region for every AWS call.
configurable string awsRegion = "us-east-1";

# Queue with investigation jobs from the support console.
configurable string jobQueueUrl = ?;
# Queue with approve or reject decisions from the support console.
configurable string decisionQueueUrl = ?;

// An investigation can take several minutes. The jobs queue hides a received message for
// longer than the longest expected run, so another task does not pick it up meanwhile.
# Seconds a received job stays hidden from other consumers.
configurable int jobVisibilitySeconds = 900;
# Seconds a received decision stays hidden from other consumers.
configurable int decisionVisibilitySeconds = 300;
# Seconds before a failed message is retried. SQS moves it to the DLQ after 3 receives.
configurable int retryDelaySeconds = 60;
# Investigation attempts before a case is marked FAILED. Keep equal to the queue's maxReceiveCount.
configurable int maxAttempts = 3;

// Claude Sonnet 5.5 through the US cross-Region inference profile. The base model ID
// is not callable on demand; use a `us.` or `global.` profile ID.
// https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-anthropic-claude-sonnet-5-5.html
# Bedrock model or inference profile ID.
configurable string modelId = "us.anthropic.claude-sonnet-5-5";
# Upper limit on tokens per model response.
configurable int maxTokens = 4096;
# Upper limit on reasoning and tool-call cycles per investigation.
configurable int maxIterations = 12;

# Guardrail ID or ARN. The guardrail masks personal data in the model's output.
configurable string guardrailId = ?;
# Guardrail version, e.g. `1`.
configurable string guardrailVersion = ?;

# Managed knowledge base ID.
configurable string knowledgeBaseId = ?;
# ID of the knowledge base's custom data source, which holds resolved cases.
configurable string customDataSourceId = ?;
# Passages returned per knowledge base search.
configurable int knowledgeResults = 5;

# DynamoDB table that holds one item per case.
configurable string caseTable = ?;

# AgentCore Gateway MCP endpoint, e.g. `https://<gateway-id>.gateway.bedrock-agentcore.<region>.amazonaws.com/mcp`.
configurable string gatewayUrl = ?;
# Cognito token endpoint, e.g. `https://<domain>.auth.<region>.amazoncognito.com/oauth2/token`.
configurable string tokenUrl = ?;
# App client used for investigations (read scope only).
configurable string investigatorClientId = ?;
# App client used to apply approved changes (write scope only).
configurable string applierClientId = ?;
# OAuth scopes requested for investigations.
configurable string[] readScopes = ["inquiry-gateway/read"];
# OAuth scopes requested to apply approved changes.
configurable string[] writeScopes = ["inquiry-gateway/write"];
