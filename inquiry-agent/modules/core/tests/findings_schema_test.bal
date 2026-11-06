import ballerina/ai;
import ballerina/test;

final readonly & map<json> COMPLETE_ANSWER = {
    summary: "Stay S-90551 closed after the accrual batch ran.",
    evidence: [{'source: "loyalty___listStays", detail: "Stay S-90551 accrual FAILED"}],
    rootCause: "The nightly accrual batch ran before checkout.",
    proposedAction: {
        tool: "loyalty___creditPoints",
        arguments: {memberId: "M-77310", stayId: "S-90551", points: 3465},
        rationale: "Credit the missing accrual."
    },
    draftReply: "We have added your points.",
    confidence: "high"
};

// The complete answer without its evidence.
final readonly & map<json> INCOMPLETE_ANSWER = map from [string, json] [name, value] in COMPLETE_ANSWER.entries()
    where name != "evidence"
    select [name, value];

// A model that answers each call at once through the agent's final-answer tool, with the next of
// its scripted answers. It records the parameter schema the agent offers for that tool and the
// number of messages each call receives.
isolated client class FinalAnswerModel {
    *ai:ModelProvider;

    private final map<json>[] answers;
    private map<json>? offeredSchema = ();
    private int[] messageCounts = [];

    isolated function init(map<json>[] answers) {
        self.answers = answers.clone();
    }

    isolated remote function chat(ai:ChatMessage[]|ai:ChatUserMessage messages,
            ai:ChatCompletionFunctions[] tools = [], string? stop = ()) returns ai:ChatAssistantMessage|ai:Error {
        ai:ChatCompletionFunctions finalAnswer = tools[tools.length() - 1];
        map<json> answer;
        lock {
            self.offeredSchema = finalAnswer.parameters.clone();
            self.messageCounts.push(messages is ai:ChatMessage[] ? messages.length() : 1);
            int call = self.messageCounts.length() - 1;
            answer = self.answers[call < self.answers.length() ? call : self.answers.length() - 1].clone();
        }
        return {role: ai:ASSISTANT, toolCalls: [{name: finalAnswer.name, id: "call-1", arguments: answer}]};
    }

    // Required by ai:ModelProvider but never called by the agent. A dependently typed function
    // must be external.
    isolated remote function generate(ai:Prompt prompt, typedesc<anydata> td = <>) returns td|ai:Error = external;

    isolated function schema() returns map<json>? {
        lock {
            return self.offeredSchema.clone();
        }
    }

    isolated function calls() returns int[] {
        lock {
            return self.messageCounts.clone();
        }
    }
}

isolated function testAgent(FinalAnswerModel model) returns ai:Agent|error =>
    new (systemPrompt = {role: "Tester", instructions: "Answer at once."},
        model = model, tools = [], memory = check jobMemory());

@test:Config
function agentReturnsFindings() returns error? {
    FinalAnswerModel model = new ([COMPLETE_ANSWER]);

    Findings findings = check runForFindings(check testAgent(model), "Points missing for stay S-90551",
        "session-1", "CASE-1");

    test:assertEquals(findings.confidence, "high");
    test:assertEquals(findings?.proposedAction?.tool, "loyalty___creditPoints");
    test:assertEquals(findings.knowledgeSources, []);
    test:assertEquals(model.calls().length(), 1);
    map<json>? schema = model.schema();
    test:assertTrue(schema is map<json>, "The agent offered no schema for its final-answer tool");
    test:assertEquals((<map<json>>schema)["required"], ["summary", "evidence", "rootCause", "draftReply", "confidence"]);
}

@test:Config
function incompleteAnswerIsCorrectedInTheSameSession() returns error? {
    FinalAnswerModel model = new ([INCOMPLETE_ANSWER, COMPLETE_ANSWER]);

    Findings findings = check runForFindings(check testAgent(model), "Points missing for stay S-90551",
        "session-2", "CASE-2");

    test:assertEquals(findings.evidence.length(), 1);
    int[] calls = model.calls();
    test:assertEquals(calls.length(), 2);
    // The correction turn sees the first turn's messages as well as its own.
    test:assertTrue(calls[1] > calls[0], string `The correction turn saw ${calls[1]} messages, the first turn ${calls[0]}`);
}

@test:Config
function answerIsCorrectedOnlyOnce() returns error? {
    FinalAnswerModel model = new ([INCOMPLETE_ANSWER, INCOMPLETE_ANSWER, COMPLETE_ANSWER]);

    Findings|error findings = runForFindings(check testAgent(model), "Points missing for stay S-90551",
        "session-3", "CASE-3");

    test:assertTrue(findings is error, "An answer that is still incomplete must fail");
    test:assertEquals(model.calls().length(), 2);
}
