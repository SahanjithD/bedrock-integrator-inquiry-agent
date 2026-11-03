// Message checks, runtime session IDs and the InvokeAgentRuntime request path.

import ballerina/url;

# AgentCore requires runtime session IDs of at least this many characters.
public const int MIN_SESSION_ID_LENGTH = 33;

# Checks an investigation job before any work starts.
#
# + job - The job from the jobs queue
# + return - A reason the job cannot be processed, or `()` if it is acceptable
public isolated function checkJob(InvestigationJob job) returns string? {
    if job.caseId.trim() == "" {
        return "caseId is required";
    }
    if job.customerRef.trim() == "" {
        return "customerRef is required";
    }
    if job.inquiry.trim() == "" {
        return "inquiry is empty";
    }
    return ();
}

# Checks a decision before any work starts.
#
# + decision - The decision from the decisions queue
# + return - A reason the decision cannot be processed, or `()` if it is acceptable
public isolated function checkDecision(Decision decision) returns string? {
    if decision.caseId.trim() == "" {
        return "caseId is required";
    }
    if decision.proposalVersion < 1 {
        return "proposalVersion must be 1 or higher";
    }
    return ();
}

# Builds a runtime session ID of the form `<caseId>-<suffix>`, padded to the minimum length.
#
# + caseId - The case ID
# + suffix - The attempt or version, e.g. `1` or `apply-v1`
# + return - The session ID
public isolated function sessionId(string caseId, string suffix) returns string {
    string value = string `${caseId}-${suffix}`;
    if value.length() >= MIN_SESSION_ID_LENGTH {
        return value;
    }
    string padding = "";
    foreach int _ in 0 ..< (MIN_SESSION_ID_LENGTH - value.length() - 1) {
        padding += "0";
    }
    return string `${value}-${padding}`;
}

# The request path for InvokeAgentRuntime. The runtime ARN is one path segment, so its `:` and
# `/` are percent-encoded, as the AWS SDKs do: `/runtimes/arn%3Aaws%3A...%2F<id>/invocations`.
#
# + agentRuntimeArn - The agent runtime ARN
# + return - The encoded request path
public isolated function invocationPath(string agentRuntimeArn) returns string|error {
    string encoded = check url:encode(agentRuntimeArn, "UTF-8");
    return string `/runtimes/${encoded}/invocations`;
}
