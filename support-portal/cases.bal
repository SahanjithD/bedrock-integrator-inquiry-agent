// Reads and writes for the case table and the queues. Same item shapes and messages as the
// inquiry listener expects (see modules/core).

import support_portal.core;

import ballerina/io;
import ballerina/time;
import ballerina/uuid;
import ballerinax/aws.dynamodb;
import ballerinax/aws.sqs;

# Creates a case in QUEUED status and sends its investigation job to the jobs queue.
#
# + customerRef - Guest reference
# + inquiry - The guest's message
# + channel - Where the inquiry came from
# + context - Identifiers on file
# + return - The new case ID, or an error
isolated function createCase(string customerRef, string inquiry, string channel, map<string> context)
        returns string|error {
    time:Utc now = time:utcNow();
    string id = core:caseId(now, uuid:createType4AsString());
    string submittedAt = time:utcToString(now);
    core:Job job = core:job(id, customerRef, inquiry, channel, context, submittedAt);

    _ = check caseStore->createItem({
        TableName: caseTable,
        Item: {
            caseId: {S: id},
            status: {S: "QUEUED"},
            job: {S: job.toJsonString()},
            createdAt: {S: submittedAt},
            updatedAt: {S: submittedAt}
        },
        ConditionExpression: "attribute_not_exists(caseId)"
    });
    _ = check queues->sendMessage(jobQueueUrl, job.toJsonString());
    return id;
}

# Reads one case with a strongly consistent read.
#
# + caseId - The case ID
# + return - The case as JSON, `()` if it does not exist, or an error
isolated function getCase(string caseId) returns map<json>?|error {
    dynamodb:ItemGetOutput output = check caseStore->getItem({
        TableName: caseTable,
        Key: {caseId: {S: caseId}},
        ConsistentRead: true
    });
    map<dynamodb:AttributeValue>? item = output?.Item;
    return item is () ? () : core:caseView(attributes(item));
}

# Lists all cases, most recently updated first. A scan is fine for a sample-sized table.
#
# + return - Case summaries, or an error
isolated function listCases() returns map<json>[]|error {
    stream<dynamodb:ScanOutput, dynamodb:Error?> items = check caseStore->scan({TableName: caseTable});
    map<json>[] summaries = [];
    check from dynamodb:ScanOutput entry in items
        do {
            map<dynamodb:AttributeValue>? item = entry?.Item;
            if item is map<dynamodb:AttributeValue> {
                summaries.push(core:caseSummary(core:caseView(attributes(item))));
            }
        };
    return from map<json> summary in summaries
        order by summary["updatedAt"].toString() descending
        select summary;
}

# Sends a decision for the proposal version stored on the case.
#
# + caseId - The case ID
# + proposalVersion - The proposal version the representative reviewed
# + decision - `approve` or `reject`
# + return - The message sent, or an error
isolated function sendDecision(string caseId, int proposalVersion, "approve"|"reject" decision)
        returns core:DecisionMessage|error {
    core:DecisionMessage message = core:decisionMessage(caseId, decision, proposalVersion);
    _ = check queues->sendMessage(decisionQueueUrl, message.toJsonString());
    return message;
}

# Peeks at the messages in one dead-letter queue without removing them.
#
# + queueUrl - The DLQ URL
# + return - Up to 10 messages, or an error
isolated function peekDeadLetters(string queueUrl) returns json[]|error {
    // VisibilityTimeout 0 leaves the messages on the queue for the next look.
    sqs:Message[] messages = check queues->receiveMessage(queueUrl,
        maxNumberOfMessages = 10, visibilityTimeout = 0, waitTimeSeconds = 1);
    return from sqs:Message message in messages
        let string body = message?.body ?: ""
        let json|error parsed = body.fromJsonString()
        select {
            messageId: message?.messageId,
            caseId: parsed is map<json> ? parsed["caseId"] : (),
            body: parsed is json ? parsed : body
        };
}

# Reads the sample inquiries.
#
# + return - The samples, or an error
isolated function loadSamples() returns core:Sample[]|error {
    json content = check io:fileReadJson(samplesFile);
    return content.cloneWithType();
}

isolated function attributes(map<dynamodb:AttributeValue> item) returns map<core:Attribute> {
    map<core:Attribute> result = {};
    foreach [string, dynamodb:AttributeValue] [name, value] in item.entries() {
        result[name] = {S: value?.S, N: value?.N};
    }
    return result;
}
