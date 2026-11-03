// Long-lived clients, created once per task. All of them use the ECS task role.

import ballerina/http;
import ballerinax/aws;
import ballerinax/aws.auth;
import ballerinax/aws.dynamodb;
import ballerinax/aws.sqs;

# Case table, standing in for the ticket in a real support system.
final dynamodb:Client caseStore = check new ({auth: auth:DEFAULT_CREDENTIALS, region: awsRegion});

# Used to shorten a failed message's visibility so it is retried sooner.
final sqs:Client queues = check new ({auth: auth:DEFAULT_CREDENTIALS, region: awsRegion});

# Credentials of the ECS task role, used to sign InvokeAgentRuntime requests.
final auth:CredentialProvider credentialProvider = check new (auth:DEFAULT_CREDENTIALS);

# AgentCore data plane host, e.g. `bedrock-agentcore.us-east-1.amazonaws.com`.
final string agentCoreHost = aws:resolveEndpointHost("bedrock-agentcore", awsRegion);

# HTTP client for InvokeAgentRuntime. The timeout covers the longest synchronous call.
final http:Client agentCore = check new ("https://" + agentCoreHost, {timeout: agentTimeoutSeconds});
