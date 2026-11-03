// Calls the inquiry agent on AgentCore Runtime with InvokeAgentRuntime.
//
// No Ballerina connector covers AgentCore Runtime yet, so this sends the HTTPS request directly
// and signs it with SigV4 (`ballerinax/aws.auth`, signing name `bedrock-agentcore`) using the
// ECS task role. The call is synchronous: the agent answers with one JSON document when it has
// finished, which can take several minutes.

import inquiry_listener.core;

import ballerina/http;
import ballerinax/aws.auth;

const string SESSION_ID_HEADER = "x-amzn-bedrock-agentcore-runtime-session-id";

# Invokes the agent and returns its answer.
#
# + payload - The request body for `POST /invocations` on the agent
# + runtimeSessionId - The runtime session ID (at least 33 characters)
# + return - The agent's answer when its `status` is "ok", a `core:AgentError` when the agent
# reports an error, or another error if the call fails
isolated function invokeAgent(map<json> payload, string runtimeSessionId) returns map<json>|error {
    string path = check core:invocationPath(agentRuntimeArn);
    byte[] body = payload.toJsonString().toBytes();
    map<string> headers = {
        "content-type": "application/json",
        "accept": "application/json",
        [SESSION_ID_HEADER]: runtimeSessionId
    };

    // The path already carries the percent-encoded ARN, exactly as the AWS SDKs send it. With
    // `s3PathMode` the signer neither normalizes the path nor double-encodes it; its single
    // encoding pass turns the path into the double-encoded canonical URI (`%253A`, `%252F`) that
    // botocore computes for this operation. Method, URI template, session-ID header, `qualifier`
    // query parameter and signing name match the botocore service model.
    // TODO(verify): confirm against a live runtime that `http:Client` sends the path unchanged;
    // if AgentCore rejects the signature, compare with the AWS CLI's canonical request (`--debug`).
    map<string> signedHeaders = check auth:getSignedHeaders({
        method: "POST",
        host: agentCoreHost,
        path,
        queryParams: {qualifier: agentRuntimeQualifier},
        headers,
        payload: body,
        s3PathMode: true
    }, check credentialProvider.getCredentials(), awsRegion, "bedrock-agentcore");

    http:Request request = new;
    request.setBinaryPayload(body);
    foreach [string, string] [name, value] in headers.entries() {
        request.setHeader(name, value);
    }
    foreach [string, string] [name, value] in signedHeaders.entries() {
        request.setHeader(name, value);
    }

    http:Response response = check agentCore->post(string `${path}?qualifier=${agentRuntimeQualifier}`, request);
    json answer = check response.getJsonPayload();
    if response.statusCode >= 300 {
        return error(string `InvokeAgentRuntime failed with HTTP ${response.statusCode}: ${answer.toJsonString()}`);
    }
    map<json> result = check answer.ensureType();
    if result["status"] != "ok" {
        json codeValue = result["code"];
        string code = codeValue is string ? codeValue : "UnknownError";
        return error core:AgentError(string `${code}: ${(result["message"] ?: "").toString()}`, code = code);
    }
    return result;
}
