// Pure helpers for the support portal: case IDs, jobs, decisions and the JSON view of a case
// item. They live in this submodule so they can be unit tested without AWS clients.
//
// The item shapes and message formats match what the inquiry listener expects:
//   case item: caseId, status, job (JSON string), createdAt, updatedAt; the listener adds
//              findings, proposedAction, draftReply, proposalVersion, applyResult, failureReason
//   job message: {caseId, customerRef, inquiry, channel, context, submittedAt, requestedBy}
//   decision message: {caseId, decision: "APPROVED" | "REJECTED", proposalVersion, decidedBy}
// The listener sends `requestedBy` and `decidedBy` to the agent as the runtime user ID.

import ballerina/time;

# A sample inquiry from `data/sample-inquiries.json`.
public type Sample record {
    int id;
    string title;
    string customerRef;
    string channel;
    map<string> context;
    string inquiry;
};

# An investigation job, as the jobs queue carries it.
public type Job record {|
    string caseId;
    string customerRef;
    string inquiry;
    string channel;
    map<string> context;
    string submittedAt;
    # The representative who created the case
    string requestedBy;
|};

# A decision, as the decisions queue carries it.
public type DecisionMessage record {|
    string caseId;
    "APPROVED"|"REJECTED" decision;
    int proposalVersion;
    # The representative who decided
    string decidedBy;
|};

# Longest representative name the inquiry listener accepts.
public const int MAX_REPRESENTATIVE_LENGTH = 128;

// Attributes stored as JSON strings on the case item.
final readonly & string[] JSON_ATTRIBUTES = ["job", "findings", "proposedAction", "applyResult"];

# Builds a case ID such as `CASE-20261105-1a2b3c`.
#
# + now - The current time
# + suffix - A random suffix, at least six characters
# + return - The case ID
public isolated function caseId(time:Utc now, string suffix) returns string {
    time:Civil civil = time:utcToCivil(now);
    return string `CASE-${civil.year}${pad(civil.month)}${pad(civil.day)}-${suffix.substring(0, 6)}`;
}

isolated function pad(int value) returns string => value < 10 ? string `0${value}` : value.toString();

# Builds the job for a new case.
#
# + id - The case ID
# + customerRef - Guest reference
# + inquiry - The guest's message
# + channel - Where the inquiry came from
# + context - Identifiers on file
# + submittedAt - ISO 8601 time
# + requestedBy - The representative who created the case
# + return - The job
public isolated function job(string id, string customerRef, string inquiry, string channel,
        map<string> context, string submittedAt, string requestedBy) returns Job => {
    caseId: id,
    customerRef,
    inquiry,
    channel,
    context,
    submittedAt,
    requestedBy
};

# Maps the portal's `approve` / `reject` to the decision message.
#
# + caseId - The case ID
# + decision - `approve` or `reject`
# + proposalVersion - The proposal version shown to the representative
# + decidedBy - The representative who decided
# + return - The decision message
public isolated function decisionMessage(string caseId, "approve"|"reject" decision, int proposalVersion,
        string decidedBy) returns DecisionMessage => {
    caseId,
    decision: decision == "approve" ? "APPROVED" : "REJECTED",
    proposalVersion,
    decidedBy
};

# Picks the representative for a request: the name sent with it, otherwise the configured
# default. The portal has no sign-in, so the name is not verified.
#
# + given - The name sent with the request, if any
# + fallback - The configured default, `""` if none
# + return - The trimmed name, or an error if there is none or it is too long
public isolated function representative(string? given, string fallback) returns string|error {
    string name = given is string && given.trim() != "" ? given.trim() : fallback.trim();
    if name == "" {
        return error("Enter the representative's name, or set `representative` in Config.toml");
    }
    if name.length() > MAX_REPRESENTATIVE_LENGTH {
        return error(string `The representative's name is longer than ${MAX_REPRESENTATIVE_LENGTH} characters`);
    }
    return name;
}

# One DynamoDB attribute value, as far as the case item uses them.
public type Attribute record {
    string? S?;
    string? N?;
};

# Turns a case item into plain JSON. Numbers become integers, and the attributes stored as JSON
# strings are parsed.
#
# + item - The item's attributes
# + return - The case as JSON
public isolated function caseView(map<Attribute> item) returns map<json> {
    map<json> view = {};
    foreach [string, Attribute] [name, attribute] in item.entries() {
        string? text = attribute?.S;
        string? number = attribute?.N;
        if text is string {
            view[name] = text;
        } else if number is string {
            int|error parsed = int:fromString(number);
            view[name] = parsed is int ? parsed : number;
        }
    }
    foreach string name in JSON_ATTRIBUTES {
        json value = view[name];
        if value is string {
            json|error parsed = value.fromJsonString();
            if parsed is json {
                view[name] = parsed;
            }
        }
    }
    return view;
}

# A short summary of a case for the case list.
#
# + view - The case as JSON (from `caseView`)
# + return - caseId, status, inquiry, proposed tool and update time
public isolated function caseSummary(map<json> view) returns map<json> {
    json job = view["job"];
    json action = view["proposedAction"];
    return {
        caseId: view["caseId"],
        status: view["status"],
        inquiry: job is map<json> ? job["inquiry"] : (),
        customerRef: job is map<json> ? job["customerRef"] : (),
        proposedTool: action is map<json> ? action["tool"] : (),
        proposalVersion: view["proposalVersion"],
        updatedAt: view["updatedAt"]
    };
}
