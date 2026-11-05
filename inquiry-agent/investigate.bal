// The investigate action: gather evidence with read-only tools, consult the knowledge base,
// and return findings, a proposed fix and a draft reply. It changes nothing.

import inquiry_agent.core;

import ballerina/ai;
import ballerina/lang.runtime;
import ballerina/log;

# Searches runbooks, policies and resolved past cases in the knowledge base.
#
# + query - What to look for, in plain words, e.g. "points missing after checkout"
# + return - The most relevant passages, best match first
@ai:AgentTool
isolated function searchKnowledge(string query) returns string|error {
    ai:QueryMatch[] matches = check knowledgeBase.retrieve(query, knowledgeResults);
    if matches.length() == 0 {
        return "No matching runbooks, policies or past cases.";
    }
    string[] passages = from ai:QueryMatch m in matches
        select string `[score ${m.similarityScore}] ${(m.chunk.metadata ?: {}).toJsonString()}
${m.chunk.content.toString()}`;
    return string:'join("\n---\n", ...passages);
}

// Both futures below return a value, not an error, so `wait a | b` returns whichever finishes
// first. The wait can still yield an error if a strand panics.
type InvestigationOutcome record {|
    core:Findings? findings = ();
    error? failure = ();
|};

type TimedOut record {|
    true timedOut = true;
|};

# Runs one investigation within `investigationTimeoutSeconds`.
#
# + request - The invocation, already checked by `core:checkRequest`
# + workloadAccessToken - The `WorkloadAccessToken` header, if present
# + return - The response body, or an error
isolated function investigate(core:InvocationRequest & readonly request, string? workloadAccessToken)
        returns json|error {
    core:InvestigationJob & readonly job = check request?.job.ensureType();
    string workload = check workloadToken(workloadAccessToken);

    future<InvestigationOutcome> work = start runInvestigation(job, workload);
    future<TimedOut> timer = start timeoutAfter(investigationTimeoutSeconds);
    InvestigationOutcome|TimedOut|error outcome = wait work | timer;
    if outcome is error {
        return outcome;
    }
    if outcome is TimedOut {
        // The investigation strand stops on its own at maxIterations or an HTTP timeout; its
        // result is discarded. The listener retries the job.
        return error core:AgentError(
            string `The investigation did not finish within ${investigationTimeoutSeconds} seconds`,
            code = core:INVESTIGATION_TIMEOUT);
    }
    error? failure = outcome.failure;
    if failure is error {
        return failure;
    }
    core:Findings findings = check outcome.findings.ensureType();
    log:printInfo("Investigation finished", caseId = request.caseId,
            proposed = findings?.proposedAction?.tool ?: "none", confidence = findings.confidence);
    return {status: "ok", caseId: request.caseId, findings: findings.toJson()};
}

isolated function runInvestigation(core:InvestigationJob & readonly job, string workload)
        returns InvestigationOutcome {
    core:Findings|error findings = investigateJob(job, workload);
    return findings is error ? {failure: findings} : {findings};
}

isolated function timeoutAfter(decimal seconds) returns TimedOut {
    runtime:sleep(seconds);
    return {};
}

isolated function investigateJob(core:InvestigationJob job, string workload) returns core:Findings|error {
    // A fresh connection per job, limited to the read-only tools. The token comes from the
    // investigator credential provider, whose Cognito client is granted only the read scope.
    string token = check gatewayToken(workload, investigatorCredentialProvider, readScopes);
    ai:McpToolKit gatewayTools = check new (gatewayUrl, core:READ_TOOLS,
        {name: "inquiry-agent-investigate", version: "0.1.0"},
        auth = {token}
    );

    // `memory = ()` keeps the agent stateless: each run sees only this job and its tool results.
    ai:Agent agent = check new (
        systemPrompt = INVESTIGATOR_PROMPT,
        model = model,
        tools = [gatewayTools, searchKnowledge],
        maxIter = maxIterations,
        memory = ()
    );

    core:Findings findings = check agent.run(investigationPrompt(job));
    check core:validateProposal(findings);
    return findings;
}
