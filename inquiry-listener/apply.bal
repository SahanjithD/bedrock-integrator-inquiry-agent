// Decisions: reject, or have the agent apply the approved proposal stored on the case.
//
// Approve, step by step:
//   1. Claim the case: PENDING_APPROVAL -> APPLYING, only if the approved version is current.
//      The claim records the decision's message ID.
//   2. If the claim fails because the case is already APPLYING:
//      - under this message's claim: this is a redelivery, and the earlier attempt may have
//        made the change. Do not call the agent again: mark NEEDS_REVIEW.
//      - under another message's claim: a second approval of the same proposal (for example
//        from a second representative). The first one is still applying it, so do nothing.
//   3. Load the proposal from the case (never from the message) and call the agent with it.
//   4. APPLYING -> APPLIED, storing the agent's answer. Only the message that holds the claim
//      can make this change or mark the case NEEDS_REVIEW.

import inquiry_listener.core;

import ballerina/log;

# Handles one decision from the decisions queue.
#
# + decision - The decision
# + messageId - The SQS message ID, used to hold the apply claim on the case
# + return - `()` when the message can be deleted, or an error to retry it later
isolated function handleDecision(core:Decision decision, string messageId) returns error? {
    string caseId = decision.caseId;
    int version = decision.proposalVersion;
    string decidedBy = decision.decidedBy;

    if decision.decision == "REJECTED" {
        boolean rejected = check markRejected(caseId, version, decidedBy);
        if rejected {
            log:printInfo("Proposal rejected", caseId = caseId, proposalVersion = version);
        } else {
            log:printWarn("Rejection ignored: case is not waiting for this version", caseId = caseId);
        }
        return;
    }

    boolean claimed = check claimForApply(caseId, version, decidedBy, messageId);
    if !claimed {
        StoredCase current = check loadCase(caseId);
        if current.status == core:APPLYING && current.applyMessageId == messageId {
            // A redelivered decision: the earlier attempt's outcome is unknown.
            _ = check markNeedsReview(caseId, messageId,
                "The decision was received again while the case was APPLYING; the earlier attempt's outcome is unknown.");
            log:printWarn("Case marked NEEDS_REVIEW; the agent was not called again", caseId = caseId);
        } else if current.status == core:APPLYING {
            log:printInfo("Approval ignored: another approval of this proposal is being applied", caseId = caseId,
                    approvedVersion = version);
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
        _ = check markNeedsReview(caseId, messageId, "The case has no stored proposal.");
        return;
    }
    map<json> payload = {action: "apply", caseId, proposalVersion: version, proposedAction: proposal};
    map<json>? findings = stored.findings;
    if findings is map<json> {
        payload["findings"] = findings;
    }

    map<json>|error answer = invokeAgent(payload, core:sessionId(caseId, string `apply-v${version}`), decidedBy);
    if answer is error {
        _ = check markNeedsReview(caseId, messageId, answer.message());
        log:printError("Applying the approved change failed; case marked NEEDS_REVIEW", answer, caseId = caseId);
        return;
    }

    // If this update fails, the message is retried, finds the case APPLYING under its own
    // claim, and marks it NEEDS_REVIEW without calling the agent again.
    boolean applied = check markApplied(caseId, messageId, answer);
    if !applied {
        // A redelivery of this message marked the case NEEDS_REVIEW while the agent was still
        // working. Keep the write tool's response on the case for the reviewer.
        boolean recorded = check recordLateApplyResult(caseId, messageId, answer);
        log:printWarn("Case left APPLYING before it could be marked APPLIED", caseId = caseId,
                applyResultStored = recorded);
        return;
    }
    log:printInfo("Approved change applied", caseId = caseId, proposalVersion = version);
}
