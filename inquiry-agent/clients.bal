// Long-lived clients, created once per task. Nothing here holds case state: cases live in
// DynamoDB, pending work in SQS, and knowledge in the knowledge base.

import ballerina/ai;
import ballerina/os;
import ballerinax/ai.aws.bedrock;
import ballerinax/aws.auth;
import ballerinax/aws.dynamodb;
import ballerinax/aws.sqs;

# Bedrock model, called through the Converse API with the guardrail on every request.
final ai:ModelProvider model = check new bedrock:ConverseModelProvider(
    modelId, auth:DEFAULT_CREDENTIALS, awsRegion,
    maxTokens = maxTokens,
    guardrail = {guardrailIdentifier: guardrailId, guardrailVersion}
);

# Managed knowledge base. Retrieval searches every data source (runbooks, policies and
# resolved cases); ingestion writes to the custom data source only. Managed reranking is
# off, so the task role needs no `bedrock:Rerank` permission.
final bedrock:ManagedKnowledgeBase knowledgeBase = check new (
    knowledgeBaseId, auth:DEFAULT_CREDENTIALS, awsRegion,
    dataSourceId = customDataSourceId,
    rerankingModelType = bedrock:RERANKING_NONE
);

# Case table, standing in for the ticket in a real support system.
final dynamodb:Client caseStore = check new ({auth: auth:DEFAULT_CREDENTIALS, region: awsRegion});

# Used to shorten a failed message's visibility so it is retried sooner.
final sqs:Client queues = check new ({auth: auth:DEFAULT_CREDENTIALS, region: awsRegion});

// ECS injects these from AWS Secrets Manager (the `secrets` section of the task definition).
final string investigatorClientSecret = check requiredEnv("INVESTIGATOR_CLIENT_SECRET");
final string applierClientSecret = check requiredEnv("APPLIER_CLIENT_SECRET");

isolated function requiredEnv(string name) returns string|error {
    string value = os:getEnv(name);
    if value == "" {
        return error(string `Environment variable ${name} is not set`);
    }
    return value;
}
