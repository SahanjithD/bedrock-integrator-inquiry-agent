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
    InvalidProposal? result = validateProposal(findingsWith({
        tool: "loyalty___listStays",
        arguments: {memberId: "M-77310"},
        rationale: "Not a write tool."
    }));
    test:assertTrue(result is InvalidProposal);
}

@test:Config
function rejectsMissingArgument() {
    InvalidProposal? result = validateProposal(findingsWith({
        tool: "loyalty___creditPoints",
        arguments: {memberId: "M-77310", stayId: "S-90551"},
        rationale: "Points missing."
    }));
    test:assertTrue(result is InvalidProposal);
}

@test:Config
function rejectsIdNotInEvidence() {
    InvalidProposal? result = validateProposal(findingsWith({
        tool: "loyalty___creditPoints",
        arguments: {memberId: "M-00000", stayId: "S-90551", points: 3150},
        rationale: "Wrong member."
    }));
    test:assertTrue(result is InvalidProposal);
}

@test:Config
function rejectsProposedApprovalId() {
    InvalidProposal? result = validateProposal(findingsWith({
        tool: "loyalty___creditPoints",
        arguments: {memberId: "M-77310", stayId: "S-90551", points: 3150, approvalId: "self-approved"},
        rationale: "Tries to approve itself."
    }));
    test:assertTrue(result is InvalidProposal);
}

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
function buildsApprovalId() {
    test:assertEquals(approvalIdFor("CASE-1", 2), "CASE-1#2");
}
