#!/usr/bin/env bash
# Step 4: the inquiry agent on AgentCore Runtime (HTTP protocol, port 8080, ARM64).
#   1. Build the agent image and push it to ECR.
#   2. Create or update the runtime. Settings go in BAL_CONFIG_DATA; no secrets are passed (the
#      agent reads them from Secrets Manager). The runtime uses IAM (SigV4) inbound auth, so
#      only principals with bedrock-agentcore:InvokeAgentRuntime - here, the Lambda
#      dispatcher - can call it.
# TODO(verify): request fields against `aws bedrock-agentcore-control create-agent-runtime help`.
source "$(dirname "$0")/lib.sh"
require aws docker jq
need InquiryAgentRepositoryUri InquiryAgentRuntimeRoleArn GuardrailId GuardrailVersion \
    KnowledgeBaseId CustomDataSourceId GatewayUrl CognitoTokenUrl InvestigatorClientId \
    ApplierClientId GatewayClientSecretsArn

image="${InquiryAgentRepositoryUri}:$(image_tag)"
ecr_login "${InquiryAgentRepositoryUri%%/*}"
build_and_push "${image}" "${REPO_ROOT}/inquiry-agent"
save InquiryAgentImage "${image}"

config="$(cat <<EOF
awsRegion = "${AWS_REGION}"
modelId = "${MODEL_ID}"
guardrailId = "${GuardrailId}"
guardrailVersion = "${GuardrailVersion}"
investigationTimeoutSeconds = 600
knowledgeBaseId = "${KnowledgeBaseId}"
customDataSourceId = "${CustomDataSourceId}"
gatewayUrl = "${GatewayUrl}"
tokenUrl = "${CognitoTokenUrl}"
investigatorClientId = "${InvestigatorClientId}"
applierClientId = "${ApplierClientId}"
clientSecretsArn = "${GatewayClientSecretsArn}"
EOF
)"

request="$(jq \
    --arg name "${PROJECT_NAME//-/_}_inquiry_agent" \
    --arg image "${InquiryAgentImage}" \
    --arg role "${InquiryAgentRuntimeRoleArn}" \
    --arg config "${config}" \
    '.agentRuntimeName = $name
     | .description = "Customer inquiry agent (WSO2 Integrator)"
     | .agentRuntimeArtifact.containerConfiguration.containerUri = $image
     | .roleArn = $role
     | .environmentVariables.BAL_CONFIG_DATA = $config' \
    "${AGENTCORE_TEMPLATES}/agent-runtime.json")"

if [[ -z "${AgentRuntimeId:-}" ]]; then
    log "Creating the inquiry agent runtime"
    result="$(aws bedrock-agentcore-control create-agent-runtime --cli-input-json "${request}")"
else
    log "Updating the inquiry agent runtime ${AgentRuntimeId}"
    request="$(jq --arg id "${AgentRuntimeId}" 'del(.agentRuntimeName) | .agentRuntimeId = $id' <<<"${request}")"
    result="$(aws bedrock-agentcore-control update-agent-runtime --cli-input-json "${request}")"
fi
save AgentRuntimeId "$(jq -r .agentRuntimeId <<<"${result}")"
save AgentRuntimeArn "$(jq -r .agentRuntimeArn <<<"${result}")"

wait_for "Inquiry agent runtime" "READY" "CREATE_FAILED|UPDATE_FAILED" \
    aws bedrock-agentcore-control get-agent-runtime --agent-runtime-id "${AgentRuntimeId}" \
        --query status --output text
log "Inquiry agent runtime ready: ${AgentRuntimeArn}"
