// Decisions: reject, or apply the one change a representative approved and record the resolved
// case in the knowledge base. The decision message carries only caseId, decision and
// proposalVersion; the change itself is always read from the stored case.
//
// Approve, step by step:
//   1. Claim the case: PENDING_APPROVAL -> APPLYING, only if the approved version is current.
//   2. If the claim fails because the case is already APPLYING, an earlier attempt may have
//      made the change. Do not call the tool again: mark NEEDS_REVIEW.
//   3. Call the stored write tool through the gateway with approvalId = caseId#version.
//   4. APPLYING -> APPLIED, storing the tool's response.
//   5. Ingest a resolved-case summary into the knowledge base's custom data source.

import inquiry_agent.core;

import ballerina/ai;
import ballerina/log;
import ballerina/mcp;

# Handles one decision from the decisions queue.
#
# + decision - The decision
# + return - `()` when the message can be deleted, or an error to retry it later
isolated function handleDecision(core:Decision decision) returns error? {
    string caseId = decision.caseId;
    int version = decision.proposalVersion;

    if decision.decision == "REJECTED" {
        boolean rejected = check markRejected(caseId, version);
        if rejected {
            log:printInfo("Proposal rejected", caseId = caseId, proposalVersion = version);
        } else {
            log:printWarn("Rejection ignored: case is not waiting for this version", caseId = caseId);
        }
        return;
    }

    boolean claimed = check claimForApply(caseId, version);
    if !claimed {
        StoredCase current = check loadCase(caseId);
        if current.status == core:APPLYING {
            // A redelivered decision: the earlier attempt's outcome is unknown.
            _ = check markNeedsReview(caseId,
                "The decision was received again while the case was APPLYING; the earlier attempt's outcome is unknown.");
            log:printWarn("Case marked NEEDS_REVIEW; the write tool was not called again", caseId = caseId);
        } else {
            log:printWarn("Approval ignored: case is not waiting for this version", caseId = caseId,
                    status = current.status, storedVersion = current.proposalVersion, approvedVersion = version);
        }
        return;
    }

    // From here on the case is APPLYING. A failed write leaves the outcome unknown, so the
    // case goes to NEEDS_REVIEW and the message is not retried.
    json|error applyResult = callApprovedTool(caseId, version);
    if applyResult is error {
        _ = check markNeedsReview(caseId, applyResult.message());
        log:printError("Applying the approved change failed; case marked NEEDS_REVIEW", applyResult, caseId = caseId);
        return;
    }

    // If this update fails, the message is retried, finds the case APPLYING, and marks it
    // NEEDS_REVIEW without calling the tool again.
    boolean applied = check markApplied(caseId, applyResult);
    if !applied {
        log:printWarn("Case left APPLYING before it could be marked APPLIED", caseId = caseId);
        return;
    }
    log:printInfo("Approved change applied", caseId = caseId, proposalVersion = version);

    error? ingested = ingestResolvedCase(caseId, version, applyResult);
    if ingested is error {
        // The change is applied; a missing knowledge base entry does not undo it.
        log:printWarn("Resolved case not added to the knowledge base", ingested, caseId = caseId);
    }
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
            clientSecret: applierClientSecret,
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
# + applyResult - The write tool's response
# + return - An error if ingestion fails
isolated function ingestResolvedCase(string caseId, int version, json applyResult) returns error? {
    StoredCase stored = check loadCase(caseId);
    core:Findings? findings = stored.findings;
    if findings is () {
        return error("The case has no stored findings");
    }
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
