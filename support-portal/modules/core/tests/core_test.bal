import ballerina/test;
import ballerina/time;

@test:Config
function buildsCaseId() returns error? {
    time:Utc now = check time:utcFromString("2026-11-05T08:30:00Z");
    test:assertEquals(caseId(now, "1a2b3c4d"), "CASE-20261105-1a2b3c");
}

@test:Config
function mapsDecisions() {
    test:assertEquals(decisionMessage("CASE-1", "approve", 2), {caseId: "CASE-1", decision: "APPROVED", proposalVersion: 2});
    test:assertEquals(decisionMessage("CASE-1", "reject", 1).decision, "REJECTED");
}

@test:Config
function parsesCaseItem() {
    map<Attribute> item = {
        caseId: {S: "CASE-1"},
        status: {S: "PENDING_APPROVAL"},
        proposalVersion: {N: "1"},
        job: {S: "{\"caseId\":\"CASE-1\",\"inquiry\":\"Points missing\",\"customerRef\":\"G-15562\"}"},
        proposedAction: {S: "{\"tool\":\"loyalty___creditPoints\",\"arguments\":{\"points\":3465}}"},
        draftReply: {S: "We added your points."}
    };
    map<json> view = caseView(item);
    test:assertEquals(view["proposalVersion"], 1);
    test:assertEquals(view["draftReply"], "We added your points.");
    json action = view["proposedAction"];
    test:assertTrue(action is map<json>);

    map<json> summary = caseSummary(view);
    test:assertEquals(summary["inquiry"], "Points missing");
    test:assertEquals(summary["proposedTool"], "loyalty___creditPoints");
}

@test:Config
function keepsNullProposal() {
    map<json> view = caseView({caseId: {S: "CASE-2"}, status: {S: "NO_ACTION_PROPOSED"}, proposedAction: {S: "null"}});
    test:assertEquals(view["proposedAction"], ());
    test:assertEquals(caseSummary(view)["proposedTool"], ());
}
