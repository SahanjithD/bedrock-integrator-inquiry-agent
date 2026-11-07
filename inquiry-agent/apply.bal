// The apply action: call the one write tool a representative approved, then record the
// resolved case in the knowledge base.
//
// The inquiry listener loads the approved proposal from the case item and sends it here; the
// decision message never carries it. The listener also owns the case status (claim with
// PENDING_APPROVAL -> APPLYING before calling, APPLIED after), so this action holds no state.

import inquiry_agent.core;

import ballerina/ai;
import ballerina/log;
import ballerina/mcp;

# Applies an approved proposal.
#
# + request - The invocation, already checked by `core:checkRequest`
# + workloadAccessToken - The `WorkloadAccessToken` header, if present
# + return - The response body, or an error
isolated function applyApproved(core:InvocationRequest & readonly request, string? workloadAccessToken)
        returns json|error {
    string caseId = request.caseId;
    int version = check request?.proposalVersion.ensureType();
    core:ProposedAction action = check request?.proposedAction.ensureType();

    // Without a token the write tool is never called, so the outcome is known.
    string|error token = gatewayTokenForApply(workloadAccessToken);
    if token is error {
        return error core:AgentError(string `${action.tool} not called: ${token.message()}`, token,
            code = core:APPLY_REJECTED);
    }

    json|error applyResult = callWriteTool(caseId, version, action, token);
    if applyResult is error {
        return error core:AgentError(string `${action.tool} failed: ${applyResult.message()}`, applyResult,
            code = core:APPLY_FAILED);
    }
    log:printInfo("Approved change applied", caseId = caseId, proposalVersion = version, tool = action.tool);

    boolean ingested = true;
    error? ingestResult = ingestResolvedCase(caseId, version, action, request?.findings, applyResult);
    if ingestResult is error {
        // The change is applied; a missing knowledge base entry does not undo it.
        ingested = false;
        log:printWarn("Resolved case not added to the knowledge base", ingestResult, caseId = caseId);
    }
    return {status: "ok", caseId, applyResult, knowledgeBaseUpdated: ingested};
}

# Gets a gateway token from the applier credential provider (write scope).
#
# + workloadAccessToken - The `WorkloadAccessToken` header, if present
# + return - The access token, or an error
isolated function gatewayTokenForApply(string? workloadAccessToken) returns string|error =>
    gatewayToken(check workloadToken(workloadAccessToken), applierCredentialProvider, writeScopes);

# Calls exactly one write tool through the gateway, with an applier token (write scope).
#
# + caseId - The case ID
# + version - The approved proposal version
# + action - The approved proposal
# + token - The gateway access token
# + return - The tool's response, or an error
isolated function callWriteTool(string caseId, int version, core:ProposedAction action, string token)
        returns json|error {
    mcp:StreamableHttpClient gateway = check new (gatewayUrl, auth = {token}, timeout = 60);
    check gateway->initialize({name: "inquiry-agent-apply", version: "0.1.0"});

    // Write tools are idempotent per approval ID.
    map<json> arguments = {...action.arguments};
    arguments["approvalId"] = core:approvalIdFor(caseId, version);
    mcp:CallToolResult result = check gateway->callTool({name: action.tool, arguments});
    error? closed = gateway->close();
    if closed is error {
        log:printDebug("Closing the gateway connection failed", closed);
    }

    string[] texts = [];
    foreach mcp:ContentBlock block in result.content {
        if block is mcp:TextContent {
            texts.push(block.text);
        }
    }
    if result?.isError == true {
        return error(string `${action.tool} returned an error: ${string:'join(" ", ...texts)}`);
    }
    map<anydata>? structured = result?.structuredContent;
    if structured is map<json> {
        return {tool: action.tool, result: structured};
    }
    json[] parsed = from string text in texts
        let json|error value = text.fromJsonString()
        select value is json ? value : text;
    return {tool: action.tool, result: parsed.length() == 1 ? parsed[0] : parsed};
}

# Writes a short resolved-case record to the knowledge base, for future investigations.
#
# + caseId - The case ID
# + version - The applied proposal version
# + action - The applied proposal
# + findings - The findings stored on the case, if the listener sent them
# + applyResult - The write tool's response
# + return - An error if ingestion fails
isolated function ingestResolvedCase(string caseId, int version, core:ProposedAction action,
        core:Findings? findings, json applyResult) returns error? {
    string content = string `Resolved case ${caseId} (proposal version ${version})
Summary: ${findings?.summary ?: "not provided"}
Root cause: ${findings?.rootCause ?: "not provided"}
Fix applied: ${action.tool}: ${action.rationale}
Outcome: ${applyResult.toJsonString()}
Sources: ${findings is core:Findings ? string:'join(", ", ...findings.knowledgeSources) : "not provided"}`;

    ai:TextDocument document = {
        content,
        metadata: {fileName: caseId + ".txt", "caseId": caseId, "kind": "resolved-case"}
    };
    check knowledgeBase.ingest(document);
}
