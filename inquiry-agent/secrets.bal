// Reads the Cognito client secrets from AWS Secrets Manager. There is no dedicated Ballerina
// connector for Secrets Manager, so the request is signed with SigV4 by `ballerinax/aws.auth`.

import ballerina/http;
import ballerinax/aws;
import ballerinax/aws.auth;

# Client secrets for the two Cognito app clients that call the gateway.
type GatewayClientSecrets record {
    string investigatorClientSecret;
    string applierClientSecret;
};

# Reads the gateway client secrets once, at startup.
#
# + return - The secrets, or an error
function loadGatewayClientSecrets() returns GatewayClientSecrets & readonly|error {
    auth:CredentialProvider credentials = check new (auth:DEFAULT_CREDENTIALS);
    string host = aws:resolveEndpointHost("secretsmanager", awsRegion);
    http:Client secretsManager = check new ("https://" + host, {timeout: 30});

    map<string> headers = {
        "content-type": "application/x-amz-json-1.1",
        "x-amz-target": "secretsmanager.GetSecretValue"
    };
    json body = {SecretId: clientSecretsArn};
    byte[] payload = body.toJsonString().toBytes();
    map<string> signedHeaders = check auth:getSignedHeaders(
        {method: "POST", host, headers, payload}, check credentials.getCredentials(), awsRegion, "secretsmanager");

    http:Request request = new;
    request.setBinaryPayload(payload);
    foreach [string, string] [name, value] in headers.entries() {
        request.setHeader(name, value);
    }
    foreach [string, string] [name, value] in signedHeaders.entries() {
        request.setHeader(name, value);
    }
    http:Response response = check secretsManager->post("/", request);
    json document = check response.getJsonPayload();
    if response.statusCode >= 300 {
        return error(string `GetSecretValue failed with HTTP ${response.statusCode}: ${document.toJsonString()}`);
    }
    json secretField = check document.SecretString;
    string secretString = check secretField.ensureType();
    GatewayClientSecrets secrets = check (check secretString.fromJsonString()).cloneWithType();
    return secrets.cloneReadOnly();
}
