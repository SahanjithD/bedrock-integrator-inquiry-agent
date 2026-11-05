// Types and pure helpers shared by the two SQS services. They live in this submodule so they
// can be unit tested without AWS clients.

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
    # The representative who submitted the job. Sent to AgentCore Runtime as the runtime user ID
    string requestedBy;
|};

# A representative's decision, as the console puts it on the decisions queue. It carries no
# action: the listener always reads the proposal stored on the case.
public type Decision record {|
    # The case the decision is for
    string caseId;
    # Approve or reject the stored proposal
    "APPROVED"|"REJECTED" decision;
    # The proposal version the representative reviewed
    int proposalVersion;
    # The representative who decided. Sent to AgentCore Runtime as the runtime user ID, and
    # recorded on the case
    string decidedBy;
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

# The agent answered with `status: "error"`.
public type AgentError distinct error<record {| string code; |}>;
