// Turns the agent's final answer into checked findings.

import ballerina/ai;
import ballerina/log;

// Room for a whole investigation: the prompt, every tool call and result, and the final answer.
const int JOB_MEMORY_MESSAGES = 200;

// How much of a rejected answer goes into the log.
const int LOGGED_ANSWER_LENGTH = 4000;

# Creates the memory for one job's agent. It keeps the job's messages, so a correction turn sees
# the evidence the first turn gathered. It is discarded with the agent when the job ends.
#
# + return - The memory, or an error
public isolated function jobMemory() returns ai:Memory|ai:Error {
    ai:InMemoryShortTermMemoryStore store = check new (JOB_MEMORY_MESSAGES);
    return new ai:ShortTermMemory(store);
}

# Runs the agent and returns its findings. If the final answer does not match `Findings`, the
# answer is logged and the agent gets one more turn in the same session to correct it. The
# session still holds the tool results, so the correction does not gather the evidence again.
#
# + agent - An agent whose memory keeps the session's messages (see `jobMemory`)
# + query - The investigation prompt
# + sessionId - The session for this job
# + caseId - The case, for the logs
# + return - The findings, or an error if the corrected answer does not match either
public isolated function runForFindings(ai:Agent agent, string query, string sessionId, string caseId)
        returns Findings|error {
    FindingsAnswer answer = check agent.run(query, sessionId);
    Findings|error findings = answer.cloneWithType();
    if findings is Findings {
        return findings;
    }
    string reason = conversionReason(findings);
    string answerJson = answer.toJsonString();
    log:printWarn("The final answer does not match the findings schema; asking the model to correct it",
            caseId = caseId, reason = reason,
            answer = answerJson.length() <= LOGGED_ANSWER_LENGTH ? answerJson
                : answerJson.substring(0, LOGGED_ANSWER_LENGTH));
    FindingsAnswer corrected = check agent.run(correctionPrompt(reason), sessionId);
    return corrected.cloneWithType();
}

// A conversion error's message names only the error type; its detail says which field is wrong.
isolated function conversionReason(error err) returns string {
    var message = err.detail()["message"];
    return message is string ? message : err.message();
}

isolated function correctionPrompt(string reason) returns string => string `Your final answer does not match the required format:
${reason}

Call the final-answer tool again with a complete answer that includes every required field. Use
the evidence you already gathered. Call another tool only if a required fact is still missing.`;
