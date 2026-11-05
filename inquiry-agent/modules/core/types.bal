// Types shared by the HTTP entry point and the two actions.
// They live in this submodule so they can be unit tested without AWS clients.

import ballerina/ai;

# What the runtime is asked to do. The inquiry listener picks the action.
public type Action "investigate"|"apply";

# An investigation job, as the support portal puts it on the jobs queue.
public type InvestigationJob record {|
    # Case ID created by the support portal, e.g. `CASE-20261103-1a2b3c`
    string caseId;
    # Reference to the guest record the representative has open, e.g. `G-10427`
    string customerRef;
    # The guest's message, as received
    string inquiry;
    # Where the inquiry came from, e.g. `email` or `chat`
    string channel = "email";
    # Optional identifiers the representative already has in front of them
    map<string> context = {};
    # When the portal submitted the job (ISO 8601)
    string submittedAt?;
    # The representative who submitted the job (the runtime user ID)
    string requestedBy?;
|};

# One fact the agent relied on.
public type Evidence record {|
    # Where the fact came from: a tool name or a knowledge base source
    string 'source;
    # The fact itself, including the IDs it refers to
    string detail;
|};

# The single change the agent proposes. It is applied only after approval.
public type ProposedAction record {|
    # Gateway tool name of a write tool, e.g. `loyalty___creditPoints`
    string tool;
    # Arguments for the tool, without `approvalId` (the apply action adds it)
    map<json> arguments;
    # Why this change fixes the problem
    string rationale;
|};

# What the investigate action returns. `ai:Agent.run` gives the model this type's JSON schema as
# the parameters of its final-answer tool. The schema is written out because `ballerina/ai` does
# not generate one for this record (it has an open `arguments` map and a defaulted field).
@ai:JsonSchema {
    "type": "object",
    "additionalProperties": false,
    "required": ["summary", "evidence", "rootCause", "draftReply", "confidence"],
    "properties": {
        "summary": {"type": "string", "description": "Two or three sentences on what happened"},
        "evidence": {
            "type": "array",
            "description": "Facts gathered from tools and the knowledge base",
            "items": {
                "type": "object",
                "additionalProperties": false,
                "required": ["source", "detail"],
                "properties": {
                    "source": {"type": "string", "description": "A tool name or a knowledge base source"},
                    "detail": {"type": "string", "description": "The fact itself, including the IDs it refers to"}
                }
            }
        },
        "rootCause": {"type": "string", "description": "The most likely cause"},
        "proposedAction": {
            "type": "object",
            "description": "The proposed fix. Leave out when no change is needed or the cause is unclear",
            "additionalProperties": false,
            "required": ["tool", "arguments", "rationale"],
            "properties": {
                "tool": {"type": "string", "description": "Gateway tool name of a write tool, e.g. loyalty___creditPoints"},
                "arguments": {"type": "object", "description": "Arguments for the tool, without approvalId"},
                "rationale": {"type": "string", "description": "Why this change fixes the problem"}
            }
        },
        "draftReply": {"type": "string", "description": "A reply the representative can send after the fix is applied"},
        "confidence": {"type": "string", "enum": ["high", "medium", "low"]},
        "knowledgeSources": {
            "type": "array",
            "description": "Runbooks, policies or past cases used",
            "items": {"type": "string"}
        }
    }
}
public type Findings record {|
    # Two or three sentences on what happened
    string summary;
    # Facts gathered from tools and the knowledge base
    Evidence[] evidence;
    # The most likely cause
    string rootCause;
    # The proposed fix. Left out when no change is needed or the cause is unclear
    ProposedAction proposedAction?;
    # A reply the representative can send after the fix is applied
    string draftReply;
    # How sure the agent is
    "high"|"medium"|"low" confidence;
    # Runbooks, policies or past cases used
    string[] knowledgeSources = [];
|};

# The body of `POST /invocations`, sent by the inquiry listener.
public type InvocationRequest record {|
    # Which action to run
    Action action;
    # The case this invocation belongs to
    string caseId;
    # The job to investigate. Required for `investigate`
    InvestigationJob job?;
    # The approved proposal version. Required for `apply`
    int proposalVersion?;
    # The approved proposal, as stored on the case. Required for `apply`
    ProposedAction proposedAction?;
    # The findings stored on the case, used for the resolved-case record. Optional for `apply`
    Findings findings?;
|};

# Error codes returned in an `error` response.
public enum ErrorCode {
    # The request is malformed
    INVALID_REQUEST = "InvalidRequest",
    # The agent's proposal does not pass the checks in `validateProposal`
    INVALID_PROPOSAL = "InvalidProposal",
    # The investigation did not finish within its time budget
    INVESTIGATION_TIMEOUT = "InvestigationTimeout",
    # Anything else went wrong during the investigation
    INVESTIGATION_FAILED = "InvestigationFailed",
    # The write tool was not called (for example, the proposal names a tool that is not allowed)
    APPLY_REJECTED = "ApplyRejected",
    # The write tool was called and failed, or its outcome is unknown
    APPLY_FAILED = "ApplyFailed"
}

# An error that carries the code returned to the listener.
public type AgentError distinct error<record {| ErrorCode code; |}>;
