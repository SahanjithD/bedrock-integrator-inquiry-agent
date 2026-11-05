// Gateway tokens from AgentCore Identity.
//
// The inquiry listener names the representative as the runtime user ID on each call. AgentCore
// Runtime then passes the agent a workload access token for that user in the `WorkloadAccessToken`
// header. The agent exchanges it with AgentCore Identity (`GetResourceOauth2Token`, M2M flow) for
// a Cognito client-credentials token from the investigator or applier credential provider. The
// Cognito client secrets stay in AgentCore Identity; the agent never sees them.
//
// No Ballerina connector covers AgentCore Identity yet, so the requests are signed with SigV4
// (`ballerinax/aws.auth`, signing name `bedrock-agentcore`) using the runtime's execution role.

import inquiry_agent.core;

import ballerina/http;
import ballerinax/aws.auth;

# Header in which AgentCore Runtime passes the workload access token to each invocation.
const string WORKLOAD_ACCESS_TOKEN_HEADER = "WorkloadAccessToken";

# Gets a gateway access token from a credential provider.
#
# + workloadToken - The invocation's workload access token
# + providerName - The credential provider, e.g. `inquiry-agent-investigator`
# + scopes - The OAuth scopes to request
# + return - The access token, or an error
isolated function gatewayToken(string workloadToken, string providerName, readonly & string[] scopes)
        returns string|error {
    map<json> answer = check callIdentity("/identities/oauth2/token", {
        workloadIdentityToken: workloadToken,
        resourceCredentialProviderName: providerName,
        scopes,
        oauth2Flow: "M2M"
    });
    json token = answer["accessToken"];
    if token !is string {
        return error(string `Credential provider ${providerName} returned no access token`);
    }
    return token;
}

# Returns the workload access token for one invocation: the one AgentCore Runtime passed in or,
# for a local run, one fetched for `localWorkloadName` and `localUserId`.
#
# + fromRuntime - The `WorkloadAccessToken` header, if present
# + return - The workload access token, or an `AgentError` if there is none
isolated function workloadToken(string? fromRuntime) returns string|error {
    if fromRuntime is string && fromRuntime.trim() != "" {
        return fromRuntime;
    }
    if localWorkloadName == "" {
        return error core:AgentError(string `The request has no ${WORKLOAD_ACCESS_TOKEN_HEADER} header. ` +
            "Invoke the runtime with a user ID (X-Amzn-Bedrock-AgentCore-Runtime-User-Id), " +
            "or set localWorkloadName for a local run.", code = core:INVALID_REQUEST);
    }
    map<json> answer = check callIdentity("/identities/GetWorkloadAccessTokenForUserId",
        {workloadName: localWorkloadName, userId: localUserId});
    json token = answer["workloadAccessToken"];
    if token !is string {
        return error(string `No workload access token for ${localWorkloadName}`);
    }
    return token;
}

# Sends one SigV4-signed JSON request to the AgentCore Identity data plane.
#
# + path - The operation's request path
# + request - The request body
# + return - The response body, or an error
isolated function callIdentity(string path, map<json> request) returns map<json>|error {
    byte[] body = request.toJsonString().toBytes();
    map<string> headers = {"content-type": "application/json", "accept": "application/json"};
    map<string> signedHeaders = check auth:getSignedHeaders(
        {method: "POST", host: agentCoreHost, path, headers, payload: body},
        check awsCredentials.getCredentials(), awsRegion, "bedrock-agentcore");

    http:Request outbound = new;
    outbound.setBinaryPayload(body);
    foreach [string, string] [name, value] in headers.entries() {
        outbound.setHeader(name, value);
    }
    foreach [string, string] [name, value] in signedHeaders.entries() {
        outbound.setHeader(name, value);
    }
    http:Response response = check agentCore->post(path, outbound);
    json|error answer = response.getJsonPayload();
    if response.statusCode >= 300 {
        // The error document names the failure; it never contains a token.
        string detail = answer is json ? answer.toJsonString() : "";
        return error(string `AgentCore Identity ${path} failed with HTTP ${response.statusCode}: ${detail}`);
    }
    if answer is error {
        return answer;
    }
    return answer.ensureType();
}
