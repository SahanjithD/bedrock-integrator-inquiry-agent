# Customer inquiry agent with Amazon Bedrock and WSO2 Integrator

Sample code for the AWS blog post "[article title]".

An inquiry agent built with WSO2 Integrator picks up investigation jobs from
Amazon SQS, reasons with Amazon Bedrock models behind a guardrail, and
retrieves runbooks and past cases from an Amazon Bedrock Managed Knowledge Base.
It gathers evidence through Amazon Bedrock AgentCore Gateway, and every change
it proposes waits for a person's approval.

> Work in progress. Uses synthetic data only.

## Design variants

The sample is being built in three variants, each on its own branch and pull request. They share
the MCP servers, AgentCore Gateway, the Bedrock guardrail and knowledge base, the DynamoDB case
table and the support console. They differ in how jobs reach the agent:

| Branch | How jobs reach the agent | Pull request |
| --- | --- | --- |
| `feature/agent-on-ecs` | A WSO2 Integrator SQS listener on Amazon ECS calls the agent on AgentCore Runtime for each job | #2 |
| `feature/lambda-dispatcher` | An SQS-triggered AWS Lambda function calls the agent on AgentCore Runtime | #3 |
| `feature/sample-implementation` | EventBridge Pipes start AWS Step Functions workflows that call the agent on AgentCore Runtime | #1 |

## License

Apache License 2.0.
