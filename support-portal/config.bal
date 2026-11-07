// Settings, from Config.toml. scripts/portal-config.sh writes Config.toml from the deploy
// outputs (.deploy/outputs.env). No secrets: AWS calls use your default AWS credentials.

# Port for the portal and its REST API.
configurable int port = 9090;
# AWS Region of the deployed sample.
configurable string awsRegion = "us-east-1";
# DynamoDB case table.
configurable string caseTable = ?;
# Queue the inquiry listener reads investigation jobs from.
configurable string jobQueueUrl = ?;
# Queue the inquiry listener reads decisions from.
configurable string decisionQueueUrl = ?;
# Dead-letter queue of the jobs queue.
configurable string jobDeadLetterQueueUrl = ?;
# Dead-letter queue of the decisions queue.
configurable string decisionDeadLetterQueueUrl = ?;
# Representative named on cases and decisions when the page sends no name. The listener passes
# it to the agent as the runtime user ID.
configurable string representative = "";
# The three sample inquiries, relative to this directory.
configurable string samplesFile = "../data/sample-inquiries.json";
# The portal page, relative to this directory.
configurable string pageFile = "static/index.html";
