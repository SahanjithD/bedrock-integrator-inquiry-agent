// Two WSO2 Integrator SQS listeners: one for investigation jobs, one for decisions.
//
// Messages are never deleted automatically (`autoDelete: false`). A message is deleted only
// after its work is saved, or when there is nothing left to do (for example a duplicate).
// If processing fails, the message is made visible again after `retryDelaySeconds`, and SQS
// moves it to the queue's DLQ after 3 receives (maxReceiveCount).
//
// Each listener receives one message at a time and waits for it to finish, so one ECS task
// runs at most one investigation and one decision at a time. Scale with the service's
// desired count.

import inquiry_agent.core;

import ballerina/log;
import ballerinax/aws.auth;
import ballerinax/aws.sqs;

listener sqs:Listener jobListener = new ({region: awsRegion, auth: auth:DEFAULT_CREDENTIALS});
listener sqs:Listener decisionListener = new ({region: awsRegion, auth: auth:DEFAULT_CREDENTIALS});

@sqs:ServiceConfig {
    queueUrl: jobQueueUrl,
    autoDelete: false,
    // The received job stays hidden for longer than the longest expected investigation.
    config: {waitTime: 20, visibilityTimeout: jobVisibilitySeconds, pollInterval: 1}
}
service on jobListener {

    remote function onMessage(sqs:Caller caller, sqs:Message message) returns error? {
        string messageId = message?.messageId ?: "";
        error? result = processJob(message, messageId);
        if result is error {
            log:printError("Job failed; it will be retried", result, messageId = messageId);
            retryLater(jobQueueUrl, message);
            return;
        }
        check caller->delete();
    }

    remote function onError(sqs:Error err) {
        log:printError("Jobs queue listener error", err);
    }
}

@sqs:ServiceConfig {
    queueUrl: decisionQueueUrl,
    autoDelete: false,
    config: {waitTime: 20, visibilityTimeout: decisionVisibilitySeconds, pollInterval: 1}
}
service on decisionListener {

    remote function onMessage(sqs:Caller caller, sqs:Message message) returns error? {
        error? result = processDecision(message);
        if result is error {
            log:printError("Decision failed; it will be retried", result, messageId = message?.messageId);
            retryLater(decisionQueueUrl, message);
            return;
        }
        check caller->delete();
    }

    remote function onError(sqs:Error err) {
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

isolated function processDecision(sqs:Message message) returns error? {
    json body = check (message?.body ?: "").fromJsonString();
    core:Decision decision = check body.cloneWithType();
    string? problem = core:checkDecision(decision);
    if problem is string {
        return error(string `Invalid decision: ${problem}`);
    }
    return handleDecision(decision);
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
