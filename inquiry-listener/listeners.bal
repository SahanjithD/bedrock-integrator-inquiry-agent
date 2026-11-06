// WSO2 Integrator SQS listeners for the jobs and decisions queues.
//
// Concurrency: an `sqs:Listener` receives one message at a time and waits until the service
// has handled it. Each agent call can stay open for several minutes, so the jobs service is
// attached to five listeners and the decisions service to two. One task therefore runs at most
// five investigations and two decisions at once. To change the limit, add or remove listener
// declarations.
// TODO(verify): that `ballerinax/aws.sqs` polls independently for one service attached to
// several listeners (each listener creates its own receiver when the service is attached).
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

listener sqs:Listener jobListener1 = new (connection);
listener sqs:Listener jobListener2 = new (connection);
listener sqs:Listener jobListener3 = new (connection);
listener sqs:Listener jobListener4 = new (connection);
listener sqs:Listener jobListener5 = new (connection);

listener sqs:Listener decisionListener1 = new (connection);
listener sqs:Listener decisionListener2 = new (connection);

@sqs:ServiceConfig {
    queueUrl: jobQueueUrl,
    autoDelete: false,
    // A received job stays hidden for longer than the longest agent call (15 minutes).
    config: {waitTime: 20, visibilityTimeout: jobVisibilitySeconds, pollInterval: 1}
}
isolated service on jobListener1, jobListener2, jobListener3, jobListener4, jobListener5 {

    isolated remote function onMessage(sqs:Caller caller, sqs:Message message) returns error? {
        string messageId = message?.messageId ?: "";
        error? result = processJob(message, messageId);
        if result is error {
            log:printError("Job failed; it will be retried", result, messageId = messageId);
            retryLater(jobQueueUrl, message);
            return;
        }
        check caller->delete();
    }

    isolated remote function onError(sqs:Error err) {
        log:printError("Jobs queue listener error", err);
    }
}

@sqs:ServiceConfig {
    queueUrl: decisionQueueUrl,
    autoDelete: false,
    config: {waitTime: 20, visibilityTimeout: decisionVisibilitySeconds, pollInterval: 1}
}
isolated service on decisionListener1, decisionListener2 {

    isolated remote function onMessage(sqs:Caller caller, sqs:Message message) returns error? {
        error? result = processDecision(message, message?.messageId ?: "");
        if result is error {
            log:printError("Decision failed; it will be retried", result, messageId = message?.messageId);
            retryLater(decisionQueueUrl, message);
            return;
        }
        check caller->delete();
    }

    isolated remote function onError(sqs:Error err) {
        log:printError("Decisions queue listener error", err);
    }
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
