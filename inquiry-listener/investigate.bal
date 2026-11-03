// Jobs: claim the case, have the agent investigate, save the result.

import inquiry_listener.core;

import ballerina/log;

# Handles one job from the jobs queue.
#
# + job - The investigation job
# + messageId - The SQS message ID, used to hold the claim on the case
# + return - `()` when the message can be deleted, or an error to retry it later
isolated function handleJob(core:InvestigationJob job, string messageId) returns error? {
    InvestigationClaim claim = check claimForInvestigation(job.caseId, messageId);
    if !claim.claimed {
        // Another job message already handled this case, or the case moved on.
        log:printInfo("Job skipped: case is not waiting for this job", caseId = job.caseId);
        return;
    }

    map<json>|error answer = invokeAgent(
        {action: "investigate", caseId: job.caseId, job: job.toJson()},
        core:sessionId(job.caseId, claim.attempts.toString()));
    if answer is error {
        if claim.attempts >= maxAttempts {
            // Last attempt: the message goes to the DLQ after this receive.
            check markInvestigationFailed(job.caseId, answer.message());
        }
        return answer;
    }
    map<json> findings = check answer["findings"].ensureType();

    // Delete the message only after the findings are saved.
    boolean saved = check saveFindings(job.caseId, messageId, findings);
    if !saved {
        log:printWarn("Findings not saved: the claim moved to another attempt", caseId = job.caseId);
        return;
    }
    log:printInfo("Investigation saved", caseId = job.caseId, attempt = claim.attempts);
}
