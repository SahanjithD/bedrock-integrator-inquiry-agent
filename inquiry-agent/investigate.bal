// Investigation: gather evidence with read-only tools, consult the knowledge base, and save
// findings, a proposed fix and a draft reply on the case. It changes nothing else.

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

    core:Findings|error findings = investigate(job);
    if findings is error {
        if claim.attempts >= maxAttempts {
            // Last attempt: the message goes to the DLQ after this receive.
            check markInvestigationFailed(job.caseId, findings.message());
        }
        return findings;
    }

    // Delete the message only after the findings are saved.
    boolean saved = check saveFindings(job.caseId, messageId, findings);
    if !saved {
        log:printWarn("Findings not saved: the claim moved to another attempt", caseId = job.caseId);
        return;
    }
    log:printInfo("Investigation saved", caseId = job.caseId,
            proposed = findings?.proposedAction?.tool ?: "none", confidence = findings.confidence);
}

# Runs the investigation agent for one job.
#
# + job - The investigation job
# + return - Checked findings, or an error
isolated function investigate(core:InvestigationJob job) returns core:Findings|error {
    // A fresh connection per job, limited to the read-only tools. The token comes from the
    // investigator app client, which is granted only the read scope.
    ai:McpToolKit gatewayTools = check new (gatewayUrl, core:READ_TOOLS,
        {name: "inquiry-agent-investigate", version: "0.1.0"},
        auth = {
            tokenUrl,
            clientId: investigatorClientId,
            clientSecret: investigatorClientSecret,
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
    return findings;
}
