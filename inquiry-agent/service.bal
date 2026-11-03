// HTTP entry point for AgentCore Runtime (HTTP protocol, port 8080).
//
// POST /invocations does the work synchronously and returns the result in the response. The
// Lambda dispatcher waits for it. AgentCore Runtime ends a synchronous request after
// 15 minutes, so investigations stop at `investigationTimeoutSeconds` (10 minutes by default).
//
// Every handled request gets HTTP 200 with `status` set to "ok" or "error", so the dispatcher
// can always read the outcome.

import inquiry_agent.core;

import ballerina/http;
import ballerina/log;

listener http:Listener runtimeListener = new (8080);

service / on runtimeListener {

    resource function get ping() returns json => {status: "Healthy"};

    isolated resource function post invocations(@http:Payload core:InvocationRequest request) returns json {
        string? problem = core:checkRequest(request);
        if problem is string {
            log:printWarn("Invocation rejected", reason = problem, caseId = request.caseId);
            return errorResponse(request.caseId, core:INVALID_REQUEST, problem);
        }
        core:InvocationRequest & readonly checked = request.cloneReadOnly();
        json|error result = checked.action == "investigate" ? investigate(checked) : applyApproved(checked);
        if result is error {
            core:ErrorCode code = result is core:AgentError ? result.detail().code
                : checked.action == "investigate" ? core:INVESTIGATION_FAILED : core:APPLY_FAILED;
            log:printError("Action failed", result, caseId = checked.caseId, action = checked.action, code = code);
            return errorResponse(checked.caseId, code, result.message());
        }
        return result;
    }
}

isolated function errorResponse(string caseId, core:ErrorCode code, string message) returns json =>
    {status: "error", caseId, code, message};
