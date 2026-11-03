import ballerina/test;

@test:Config
function checksJob() {
    InvestigationJob empty = {caseId: "CASE-1", customerRef: "G-10427", inquiry: "  "};
    test:assertTrue(checkJob(empty) is string);

    InvestigationJob ok = {caseId: "CASE-1", customerRef: "G-10427", inquiry: "My confirmation shows old dates."};
    test:assertEquals(checkJob(ok), ());
}

@test:Config
function checksDecision() {
    Decision noVersion = {caseId: "CASE-1", decision: "APPROVED", proposalVersion: 0};
    test:assertTrue(checkDecision(noVersion) is string);

    Decision ok = {caseId: "CASE-1", decision: "REJECTED", proposalVersion: 1};
    test:assertEquals(checkDecision(ok), ());
}

@test:Config
function padsShortSessionIds() {
    string id = sessionId("CASE-1", "1");
    test:assertTrue(id.startsWith("CASE-1-1"));
    test:assertEquals(id.length(), MIN_SESSION_ID_LENGTH);
}

@test:Config
function keepsLongSessionIds() {
    test:assertEquals(sessionId("CASE-20261103-1a2b3c", "apply-v1"), "CASE-20261103-1a2b3c-apply-v1-000");
    test:assertEquals(sessionId("CASE-20261103-1a2b3c-investigate", "attempt-1"),
            "CASE-20261103-1a2b3c-investigate-attempt-1");
}

@test:Config
function encodesRuntimeArnAsOneSegment() returns error? {
    string path = check invocationPath("arn:aws:bedrock-agentcore:us-east-1:111122223333:runtime/inquiry_agent-AbC123");
    test:assertEquals(path,
            "/runtimes/arn%3Aaws%3Abedrock-agentcore%3Aus-east-1%3A111122223333%3Aruntime%2Finquiry_agent-AbC123/invocations");
}
