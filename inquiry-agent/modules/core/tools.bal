// Which gateway tools each action may use, and the checks a proposal must pass.

// AgentCore Gateway exposes each target's tools as `<targetName><separator><toolName>`.
// TODO(verify): confirm the separator against the gateway's tools/list response.
public const string GATEWAY_TOOL_SEPARATOR = "___";

# Builds the name a gateway target exposes for one of its tools.
#
# + target - The gateway target name, e.g. `loyalty`
# + tool - The tool name on the MCP server, e.g. `listStays`
# + return - The tool name as the gateway lists it
public isolated function gatewayToolName(string target, string tool) returns string =>
    target + GATEWAY_TOOL_SEPARATOR + tool;

# Read-only tools. The investigate action loads only these.
public final readonly & string[] READ_TOOLS = [
    gatewayToolName("reservation", "findReservations"),
    gatewayToolName("reservation", "getReservation"),
    gatewayToolName("reservation", "getReservationHistory"),
    gatewayToolName("reservation", "getConfirmation"),
    gatewayToolName("loyalty", "getMember"),
    gatewayToolName("loyalty", "listStays"),
    gatewayToolName("loyalty", "listPointsActivity"),
    gatewayToolName("payment", "listCharges"),
    gatewayToolName("payment", "getCharge"),
    gatewayToolName("payment", "getFolio")
];

# A write tool and the arguments a proposal must supply for it.
public type WriteToolSpec record {|
    # Gateway tool name
    string tool;
    # What the tool changes
    string description;
    # Argument names the proposal must include (`approvalId` is added at apply time)
    string[] requiredArguments;
|};

# Write tools. Only the apply action calls them, and only with a stored, approved proposal.
public final readonly & WriteToolSpec[] WRITE_TOOL_SPECS = [
    {
        tool: gatewayToolName("reservation", "reissueConfirmation"),
        description: "Issues a new confirmation that matches the current reservation version.",
        requiredArguments: ["reservationId"]
    },
    {
        tool: gatewayToolName("loyalty", "creditPoints"),
        description: "Credits points for a completed stay whose accrual is missing.",
        requiredArguments: ["memberId", "stayId", "points"]
    },
    {
        tool: gatewayToolName("payment", "refundCharge"),
        description: "Refunds all or part of a captured card charge.",
        requiredArguments: ["chargeId", "amount"]
    }
];

# Names of all write tools.
public final readonly & string[] WRITE_TOOLS = from WriteToolSpec spec in WRITE_TOOL_SPECS
    select spec.tool;

# The approval ID passed to a write tool. Write tools use it as an idempotency key.
#
# + caseId - The case ID
# + proposalVersion - The approved proposal version
# + return - The approval ID, e.g. `CASE-20261103-1a2b3c#1`
public isolated function approvalIdFor(string caseId, int proposalVersion) returns string =>
    string `${caseId}#${proposalVersion}`;

# Checks the shape of an invocation before any work starts.
#
# + request - The request body
# + return - A reason the request is rejected, or `()` if it is acceptable
public isolated function checkRequest(InvocationRequest request) returns string? {
    if request.taskToken.trim() == "" {
        return "taskToken is required";
    }
    if request.caseId.trim() == "" {
        return "caseId is required";
    }
    if request.action == "investigate" {
        InvestigationJob? job = request?.job;
        if job is () {
            return "job is required for the investigate action";
        }
        if job.caseId != request.caseId {
            return "job.caseId does not match caseId";
        }
        if job.inquiry.trim() == "" {
            return "job.inquiry is empty";
        }
        return ();
    }
    int? version = request?.proposalVersion;
    if version is () || version < 1 {
        return "proposalVersion (1 or higher) is required for the apply action";
    }
    return ();
}

# Checks the agent's proposal before it is stored for approval.
#
# A proposal must name a known write tool, supply its required arguments as scalar values,
# leave `approvalId` to the apply step, and refer only to IDs that appear in the evidence.
#
# + findings - The agent's findings
# + return - An `AgentError` with `INVALID_PROPOSAL` if a check fails
public isolated function validateProposal(Findings findings) returns AgentError? {
    ProposedAction? action = findings?.proposedAction;
    if action is () {
        return ();
    }
    WriteToolSpec[] matching = from WriteToolSpec spec in WRITE_TOOL_SPECS
        where spec.tool == action.tool
        select spec;
    if matching.length() != 1 {
        return invalid(string `'${action.tool}' is not an allowed write tool`);
    }
    if action.arguments.hasKey("approvalId") {
        return invalid("approvalId is added at apply time and must not be proposed");
    }
    foreach string name in matching[0].requiredArguments {
        json value = action.arguments[name];
        if value is () {
            return invalid(string `missing argument '${name}'`);
        }
    }
    string evidenceText = string:'join("\n", ...from Evidence item in findings.evidence
        select item.detail);
    foreach [string, json] [name, value] in action.arguments.entries() {
        if value is map<json>|json[] {
            return invalid(string `argument '${name}' must be a single value`);
        }
        if name.endsWith("Id") {
            string id = value.toString();
            if id == "" || !evidenceText.includes(id) {
                return invalid(string `argument '${name}' (${id}) does not appear in the evidence`);
            }
        }
    }
    return ();
}

isolated function invalid(string reason) returns AgentError =>
    error AgentError(string `Invalid proposal: ${reason}`, code = INVALID_PROPOSAL);
