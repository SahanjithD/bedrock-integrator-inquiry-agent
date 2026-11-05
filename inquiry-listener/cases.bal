// Case item access. Every status change is a conditional update, so two tasks working on the
// same case (for example after a redelivery) can never both investigate or both apply it.
//
// Item attributes:
//   caseId (S, key), status (S), job (S, JSON)                         - written by the console
//   jobMessageId (S), attempts (N)                                      - investigation claim
//   findings (S, JSON), proposedAction (S, JSON or "null"),
//   draftReply (S), proposalVersion (N)                                 - investigation result
//   decidedBy (S)                                                       - decision
//   applyResult (S, JSON), failureReason (S), createdAt (S), updatedAt (S)

import inquiry_listener.core;

import ballerina/time;
import ballerinax/aws;
import ballerinax/aws.dynamodb;

const string CONDITION_FAILED = "ConditionalCheckFailedException";

# The parts of a case the apply step reads. Findings and the proposal are passed to the agent
# as stored.
type StoredCase record {|
    string caseId;
    string status;
    int proposalVersion;
    map<json>? findings;
    map<json>? proposedAction;
|};

# The result of an investigation claim.
type InvestigationClaim record {|
    # Whether this job message may investigate the case
    boolean claimed;
    # Investigation attempts so far, including this one
    int attempts = 0;
|};

// ---------------------------------------------------------------------------
// Investigation
// ---------------------------------------------------------------------------

# Claims a case for investigation: QUEUED -> INVESTIGATING. A redelivery of the same job
# message may claim it again (the earlier attempt stopped part way), but a second job
# message for the same case may not.
#
# + caseId - The case ID
# + messageId - The SQS message ID of the job
# + return - The claim, or an error
isolated function claimForInvestigation(string caseId, string messageId) returns InvestigationClaim|error {
    map<dynamodb:AttributeValue>? updated = check conditionalUpdate(caseId,
        "SET #status = :investigating, jobMessageId = :messageId, updatedAt = :now ADD attempts :one",
        "#status = :queued OR (#status = :investigating AND jobMessageId = :messageId)",
        {
            ":investigating": {S: core:INVESTIGATING},
            ":queued": {S: core:QUEUED},
            ":messageId": {S: messageId},
            ":one": {N: "1"}
        },
        returnNewValues = true);
    if updated is () {
        return {claimed: false};
    }
    return {claimed: true, attempts: check int:fromString(updated["attempts"]?.N ?: "1")};
}

# Saves the findings and opens a new proposal version: INVESTIGATING -> PENDING_APPROVAL
# (or NO_ACTION_PROPOSED when the agent proposes no change).
#
# + caseId - The case ID
# + messageId - The SQS message ID that holds the claim
# + findings - The findings returned by the agent (already checked by the agent)
# + return - `true` if saved, `false` if this message no longer holds the claim
isolated function saveFindings(string caseId, string messageId, map<json> findings) returns boolean|error {
    json action = findings["proposedAction"];
    json reply = findings["draftReply"];
    map<dynamodb:AttributeValue>? updated = check conditionalUpdate(caseId,
        "SET #status = :next, findings = :findings, proposedAction = :action, draftReply = :reply, " +
            "updatedAt = :now ADD proposalVersion :one",
        "#status = :investigating AND jobMessageId = :messageId",
        {
            ":next": {S: action is () ? core:NO_ACTION_PROPOSED : core:PENDING_APPROVAL},
            ":findings": {S: findings.toJsonString()},
            ":action": {S: action is () ? "null" : action.toJsonString()},
            ":reply": {S: reply is string ? reply : ""},
            ":investigating": {S: core:INVESTIGATING},
            ":messageId": {S: messageId},
            ":one": {N: "1"}
        });
    return updated !is ();
}

# Marks a case FAILED after its last investigation attempt.
#
# + caseId - The case ID
# + reason - What went wrong
# + return - An error if the update fails for a reason other than the condition
isolated function markInvestigationFailed(string caseId, string reason) returns error? {
    _ = check conditionalUpdate(caseId,
        "SET #status = :failed, failureReason = :reason, updatedAt = :now",
        "#status IN (:queued, :investigating)",
        {
            ":failed": {S: core:FAILED},
            ":reason": {S: truncate(reason, 1000)},
            ":queued": {S: core:QUEUED},
            ":investigating": {S: core:INVESTIGATING}
        });
}

// ---------------------------------------------------------------------------
// Decisions
// ---------------------------------------------------------------------------

# Rejects the proposal: PENDING_APPROVAL -> REJECTED, if the version is still current.
#
# + caseId - The case ID
# + proposalVersion - The version the representative reviewed
# + decidedBy - The representative who rejected it
# + return - `true` if the case was rejected, `false` if the condition did not hold
isolated function markRejected(string caseId, int proposalVersion, string decidedBy) returns boolean|error {
    return check conditionalUpdate(caseId,
        "SET #status = :rejected, decidedBy = :decidedBy, updatedAt = :now",
        "#status = :pending AND proposalVersion = :version",
        {
            ":rejected": {S: core:REJECTED},
            ":pending": {S: core:PENDING_APPROVAL},
            ":version": {N: proposalVersion.toString()},
            ":decidedBy": {S: decidedBy}
        }) !is ();
}

# Claims a case for applying: PENDING_APPROVAL -> APPLYING, if the version is still current.
#
# + caseId - The case ID
# + proposalVersion - The version the representative approved
# + decidedBy - The representative who approved it
# + return - `true` if this call claimed the case, `false` if the condition did not hold
isolated function claimForApply(string caseId, int proposalVersion, string decidedBy) returns boolean|error {
    return check conditionalUpdate(caseId,
        "SET #status = :applying, decidedBy = :decidedBy, updatedAt = :now",
        "#status = :pending AND proposalVersion = :version",
        {
            ":applying": {S: core:APPLYING},
            ":pending": {S: core:PENDING_APPROVAL},
            ":version": {N: proposalVersion.toString()},
            ":decidedBy": {S: decidedBy}
        }) !is ();
}

# APPLYING -> APPLIED, storing the write tool's response.
#
# + caseId - The case ID
# + applyResult - The write tool's response
# + return - `true` if the case was still APPLYING, otherwise `false`
isolated function markApplied(string caseId, json applyResult) returns boolean|error {
    return check conditionalUpdate(caseId,
        "SET #status = :applied, applyResult = :result, updatedAt = :now",
        "#status = :applying",
        {
            ":applied": {S: core:APPLIED},
            ":applying": {S: core:APPLYING},
            ":result": {S: applyResult.toJsonString()}
        }) !is ();
}

# APPLYING -> NEEDS_REVIEW, because the outcome of a write is unknown.
#
# + caseId - The case ID
# + reason - Why a person has to check the case
# + return - `true` if the case was still APPLYING, otherwise `false`
isolated function markNeedsReview(string caseId, string reason) returns boolean|error {
    return check conditionalUpdate(caseId,
        "SET #status = :review, failureReason = :reason, updatedAt = :now",
        "#status = :applying",
        {
            ":review": {S: core:NEEDS_REVIEW},
            ":applying": {S: core:APPLYING},
            ":reason": {S: truncate(reason, 1000)}
        }) !is ();
}

// ---------------------------------------------------------------------------
// Shared
// ---------------------------------------------------------------------------

# Runs one conditional update.
#
# + return - The item's new attributes (or an empty map) if the update ran, `()` if the
# condition did not hold, or an error
isolated function conditionalUpdate(string caseId, string updateExpression, string conditionExpression,
        map<dynamodb:AttributeValue> values, boolean returnNewValues = false)
        returns map<dynamodb:AttributeValue>?|error {
    map<dynamodb:AttributeValue> expressionValues = {...values};
    expressionValues[":now"] = {S: time:utcToString(time:utcNow())};
    dynamodb:ItemUpdateInput input = {
        TableName: caseTable,
        Key: {caseId: {S: caseId}},
        UpdateExpression: updateExpression,
        ConditionExpression: conditionExpression,
        ExpressionAttributeNames: {"#status": "status"},
        ExpressionAttributeValues: expressionValues
    };
    if returnNewValues {
        input.ReturnValues = dynamodb:ALL_NEW;
    }
    dynamodb:ItemDescription|dynamodb:Error result = caseStore->updateItem(input);
    if result is dynamodb:Error {
        // TODO(verify): the connector reports DynamoDB's `__type` as `errorCode`.
        aws:ErrorDetails details = result.detail();
        if details?.errorCode == CONDITION_FAILED {
            return ();
        }
        return result;
    }
    return result?.Attributes ?: {};
}

# Reads a case with a strongly consistent read.
#
# + caseId - The case ID
# + return - The stored case, or an error if it is missing or malformed
isolated function loadCase(string caseId) returns StoredCase|error {
    dynamodb:ItemGetOutput output = check caseStore->getItem({
        TableName: caseTable,
        Key: {caseId: {S: caseId}},
        ConsistentRead: true
    });
    map<dynamodb:AttributeValue>? item = output?.Item;
    if item is () {
        return error(string `Case ${caseId} not found`);
    }
    map<json>? proposedAction = ();
    string? actionJson = item["proposedAction"]?.S;
    if actionJson is string && actionJson != "null" {
        proposedAction = check (check actionJson.fromJsonString()).ensureType();
    }
    map<json>? findings = ();
    string? findingsJson = item["findings"]?.S;
    if findingsJson is string {
        findings = check (check findingsJson.fromJsonString()).ensureType();
    }
    return {
        caseId,
        status: item["status"]?.S ?: "",
        proposalVersion: check int:fromString(item["proposalVersion"]?.N ?: "0"),
        findings,
        proposedAction
    };
}

isolated function truncate(string value, int maxLength) returns string =>
    value.length() <= maxLength ? value : value.substring(0, maxLength);
