// Long-lived clients, created once per container. The agent holds no case state: the inquiry
// listener keeps cases in DynamoDB, and knowledge lives in the knowledge base.

import ballerina/ai;
import ballerina/http;
import ballerinax/ai.aws.bedrock;
import ballerinax/aws;
import ballerinax/aws.auth;

# Bedrock model, called through the Converse API with the guardrail on every request.
final ai:ModelProvider model = check new bedrock:ConverseModelProvider(
    modelId, auth:DEFAULT_CREDENTIALS, awsRegion,
    maxTokens = maxTokens,
    guardrail = {guardrailIdentifier: guardrailId, guardrailVersion}
);

# Managed knowledge base. Retrieval searches every data source (runbooks, policies and
# resolved cases); ingestion writes to the custom data source only. Managed reranking is
# off, so the runtime role needs no `bedrock:Rerank` permission.
final bedrock:ManagedKnowledgeBase knowledgeBase = check new (
    knowledgeBaseId, auth:DEFAULT_CREDENTIALS, awsRegion,
    dataSourceId = customDataSourceId,
    rerankingModelType = bedrock:RERANKING_NONE
);

# Credentials of the runtime's execution role, used to sign AgentCore Identity requests.
final auth:CredentialProvider awsCredentials = check new (auth:DEFAULT_CREDENTIALS);

# AgentCore data plane host, e.g. `bedrock-agentcore.us-east-1.amazonaws.com`.
final string agentCoreHost = aws:resolveEndpointHost("bedrock-agentcore", awsRegion);

# HTTP client for AgentCore Identity.
final http:Client agentCore = check new ("https://" + agentCoreHost, {timeout: 30});
