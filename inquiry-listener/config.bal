// Settings. On Amazon ECS they arrive in the `BAL_CONFIG_DATA` environment variable, set by
// infra/cloudformation/listener-ecs.yaml. The listener needs no secrets: it signs its AWS
// requests with the ECS task role.

# AWS Region for every AWS call.
configurable string awsRegion = "us-east-1";

# Queue with investigation jobs from the support console.
configurable string jobQueueUrl = ?;
# Queue with approve or reject decisions from the support console.
configurable string decisionQueueUrl = ?;

// The listener waits for each agent call, which AgentCore Runtime ends after 15 minutes at
// most. A received message stays hidden for longer than that, so no other consumer picks it up
// while the call is open.
# Seconds a received job stays hidden from other consumers.
configurable int jobVisibilitySeconds = 1200;
# Seconds a received decision stays hidden from other consumers.
configurable int decisionVisibilitySeconds = 1200;
# Seconds before a failed message is retried. SQS moves it to the DLQ after 3 receives.
configurable int retryDelaySeconds = 60;
# Investigation attempts before a case is marked FAILED. Keep equal to the queue's maxReceiveCount.
configurable int maxAttempts = 3;

# DynamoDB table that holds one item per case.
configurable string caseTable = ?;

# ARN of the inquiry agent runtime on AgentCore Runtime.
configurable string agentRuntimeArn = ?;
# Runtime endpoint to invoke.
configurable string agentRuntimeQualifier = "DEFAULT";
# Seconds to wait for the agent's answer. AgentCore ends a synchronous request after 900 seconds.
configurable decimal agentTimeoutSeconds = 900;
