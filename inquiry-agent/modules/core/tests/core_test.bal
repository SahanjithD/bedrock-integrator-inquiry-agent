import ballerina/test;

final Evidence[] & readonly loyaltyEvidence = [
    {'source: "loyalty___listStays", detail: "Stay S-90551 for member M-77310 checked out 2026-11-01; accrual FAILED."},
    {'source: "runbooks/loyalty-points.md", detail: "Missing accruals are credited at the earn rate."}
];

isolated function findingsWith(ProposedAction? action) returns Findings {
    Findings findings = {
        summary: "Points for a completed stay were never posted.",
        evidence: loyaltyEvidence,
        rootCause: "The accrual batch skipped the stay.",
        draftReply: "We have added the missing points.",
        confidence: "high"
    };
    if action is ProposedAction {
        findings.proposedAction = action;
    }
    return findings;
}

@test:Config
function acceptsValidProposal() {
    Findings findings = findingsWith({
        tool: "loyalty___creditPoints",
        arguments: {memberId: "M-77310", stayId: "S-90551", points: 3150},
        rationale: "Credit the missing accrual."
    });
    test:assertEquals(validateProposal(findings), ());
}

@test:Config
function acceptsFindingsWithoutProposal() {
    test:assertEquals(validateProposal(findingsWith(())), ());
}

@test:Config
function rejectsReadToolAsAction() {
    AgentError? result = validateProposal(findingsWith({
        tool: "loyalty___listStays",
        arguments: {memberId: "M-77310"},
        rationale: "Not a write tool."
    }));
    test:assertTrue(result is AgentError);
}

@test:Config
function rejectsMissingArgument() {
    AgentError? result = validateProposal(findingsWith({
        tool: "loyalty___creditPoints",
        arguments: {memberId: "M-77310", stayId: "S-90551"},
        rationale: "Points missing."
    }));
    test:assertTrue(result is AgentError);
}

@test:Config
function rejectsIdNotInEvidence() {
    AgentError? result = validateProposal(findingsWith({
        tool: "loyalty___creditPoints",
        arguments: {memberId: "M-00000", stayId: "S-90551", points: 3150},
        rationale: "Wrong member."
    }));
    test:assertTrue(result is AgentError);
}

@test:Config
function rejectsProposedApprovalId() {
    AgentError? result = validateProposal(findingsWith({
        tool: "loyalty___creditPoints",
        arguments: {memberId: "M-77310", stayId: "S-90551", points: 3150, approvalId: "self-approved"},
        rationale: "Tries to approve itself."
    }));
    test:assertTrue(result is AgentError);
    if result is AgentError {
        test:assertEquals(result.detail().code, INVALID_PROPOSAL);
    }
}

@test:Config
function checksInvestigateRequest() {
    InvocationRequest missingJob = {action: "investigate", taskToken: "token", caseId: "CASE-1"};
    test:assertTrue(checkRequest(missingJob) is string);

    InvocationRequest ok = {
        action: "investigate",
        taskToken: "token",
        caseId: "CASE-1",
        job: {caseId: "CASE-1", customerRef: "G-10427", inquiry: "My confirmation shows old dates."}
    };
    test:assertEquals(checkRequest(ok), ());
}

@test:Config
function checksApplyRequest() {
    InvocationRequest noVersion = {action: "apply", taskToken: "token", caseId: "CASE-1"};
    test:assertTrue(checkRequest(noVersion) is string);

    InvocationRequest ok = {action: "apply", taskToken: "token", caseId: "CASE-1", proposalVersion: 1};
    test:assertEquals(checkRequest(ok), ());
}

@test:Config
function buildsApprovalId() {
    test:assertEquals(approvalIdFor("CASE-1", 2), "CASE-1#2");
}

@test:Config
function reportsBusyWhileWorkRuns() {
    jobStarted();
    test:assertEquals(currentStatus().status, "HealthyBusy");
    int changedAt = currentStatus().time_of_last_update;
    jobFinished();
    test:assertEquals(currentStatus().status, "Healthy");
    test:assertTrue(currentStatus().time_of_last_update >= changedAt);
}
