// Types shared by the two SQS services and the case store.
// They live in this submodule so they can be unit tested without AWS clients.

# An investigation job, as the support console puts it on the jobs queue.
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

# A representative's decision, as the console puts it on the decisions queue. It carries no
# action: the apply step always reads the proposal stored on the case.
public type Decision record {|
    # The case the decision is for
    string caseId;
    # Approve or reject the stored proposal
    "APPROVED"|"REJECTED" decision;
    # The proposal version the representative reviewed
    int proposalVersion;
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
    # Arguments for the tool, without `approvalId` (the apply step adds it)
    map<json> arguments;
    # Why this change fixes the problem
    string rationale;
|};

# What an investigation produces.
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
    QUEUED,
    INVESTIGATING,
    PENDING_APPROVAL,
    NO_ACTION_PROPOSED,
    APPLYING,
    APPLIED,
    REJECTED,
    NEEDS_REVIEW,
    FAILED
}
