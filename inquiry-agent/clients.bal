// Long-lived clients, created once per container. Nothing here holds case state:
// cases live in DynamoDB, workflow state in Step Functions, and knowledge in the KB.

import ballerina/ai;
import ballerinax/ai.aws.bedrock;
import ballerinax/aws.auth;
import ballerinax/aws.dynamodb;

# Bedrock model, called through the Converse API with the guardrail on every request.
final ai:ModelProvider model = check new bedrock:ConverseModelProvider(
    modelId, auth:DEFAULT_CREDENTIALS, awsRegion,
    maxTokens = maxTokens,
    guardrail = {guardrailIdentifier: guardrailId, guardrailVersion}
);

# Managed knowledge base. Retrieval searches every data source (runbooks, policies and
# resolved cases); ingestion writes to the custom data source only.
final bedrock:ManagedKnowledgeBase knowledgeBase = check new (
    knowledgeBaseId, auth:DEFAULT_CREDENTIALS, awsRegion,
    dataSourceId = customDataSourceId
);

# Case table, standing in for the ticket in a real support system.
final dynamodb:Client caseStore = check new ({auth: auth:DEFAULT_CREDENTIALS, region: awsRegion});

# Cognito client secrets for the gateway, read once at startup.
final GatewayClientSecrets & readonly gatewaySecrets = check loadGatewayClientSecrets();
