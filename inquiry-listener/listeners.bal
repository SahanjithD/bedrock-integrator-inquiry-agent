// WSO2 Integrator SQS listeners for the jobs and decisions queues.
//
// Concurrency: an `sqs:Listener` receives one message at a time and waits until the service
// has handled it. Each agent call can stay open for several minutes, so the jobs queue has five
// listeners and the decisions queue two. One task therefore runs at most five investigations and
// two decisions at once. To change the limit, add or remove a listener and its service.
//
// Each listener has its own service. `ballerinax/aws.sqs` keeps one message receiver per service,
// so a single service attached to several listeners would still receive one message at a time.
//
// Messages are never deleted automatically (`autoDelete: false`). A message is deleted only
// after its work is saved, or when there is nothing left to do (for example a duplicate). If
// processing fails, the message is made visible again after `retryDelaySeconds`, and SQS moves
// it to the queue's DLQ after 3 receives (maxReceiveCount).

import inquiry_listener.core;

import ballerina/log;
import ballerinax/aws.auth;
import ballerinax/aws.sqs;

final sqs:ConnectionConfig & readonly connection = {region: awsRegion, auth: auth:DEFAULT_CREDENTIALS};

// A received job stays hidden for longer than the longest agent call (15 minutes).
final sqs:ServiceConfigType & readonly jobService = {
    queueUrl: jobQueueUrl,
    autoDelete: false,
    config: {waitTime: 20, visibilityTimeout: jobVisibilitySeconds, pollInterval: 1}
};

final sqs:ServiceConfigType & readonly decisionService = {
    queueUrl: decisionQueueUrl,
    autoDelete: false,
    config: {waitTime: 20, visibilityTimeout: decisionVisibilitySeconds, pollInterval: 1}
};

listener sqs:Listener jobListener1 = new (connection);
listener sqs:Listener jobListener2 = new (connection);
listener sqs:Listener jobListener3 = new (connection);
listener sqs:Listener jobListener4 = new (connection);
listener sqs:Listener jobListener5 = new (connection);

listener sqs:Listener decisionListener1 = new (connection);
listener sqs:Listener decisionListener2 = new (connection);

@sqs:ServiceConfig {...jobService}
isolated service on jobListener1 {
    isolated remote function onMessage(sqs:Caller caller, sqs:Message message) returns error? {
        return onJob(caller, message);
    }

    isolated remote function onError(sqs:Error err) {
        log:printError("Jobs queue listener error", err);
    }
}

@sqs:ServiceConfig {...jobService}
isolated service on jobListener2 {
    isolated remote function onMessage(sqs:Caller caller, sqs:Message message) returns error? {
        return onJob(caller, message);
    }

    isolated remote function onError(sqs:Error err) {
        log:printError("Jobs queue listener error", err);
    }
}

@sqs:ServiceConfig {...jobService}
isolated service on jobListener3 {
    isolated remote function onMessage(sqs:Caller caller, sqs:Message message) returns error? {
        return onJob(caller, message);
    }

    isolated remote function onError(sqs:Error err) {
        log:printError("Jobs queue listener error", err);
    }
}

@sqs:ServiceConfig {...jobService}
isolated service on jobListener4 {
    isolated remote function onMessage(sqs:Caller caller, sqs:Message message) returns error? {
        return onJob(caller, message);
    }

    isolated remote function onError(sqs:Error err) {
        log:printError("Jobs queue listener error", err);
    }
}

@sqs:ServiceConfig {...jobService}
isolated service on jobListener5 {
    isolated remote function onMessage(sqs:Caller caller, sqs:Message message) returns error? {
        return onJob(caller, message);
    }

    isolated remote function onError(sqs:Error err) {
        log:printError("Jobs queue listener error", err);
    }
}

@sqs:ServiceConfig {...decisionService}
isolated service on decisionListener1 {
    isolated remote function onMessage(sqs:Caller caller, sqs:Message message) returns error? {
        return onDecision(caller, message);
    }

    isolated remote function onError(sqs:Error err) {
        log:printError("Decisions queue listener error", err);
    }
}

@sqs:ServiceConfig {...decisionService}
isolated service on decisionListener2 {
    isolated remote function onMessage(sqs:Caller caller, sqs:Message message) returns error? {
        return onDecision(caller, message);
    }

    isolated remote function onError(sqs:Error err) {
        log:printError("Decisions queue listener error", err);
    }
}

# Handles one job and deletes its message, or makes it visible again sooner to retry.
#
# + caller - The caller of the listener that received the message
# + message - The job message
# + return - An error if the message could not be deleted
isolated function onJob(sqs:Caller caller, sqs:Message message) returns error? {
    string messageId = message?.messageId ?: "";
    error? result = processJob(message, messageId);
    if result is error {
        log:printError("Job failed; it will be retried", result, messageId = messageId);
        retryLater(jobQueueUrl, message);
        return;
    }
    check caller->delete();
}

# Handles one decision and deletes its message, or makes it visible again sooner to retry.
#
# + caller - The caller of the listener that received the message
# + message - The decision message
# + return - An error if the message could not be deleted
isolated function onDecision(sqs:Caller caller, sqs:Message message) returns error? {
    error? result = processDecision(message, message?.messageId ?: "");
    if result is error {
        log:printError("Decision failed; it will be retried", result, messageId = message?.messageId);
        retryLater(decisionQueueUrl, message);
        return;
    }
    check caller->delete();
}

isolated function processJob(sqs:Message message, string messageId) returns error? {
    if messageId == "" {
        return error("The message has no ID");
    }
    json body = check (message?.body ?: "").fromJsonString();
    core:InvestigationJob job = check body.cloneWithType();
    string? problem = core:checkJob(job);
    if problem is string {
        return error(string `Invalid job: ${problem}`);
    }
    return handleJob(job, messageId);
}

isolated function processDecision(sqs:Message message, string messageId) returns error? {
    if messageId == "" {
        return error("The message has no ID");
    }
    json body = check (message?.body ?: "").fromJsonString();
    core:Decision decision = check body.cloneWithType();
    string? problem = core:checkDecision(decision);
    if problem is string {
        return error(string `Invalid decision: ${problem}`);
    }
    return handleDecision(decision, messageId);
}

# Makes a failed message visible again sooner than its full visibility timeout.
#
# + queueUrl - The queue the message came from
# + message - The message
isolated function retryLater(string queueUrl, sqs:Message message) {
    string? receiptHandle = message?.receiptHandle;
    if receiptHandle is () {
        return;
    }
    sqs:Error? changed = queues->changeMessageVisibility(queueUrl, receiptHandle, retryDelaySeconds);
    if changed is sqs:Error {
        log:printWarn("Could not shorten the message's visibility; it is retried after the full timeout", changed);
    }
}
