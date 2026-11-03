// Decisions: reject, or have the agent apply the approved proposal stored on the case.
//
// Approve, step by step:
//   1. Claim the case: PENDING_APPROVAL -> APPLYING, only if the approved version is current.
//   2. If the claim fails because the case is already APPLYING, an earlier attempt may have
//      made the change. Do not call the agent again: mark NEEDS_REVIEW.
//   3. Load the proposal from the case (never from the message) and call the agent with it.
//   4. APPLYING -> APPLIED, storing the agent's answer.

import inquiry_listener.core;

import ballerina/log;

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
            log:printWarn("Case marked NEEDS_REVIEW; the agent was not called again", caseId = caseId);
        } else {
            log:printWarn("Approval ignored: case is not waiting for this version", caseId = caseId,
                    status = current.status, storedVersion = current.proposalVersion, approvedVersion = version);
        }
        return;
    }

    // From here on the case is APPLYING. A failed call leaves the outcome unknown, so the case
    // goes to NEEDS_REVIEW and the message is not retried.
    StoredCase stored = check loadCase(caseId);
    map<json>? proposal = stored.proposedAction;
    if proposal is () {
        _ = check markNeedsReview(caseId, "The case has no stored proposal.");
        return;
    }
    map<json> payload = {action: "apply", caseId, proposalVersion: version, proposedAction: proposal};
    map<json>? findings = stored.findings;
    if findings is map<json> {
        payload["findings"] = findings;
    }

    map<json>|error answer = invokeAgent(payload, core:sessionId(caseId, string `apply-v${version}`));
    if answer is error {
        _ = check markNeedsReview(caseId, answer.message());
        log:printError("Applying the approved change failed; case marked NEEDS_REVIEW", answer, caseId = caseId);
        return;
    }

    // If this update fails, the message is retried, finds the case APPLYING, and marks it
    // NEEDS_REVIEW without calling the agent again.
    boolean applied = check markApplied(caseId, answer);
    if !applied {
        log:printWarn("Case left APPLYING before it could be marked APPLIED", caseId = caseId);
        return;
    }
    log:printInfo("Approved change applied", caseId = caseId, proposalVersion = version);
}
