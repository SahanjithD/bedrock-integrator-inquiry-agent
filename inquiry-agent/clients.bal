// Long-lived clients, created once per container. The agent holds no case state: the inquiry
// listener keeps cases in DynamoDB, and knowledge lives in the knowledge base.

import ballerina/ai;
import ballerinax/ai.aws.bedrock;
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

# Cognito client secrets for the gateway, read once at startup.
final GatewayClientSecrets & readonly gatewaySecrets = check loadGatewayClientSecrets();
