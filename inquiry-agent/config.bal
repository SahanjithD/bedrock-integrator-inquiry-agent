// Settings. On AgentCore Runtime each one arrives in its own `BAL_CONFIG_VAR_<NAME>` environment
// variable, which scripts/04-agent.sh sets. No secrets go here: gateway tokens come from AgentCore
// Identity credential providers, which hold the Cognito client secrets.

# AWS Region for every AWS call.
configurable string awsRegion = "us-east-1";

// Claude Sonnet 5.5 through the US cross-Region inference profile. The base model ID
// is not callable on demand; use a `us.` or `global.` profile ID.
// https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-anthropic-claude-sonnet-5-5.html
# Bedrock model or inference profile ID.
configurable string modelId = "us.anthropic.claude-sonnet-5-5";
# Upper limit on tokens per model response. Adaptive thinking counts toward it, so keep room for
# the reasoning as well as the findings.
configurable int maxTokens = 16000;
# Upper limit on reasoning and tool-call cycles per investigation.
configurable int maxIterations = 12;

// AgentCore Runtime ends a synchronous InvokeAgentRuntime request after 15 minutes. The agent
// stops an investigation well before that, so the inquiry listener always gets an answer.
# Seconds an investigation may run before the agent gives up and returns an error.
configurable decimal investigationTimeoutSeconds = 600;

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

# AgentCore Gateway MCP endpoint, e.g. `https://<gateway-id>.gateway.bedrock-agentcore.<region>.amazonaws.com/mcp`.
configurable string gatewayUrl = ?;
# AgentCore Identity credential provider for the investigate action (Cognito client with the read scope).
configurable string investigatorCredentialProvider = ?;
# AgentCore Identity credential provider for the apply action (Cognito client with the write scope).
configurable string applierCredentialProvider = ?;
# OAuth scopes requested by the investigate action.
configurable readonly & string[] readScopes = ["inquiry-gateway/read"];
# OAuth scopes requested by the apply action.
configurable readonly & string[] writeScopes = ["inquiry-gateway/write"];

// On AgentCore Runtime the workload access token arrives with each request. For a local run,
// which has no such header, the agent fetches one for this workload identity and user instead.
# Workload identity used for local runs only. Leave empty on AgentCore Runtime.
configurable string localWorkloadName = "";
# User ID used for local runs only.
configurable string localUserId = "local-developer";
