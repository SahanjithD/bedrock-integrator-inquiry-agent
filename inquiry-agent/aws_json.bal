// Small client for AWS JSON-protocol APIs that have no dedicated Ballerina connector:
// Step Functions (task callbacks) and Secrets Manager (gateway client secrets).
// Requests are signed with SigV4 by `ballerinax/aws.auth`.

import ballerina/http;
import ballerinax/aws;
import ballerinax/aws.auth;

final auth:CredentialProvider credentialProvider = check new (auth:DEFAULT_CREDENTIALS);

final AwsJsonService stepFunctions = check new ("states", "1.0");
final AwsJsonService secretsManager = check new ("secretsmanager", "1.1");

# Calls one AWS JSON-protocol service.
isolated client class AwsJsonService {
    private final http:Client httpClient;
    private final string host;
    private final string serviceName;
    private final string contentType;

    # + serviceName - Endpoint prefix and signing name, e.g. `states`
    # + jsonVersion - The service's JSON protocol version, `1.0` or `1.1`
    # + return - An error if the HTTP client cannot be created
    isolated function init(string serviceName, string jsonVersion) returns error? {
        self.serviceName = serviceName;
        self.host = aws:resolveEndpointHost(serviceName, awsRegion);
        self.contentType = string `application/x-amz-json-${jsonVersion}`;
        self.httpClient = check new ("https://" + self.host, {timeout: 30});
    }

    # Sends one signed request.
    #
    # + target - The `X-Amz-Target` value, e.g. `AWSStepFunctions.SendTaskSuccess`
    # + body - The request document
    # + return - The response document, or an error with the service's message
    isolated remote function call(string target, json body) returns json|error {
        byte[] payload = body.toJsonString().toBytes();
        map<string> headers = {"content-type": self.contentType, "x-amz-target": target};
        auth:Credentials credentials = check credentialProvider.getCredentials();
        map<string> signedHeaders = check auth:getSignedHeaders({
            method: "POST",
            host: self.host,
            headers,
            payload
        }, credentials, awsRegion, self.serviceName);

        http:Request request = new;
        request.setBinaryPayload(payload);
        foreach [string, string] [name, value] in headers.entries() {
            request.setHeader(name, value);
        }
        foreach [string, string] [name, value] in signedHeaders.entries() {
            request.setHeader(name, value);
        }
        http:Response response = check self.httpClient->post("/", request);
        json|error document = response.getJsonPayload();
        if response.statusCode >= 300 {
            string detail = document is json ? document.toJsonString() : "no response body";
            return error(string `${target} failed with HTTP ${response.statusCode}: ${detail}`);
        }
        return document is json ? document : {};
    }
}

// Step Functions limits: task output 256 KiB, error 256 chars, cause 32,768 chars.
const int MAX_ERROR_LENGTH = 256;
const int MAX_CAUSE_LENGTH = 32000;

# Reports a successful action to the waiting Step Functions task.
#
# + taskToken - The task token from the invocation
# + output - The task output
# + return - An error if Step Functions rejects the callback
isolated function sendTaskSuccess(string taskToken, json output) returns error? {
    _ = check stepFunctions->call("AWSStepFunctions.SendTaskSuccess",
        {taskToken, output: output.toJsonString()});
}

# Reports a failed action to the waiting Step Functions task.
#
# + taskToken - The task token from the invocation
# + code - The error name the state machine matches on
# + cause - A human-readable explanation
# + return - An error if Step Functions rejects the callback
isolated function sendTaskFailure(string taskToken, string code, string cause) returns error? {
    _ = check stepFunctions->call("AWSStepFunctions.SendTaskFailure", {
        taskToken,
        'error: truncate(code, MAX_ERROR_LENGTH),
        cause: truncate(cause, MAX_CAUSE_LENGTH)
    });
}

isolated function truncate(string value, int maxLength) returns string =>
    value.length() <= maxLength ? value : value.substring(0, maxLength);

# Client secrets for the two Cognito app clients that call the gateway.
type GatewayClientSecrets record {
    string investigatorClientSecret;
    string applierClientSecret;
};

# Reads the gateway client secrets from Secrets Manager.
#
# + return - The secrets, or an error
isolated function loadGatewayClientSecrets() returns GatewayClientSecrets & readonly|error {
    json response = check secretsManager->call("secretsmanager.GetSecretValue", {SecretId: clientSecretsArn});
    json secretField = check response.SecretString;
    string secretString = check secretField.ensureType();
    json secret = check secretString.fromJsonString();
    GatewayClientSecrets secrets = check secret.cloneWithType();
    return secrets.cloneReadOnly();
}
