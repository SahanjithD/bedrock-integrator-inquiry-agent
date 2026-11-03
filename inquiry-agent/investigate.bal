// The investigate action: gather evidence with read-only tools, consult the knowledge base,
// and return findings, a proposed fix and a draft reply. It changes nothing.

import inquiry_agent.core;

import ballerina/ai;
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

# Runs one investigation and reports the result to Step Functions.
#
# + request - The invocation, already checked by `core:checkRequest`
# + return - An error if the investigation fails; the caller reports it
isolated function investigate(core:InvocationRequest & readonly request) returns error? {
    core:InvestigationJob job = check request?.job.ensureType();

    // A fresh connection per job, limited to the read-only tools. The token comes from the
    // investigator app client, which is granted only the read scope.
    ai:McpToolKit gatewayTools = check new (gatewayUrl, core:READ_TOOLS,
        {name: "inquiry-agent-investigate", version: "0.1.0"},
        auth = {
            tokenUrl,
            clientId: investigatorClientId,
            clientSecret: gatewaySecrets.investigatorClientSecret,
            scopes: readScopes
        }
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

    log:printInfo("Investigation finished", caseId = request.caseId,
            proposed = findings?.proposedAction?.tool ?: "none", confidence = findings.confidence);
    check sendTaskSuccess(request.taskToken, {caseId: request.caseId, findings: findings.toJson()});
}
