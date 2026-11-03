// The apply action: run the one change a representative approved, then record the resolved
// case in the knowledge base. The decision message carries only caseId, decision and
// proposalVersion; the change itself is always read from the stored case.
//
// Order of steps:
//   1. Claim the case: PENDING_APPROVAL -> APPLYING, only if the approved version is current.
//   2. If the claim fails because the case is already APPLYING, an earlier attempt may have
//      made the change. Do not call the tool again: mark NEEDS_REVIEW and fail the task.
//   3. Call the stored write tool through the gateway with approvalId = caseId#version.
//   4. APPLYING -> APPLIED, storing the tool's response.
//   5. Ingest a resolved-case summary into the knowledge base's custom data source.

import inquiry_agent.core;

import ballerina/ai;
import ballerina/log;
import ballerina/mcp;

# Applies an approved proposal and reports the result to Step Functions.
#
# + request - The invocation, already checked by `core:checkRequest`
# + return - An error if the change cannot be applied; the caller reports it
isolated function applyApproved(core:InvocationRequest & readonly request) returns error? {
    string caseId = request.caseId;
    int version = check request?.proposalVersion.ensureType();

    boolean claimed = check claimForApply(caseId, version);
    if !claimed {
        StoredCase current = check loadCase(caseId);
        if current.status == core:APPLYING {
            _ = check markNeedsReview(caseId,
                "A retry found the case already APPLYING; the earlier attempt's outcome is unknown.");
            return error core:AgentError(
                string `Case ${caseId} was already being applied; marked NEEDS_REVIEW`,
                code = core:CASE_NEEDS_REVIEW);
        }
        return error core:AgentError(
            string `Case ${caseId} is ${current.status} at version ${current.proposalVersion}, ` +
            string `not PENDING_APPROVAL at version ${version}`,
            code = core:CASE_NOT_PENDING);
    }

    // From here on the case is APPLYING. Any failure leaves the outcome unknown, so the case
    // goes to NEEDS_REVIEW instead of being retried.
    json|error applyResult = callApprovedTool(caseId, version);
    if applyResult is error {
        _ = check markNeedsReview(caseId, applyResult.message());
        return error core:AgentError(
            string `Applying case ${caseId} failed: ${applyResult.message()}`, applyResult,
            code = core:CASE_NEEDS_REVIEW);
    }

    boolean applied = check markApplied(caseId, applyResult);
    if !applied {
        return error core:AgentError(
            string `Case ${caseId} left APPLYING before it could be marked APPLIED`,
            code = core:CASE_NEEDS_REVIEW);
    }

    boolean ingested = true;
    error? ingestResult = ingestResolvedCase(caseId, version, applyResult);
    if ingestResult is error {
        // The change is applied; a missing knowledge base entry does not undo it.
        ingested = false;
        log:printWarn("Resolved case not added to the knowledge base", ingestResult, caseId = caseId);
    }

    log:printInfo("Approved change applied", caseId = caseId, proposalVersion = version);
    check sendTaskSuccess(request.taskToken, {
        caseId,
        status: core:APPLIED,
        applyResult,
        knowledgeBaseUpdated: ingested
    });
}

# Calls the stored write tool. Only tools on the write list are allowed.
#
# + caseId - The case ID
# + version - The approved proposal version
# + return - The tool's response, or an error
isolated function callApprovedTool(string caseId, int version) returns json|error {
    StoredCase stored = check loadCase(caseId);
    if stored.proposalVersion != version {
        return error(string `Stored proposal is version ${stored.proposalVersion}, approved was ${version}`);
    }
    core:ProposedAction? action = stored.proposedAction;
    if action is () {
        return error("The case has no stored proposal");
    }
    if core:WRITE_TOOLS.indexOf(action.tool) is () {
        return error(string `'${action.tool}' is not an allowed write tool`);
    }

    // The applier app client is granted only the write scope.
    mcp:StreamableHttpClient gateway = check new (gatewayUrl,
        auth = {
            tokenUrl,
            clientId: applierClientId,
            clientSecret: gatewaySecrets.applierClientSecret,
            scopes: writeScopes
        },
        timeout = 60
    );
    check gateway->initialize({name: "inquiry-agent-apply", version: "0.1.0"});

    record {} arguments = {...action.arguments, approvalId: core:approvalIdFor(caseId, version)};
    mcp:CallToolResult result = check gateway->callTool({name: action.tool, arguments});
    error? closed = gateway->close();
    if closed is error {
        log:printDebug("Closing the gateway connection failed", closed);
    }

    string[] texts = from mcp:ContentBlock block in result.content
        where block is mcp:TextContent
        select block.text;
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
# + applyResult - The write tool's response
# + return - An error if ingestion fails
isolated function ingestResolvedCase(string caseId, int version, json applyResult) returns error? {
    StoredCase stored = check loadCase(caseId);
    core:Findings findings = stored.findings;
    core:ProposedAction? action = stored.proposedAction;
    string actionLine = action is core:ProposedAction ? string `${action.tool}: ${action.rationale}` : "none";
    string content = string `Resolved case ${caseId} (proposal version ${version})
Summary: ${findings.summary}
Root cause: ${findings.rootCause}
Fix applied: ${actionLine}
Outcome: ${applyResult.toJsonString()}
Sources: ${string:'join(", ", ...findings.knowledgeSources)}`;

    ai:TextDocument document = {
        content,
        metadata: {fileName: caseId + ".txt", "caseId": caseId, "kind": "resolved-case"}
    };
    check knowledgeBase.ingest(document);
}
