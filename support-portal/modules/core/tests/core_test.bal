import ballerina/test;
import ballerina/time;

@test:Config
function buildsCaseId() returns error? {
    time:Utc now = check time:utcFromString("2026-11-05T08:30:00Z");
    test:assertEquals(caseId(now, "1a2b3c4d"), "CASE-20261105-1a2b3c");
}

@test:Config
function mapsDecisions() {
    test:assertEquals(decisionMessage("CASE-1", "approve", 2, "rep-ana"),
        {caseId: "CASE-1", decision: "APPROVED", proposalVersion: 2, decidedBy: "rep-ana"});
    test:assertEquals(decisionMessage("CASE-1", "reject", 1, "rep-ana").decision, "REJECTED");
}

@test:Config
function buildsJob() {
    Job built = job("CASE-1", "G-15562", "Points missing", "email", {}, "2026-11-05T08:30:00Z", "rep-ana");
    test:assertEquals(built.requestedBy, "rep-ana");
}

@test:Config
function picksRepresentative() returns error? {
    test:assertEquals(check representative(" rep-ben ", "rep-ana"), "rep-ben");
    test:assertEquals(check representative((), "rep-ana"), "rep-ana");
    test:assertEquals(check representative("  ", "rep-ana"), "rep-ana");
    test:assertTrue(representative((), "") is error);
    string tooLong = string:'join("", ...from int i in 0 ..< MAX_REPRESENTATIVE_LENGTH + 1 select "a");
    test:assertTrue(representative(tooLong, "rep-ana") is error);
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
