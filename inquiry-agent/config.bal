// Settings. On AgentCore Runtime they arrive in the `BAL_CONFIG_DATA` environment variable,
// which scripts/06-agent-runtime.sh renders from Config.toml.example. No secrets go here:
// the Cognito client secrets are read from AWS Secrets Manager at startup.

# AWS Region for every AWS call.
configurable string awsRegion = "us-east-1";

// Claude Sonnet 5.5 through the US cross-Region inference profile. The base model ID
// is not callable on demand; use a `us.` or `global.` profile ID.
// https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-anthropic-claude-sonnet-5-5.html
# Bedrock model or inference profile ID.
configurable string modelId = "us.anthropic.claude-sonnet-5-5";
# Upper limit on tokens per model response.
configurable int maxTokens = 4096;
# Upper limit on reasoning and tool-call cycles per investigation.
configurable int maxIterations = 12;

# Guardrail ID or ARN. The guardrail masks personal data in model input and output.
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
# App client used by the investigate action (read scope only).
configurable string investigatorClientId = ?;
# App client used by the apply action (write scope only).
configurable string applierClientId = ?;
# OAuth scopes requested by the investigate action.
configurable string[] readScopes = ["inquiry-gateway/read"];
# OAuth scopes requested by the apply action.
configurable string[] writeScopes = ["inquiry-gateway/write"];
# Secrets Manager secret with `investigatorClientSecret` and `applierClientSecret`.
configurable string clientSecretsArn = ?;
