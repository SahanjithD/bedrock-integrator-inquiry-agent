// The support portal: a REST API over the case table and queues, and one static page at `/`.
// It runs on your machine (`bal run`) and stands in for a support system's agent console.

import support_portal.core;

import ballerina/http;
import ballerina/io;
import ballerina/log;

# Body of `POST /cases`: a free-text inquiry, or one of the three samples.
type CreateCaseRequest record {|
    # Sample inquiry number (1-3), from data/sample-inquiries.json
    int sample?;
    # The guest's message, instead of `sample`
    string inquiry?;
    # Guest reference for a free-text inquiry, e.g. `G-10427`
    string customerRef = "G-UNSPECIFIED";
    # Where the inquiry came from
    string channel = "email";
    # Identifiers on file, e.g. {"reservationId": "R-48213"}
    map<string> context = {};
    # The representative creating the case, instead of the configured default
    string representative?;
|};

# Body of `POST /cases/{caseId}/decision`.
type DecisionRequest record {|
    "approve"|"reject" decision;
    # The representative deciding, instead of the configured default
    string representative?;
|};

type ErrorBody record {|
    string message;
|};

listener http:Listener portalListener = new (port);

service / on portalListener {

    # The portal page.
    resource function get .() returns http:Response|http:InternalServerError {
        string|io:Error page = io:fileReadString(pageFile);
        if page is io:Error {
            log:printError("Could not read the portal page", page);
            return <http:InternalServerError>{body: {message: "The portal page is missing"}};
        }
        http:Response response = new;
        response.setTextPayload(page, "text/html; charset=utf-8");
        return response;
    }

    # Creates a case and sends its investigation job.
    resource function post cases(@http:Payload CreateCaseRequest request)
            returns http:Created|http:BadRequest|http:InternalServerError {
        string|error requestedBy = core:representative(request?.representative, representative);
        if requestedBy is error {
            return <http:BadRequest>{body: <ErrorBody>{message: requestedBy.message()}};
        }
        string customerRef = request.customerRef;
        string channel = request.channel;
        map<string> context = request.context;
        string inquiry;

        int? sampleId = request?.sample;
        string? text = request?.inquiry;
        if sampleId is int {
            core:Sample|error sample = findSample(sampleId);
            if sample is error {
                return <http:BadRequest>{body: <ErrorBody>{message: sample.message()}};
            }
            inquiry = sample.inquiry;
            customerRef = sample.customerRef;
            channel = sample.channel;
            context = sample.context;
        } else if text is string && text.trim() != "" {
            inquiry = text.trim();
        } else {
            return <http:BadRequest>{body: <ErrorBody>{message: "Send {\"inquiry\": \"...\"} or {\"sample\": 1|2|3}"}};
        }

        string|error caseId = createCase(customerRef, inquiry, channel, context, requestedBy);
        if caseId is error {
            log:printError("Could not create the case", caseId);
            return <http:InternalServerError>{body: <ErrorBody>{message: caseId.message()}};
        }
        log:printInfo("Case created", caseId = caseId, requestedBy = requestedBy);
        return <http:Created>{
            headers: {"Location": string `/cases/${caseId}`},
            body: {caseId, status: "QUEUED", inquiry}
        };
    }

    # Lists cases with their status, most recently updated first.
    resource function get cases() returns json|http:InternalServerError {
        map<json>[]|error cases = listCases();
        if cases is error {
            log:printError("Could not list cases", cases);
            return <http:InternalServerError>{body: <ErrorBody>{message: cases.message()}};
        }
        return cases;
    }

    # Shows one case: status, findings, proposed fix, draft reply and, once applied, the result.
    resource function get cases/[string caseId]() returns json|http:NotFound|http:InternalServerError {
        map<json>?|error found = getCase(caseId);
        if found is error {
            log:printError("Could not read the case", found, caseId = caseId);
            return <http:InternalServerError>{body: <ErrorBody>{message: found.message()}};
        }
        if found is () {
            return <http:NotFound>{body: <ErrorBody>{message: string `Case ${caseId} not found`}};
        }
        return found;
    }

    # Approves or rejects the case's current proposal. Only cases awaiting approval accept a
    # decision; the message carries the proposal version shown to the representative.
    resource function post cases/[string caseId]/decision(@http:Payload DecisionRequest request)
            returns http:Accepted|http:BadRequest|http:NotFound|http:Conflict|http:InternalServerError {
        string|error decidedBy = core:representative(request?.representative, representative);
        if decidedBy is error {
            return <http:BadRequest>{body: <ErrorBody>{message: decidedBy.message()}};
        }
        map<json>?|error found = getCase(caseId);
        if found is error {
            return <http:InternalServerError>{body: <ErrorBody>{message: found.message()}};
        }
        if found is () {
            return <http:NotFound>{body: <ErrorBody>{message: string `Case ${caseId} not found`}};
        }
        json status = found["status"];
        json storedVersion = found["proposalVersion"];
        if status != "PENDING_APPROVAL" || storedVersion !is int {
            return <http:Conflict>{
                body: <ErrorBody>{message: string `Case ${caseId} is ${status.toString()}, not PENDING_APPROVAL`}
            };
        }
        int version = <int>storedVersion;

        core:DecisionMessage|error sent = sendDecision(caseId, version, request.decision, decidedBy);
        if sent is error {
            log:printError("Could not send the decision", sent, caseId = caseId);
            return <http:InternalServerError>{body: <ErrorBody>{message: sent.message()}};
        }
        log:printInfo("Decision sent", caseId = caseId, decision = sent.decision, proposalVersion = version,
                decidedBy = decidedBy);
        return <http:Accepted>{body: sent.toJson()};
    }

    # Lists the messages in the two dead-letter queues, without removing them.
    resource function get failures() returns json|http:InternalServerError {
        json[]|error jobs = peekDeadLetters(jobDeadLetterQueueUrl);
        json[]|error decisions = peekDeadLetters(decisionDeadLetterQueueUrl);
        if jobs is error {
            return <http:InternalServerError>{body: <ErrorBody>{message: jobs.message()}};
        }
        if decisions is error {
            return <http:InternalServerError>{body: <ErrorBody>{message: decisions.message()}};
        }
        return {jobs, decisions};
    }
}

isolated function findSample(int id) returns core:Sample|error {
    foreach core:Sample sample in check loadSamples() {
        if sample.id == id {
            return sample;
        }
    }
    return error(string `No sample ${id}. Choose 1, 2 or 3.`);
}
