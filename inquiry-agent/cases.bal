// Case item access for the apply action. Each status change is a conditional update, so two
// invocations for the same case can never both apply a change.
//
// Item attributes (all set by the console or the state machines unless noted):
//   caseId (S, key), status (S), proposalVersion (N), findings (S, JSON), proposedAction (S, JSON),
//   draftReply (S), applyResult (S, JSON, set here), failureReason (S), updatedAt (S)

import inquiry_agent.core;

import ballerina/time;
import ballerinax/aws;
import ballerinax/aws.dynamodb;

const string CONDITION_FAILED = "ConditionalCheckFailedException";

# The parts of a case the apply action reads.
type StoredCase record {|
    string caseId;
    string status;
    int proposalVersion;
    core:Findings findings;
    core:ProposedAction? proposedAction;
|};

# Moves a case from PENDING_APPROVAL to APPLYING if the approved version is still current.
#
# + caseId - The case ID
# + proposalVersion - The version the representative approved
# + return - `true` if this call claimed the case, `false` if the condition did not hold
isolated function claimForApply(string caseId, int proposalVersion) returns boolean|error {
    return conditionalStatusUpdate(caseId,
        "SET #status = :applying, updatedAt = :now",
        "#status = :pending AND proposalVersion = :version",
        {
            ":applying": {S: core:APPLYING},
            ":pending": {S: core:PENDING_APPROVAL},
            ":version": {N: proposalVersion.toString()}
        });
}

# Moves a case from APPLYING to APPLIED and stores the write tool's response.
#
# + caseId - The case ID
# + applyResult - The write tool's response
# + return - `true` if the case was still APPLYING, otherwise `false`
isolated function markApplied(string caseId, json applyResult) returns boolean|error {
    return conditionalStatusUpdate(caseId,
        "SET #status = :applied, applyResult = :result, updatedAt = :now",
        "#status = :applying",
        {
            ":applied": {S: core:APPLIED},
            ":applying": {S: core:APPLYING},
            ":result": {S: applyResult.toJsonString()}
        });
}

# Moves a case from APPLYING to NEEDS_REVIEW, because the outcome of a write is unknown.
#
# + caseId - The case ID
# + reason - Why a person has to check the case
# + return - `true` if the case was still APPLYING, otherwise `false`
isolated function markNeedsReview(string caseId, string reason) returns boolean|error {
    return conditionalStatusUpdate(caseId,
        "SET #status = :review, failureReason = :reason, updatedAt = :now",
        "#status = :applying",
        {
            ":review": {S: core:NEEDS_REVIEW},
            ":applying": {S: core:APPLYING},
            ":reason": {S: reason}
        });
}

isolated function conditionalStatusUpdate(string caseId, string updateExpression,
        string conditionExpression, map<dynamodb:AttributeValue> values) returns boolean|error {
    map<dynamodb:AttributeValue> expressionValues = {...values, ":now": {S: time:utcToString(time:utcNow())}};
    dynamodb:ItemDescription|dynamodb:Error result = caseStore->updateItem({
        TableName: caseTable,
        Key: {caseId: {S: caseId}},
        UpdateExpression: updateExpression,
        ConditionExpression: conditionExpression,
        ExpressionAttributeNames: {"#status": "status"},
        ExpressionAttributeValues: expressionValues
    });
    if result is dynamodb:Error {
        // TODO(verify): the connector reports DynamoDB's `__type` as `errorCode`.
        aws:ErrorDetails details = result.detail();
        if details?.errorCode == CONDITION_FAILED {
            return false;
        }
        return result;
    }
    return true;
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
    core:ProposedAction? proposedAction = ();
    string? actionJson = item["proposedAction"]?.S;
    if actionJson is string && actionJson != "null" {
        proposedAction = check (check actionJson.fromJsonString()).cloneWithType();
    }
    return {
        caseId,
        status: item["status"]?.S ?: "",
        proposalVersion: check int:fromString(item["proposalVersion"]?.N ?: "0"),
        findings: check (check (item["findings"]?.S ?: "{}").fromJsonString()).cloneWithType(),
        proposedAction
    };
}
