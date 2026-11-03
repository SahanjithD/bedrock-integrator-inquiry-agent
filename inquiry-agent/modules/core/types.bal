// Types shared by the HTTP entry point, the investigate action and the apply action.
// They live in this submodule so they can be unit tested without AWS clients.

# What the runtime is asked to do. Step Functions picks the action.
public type Action "investigate"|"apply";

# An investigation job, as the support console puts it on the job queue.
public type InvestigationJob record {|
    # Case ID created by the support console, e.g. `CASE-20261103-1a2b3c`
    string caseId;
    # Reference to the guest record the representative has open, e.g. `G-10427`
    string customerRef;
    # The guest's message, as received
    string inquiry;
    # Where the inquiry came from, e.g. `email` or `chat`
    string channel = "email";
    # Optional identifiers the representative already has in front of them
    map<string> context = {};
    # When the console submitted the job (ISO 8601)
    string submittedAt?;
|};

# The body of `POST /invocations`. The Lambda dispatcher forwards it unchanged.
public type InvocationRequest record {|
    # Which action to run
    Action action;
    # Step Functions task token used to report the result
    string taskToken;
    # The case this invocation belongs to
    string caseId;
    # The job to investigate. Required for `investigate`
    InvestigationJob job?;
    # The proposal version the representative approved. Required for `apply`
    int proposalVersion?;
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

# What the investigate action returns to Step Functions.
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

# Case statuses. The DynamoDB item stands in for a ticket in the team's support system.
public enum CaseStatus {
    RECEIVED,
    INVESTIGATING,
    PENDING_APPROVAL,
    NO_ACTION_PROPOSED,
    APPLYING,
    APPLIED,
    REJECTED,
    NEEDS_REVIEW,
    FAILED
}

# Error codes reported to Step Functions with `SendTaskFailure`.
public enum FailureCode {
    # The proposal does not pass the checks in `validateProposal`
    INVALID_PROPOSAL = "InvalidProposal",
    # The case is not waiting for approval, or the approved version is stale
    CASE_NOT_PENDING = "CaseNotPending",
    # The outcome of a write is unknown; a person has to check it
    CASE_NEEDS_REVIEW = "CaseNeedsReview",
    # Anything else went wrong during the investigation
    INVESTIGATION_FAILED = "InvestigationFailed",
    # Anything else went wrong while applying
    APPLY_FAILED = "ApplyFailed"
}

# An error that carries the code reported to Step Functions.
public type AgentError distinct error<record {| FailureCode code; |}>;
