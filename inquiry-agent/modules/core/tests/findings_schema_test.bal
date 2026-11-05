import ballerina/ai;
import ballerina/test;

// A model that answers at once through the agent's final-answer tool, and records the parameter
// schema the agent offers for that tool.
isolated client class FinalAnswerModel {
    *ai:ModelProvider;

    private map<json>? offeredSchema = ();

    isolated remote function chat(ai:ChatMessage[]|ai:ChatUserMessage messages,
            ai:ChatCompletionFunctions[] tools = [], string? stop = ()) returns ai:ChatAssistantMessage|ai:Error {
        ai:ChatCompletionFunctions finalAnswer = tools[tools.length() - 1];
        lock {
            self.offeredSchema = finalAnswer.parameters.clone();
        }
        return {
            role: ai:ASSISTANT,
            toolCalls: [{
                name: finalAnswer.name,
                id: "call-1",
                arguments: {
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
                }
            }]
        };
    }

    // Required by ai:ModelProvider but never called by the agent. A dependently typed function
    // must be external.
    isolated remote function generate(ai:Prompt prompt, typedesc<anydata> td = <>) returns td|ai:Error = external;

    isolated function schema() returns map<json>? {
        lock {
            return self.offeredSchema.clone();
        }
    }
}

@test:Config
function agentReturnsFindings() returns error? {
    FinalAnswerModel model = new;
    ai:Agent agent = check new (systemPrompt = {role: "Tester", instructions: "Answer at once."},
        model = model, tools = [], memory = ());

    Findings findings = check agent.run("Points missing for stay S-90551");

    test:assertEquals(findings.confidence, "high");
    test:assertEquals(findings?.proposedAction?.tool, "loyalty___creditPoints");
    test:assertEquals(findings.knowledgeSources, []);
    map<json>? schema = model.schema();
    test:assertTrue(schema is map<json>, "The agent offered no schema for its final-answer tool");
    test:assertEquals((<map<json>>schema)["required"], ["summary", "evidence", "rootCause", "draftReply", "confidence"]);
}
