// HTTP entry point for AgentCore Runtime (HTTP protocol, port 8080).
//
// POST /invocations answers "accepted" at once and runs the action in the background.
// GET /ping reports HealthyBusy while background work runs, so the runtime keeps the
// session alive. The result goes back to Step Functions with the task token.

import inquiry_agent.core;

import ballerina/http;
import ballerina/log;

listener http:Listener runtimeListener = new (8080);

service / on runtimeListener {

    isolated resource function get ping() returns core:PingResponse => core:currentStatus();

    isolated resource function post invocations(@http:Payload core:InvocationRequest request)
            returns json|http:BadRequest {
        string? problem = core:checkRequest(request);
        if problem is string {
            log:printWarn("Invocation rejected", reason = problem, caseId = request.caseId);
            return <http:BadRequest>{body: {status: "rejected", reason: problem}};
        }
        core:InvocationRequest & readonly accepted = request.cloneReadOnly();
        core:jobStarted();
        _ = start runInBackground(accepted);
        return {status: "accepted", caseId: request.caseId, action: request.action};
    }
}

# Runs one action, reports any failure to Step Functions, and clears the busy status.
#
# + request - The accepted invocation
isolated function runInBackground(core:InvocationRequest & readonly request) {
    error? result = request.action == "investigate" ? investigate(request) : applyApproved(request);
    if result is error {
        string code = failureCode(request.action, result);
        log:printError("Action failed", result, caseId = request.caseId, action = request.action, code = code);
        error? reported = sendTaskFailure(request.taskToken, code, result.message());
        if reported is error {
            // Step Functions falls back to the task timeout and its retry policy.
            log:printError("Could not report the failure to Step Functions", reported, caseId = request.caseId);
        }
    }
    core:jobFinished();
}

isolated function failureCode(core:Action action, error err) returns string {
    if err is core:AgentError {
        return err.detail().code;
    }
    return action == "investigate" ? core:INVESTIGATION_FAILED : core:APPLY_FAILED;
}
