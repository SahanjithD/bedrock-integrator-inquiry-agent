# Customer inquiry agent with Amazon Bedrock and WSO2 Integrator

Sample code for the AWS blog post "<article title>".

An inquiry agent built with WSO2 Integrator picks up investigation jobs from
Amazon SQS, reasons with Amazon Bedrock models behind a guardrail, and
retrieves runbooks and past cases from an Amazon Bedrock Managed Knowledge Base.
It gathers evidence through Amazon Bedrock AgentCore Gateway, and every change
it proposes waits for a person's approval.

> Work in progress. Uses synthetic data only.
