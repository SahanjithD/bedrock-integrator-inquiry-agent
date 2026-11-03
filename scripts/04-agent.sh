#!/usr/bin/env bash
# Step 4: the inquiry agent on Amazon Bedrock AgentCore Runtime (HTTP protocol, port 8080, ARM64).
#   1. ECR repository and execution role (infra/cloudformation/agent-runtime.yaml).
#   2. Build the ARM64 agent image and push it.
#   3. Create or update the runtime (infra/agentcore/inquiry-agent.json). Settings go in
#      BAL_CONFIG_DATA; no secrets are passed (the agent reads them from Secrets Manager with its
#      execution role). The runtime uses IAM (SigV4) inbound auth, so only principals with
#      bedrock-agentcore:InvokeAgentRuntime - here, the listener's task role - can call it.
# TODO(verify): request fields against `aws bedrock-agentcore-control create-agent-runtime help`.
source "$(dirname "$0")/lib.sh"
require aws docker jq
need GuardrailId GuardrailArn GuardrailVersion KnowledgeBaseId CustomDataSourceId GatewayUrl \
    CognitoTokenUrl InvestigatorClientId ApplierClientId GatewayClientSecretsArn

log "Deploying stack ${AGENT_STACK} (repository and execution role)"
aws cloudformation deploy \
    --stack-name "${AGENT_STACK}" \
    --template-file "${REPO_ROOT}/infra/cloudformation/agent-runtime.yaml" \
    --capabilities CAPABILITY_NAMED_IAM \
    --parameter-overrides \
        "ProjectName=${PROJECT_NAME}" \
        "FoundationStackName=${FOUNDATION_STACK}" \
        "GuardrailArn=${GuardrailArn}" \
        "KnowledgeBaseId=${KnowledgeBaseId}" \
    --no-fail-on-empty-changeset
save_stack_outputs "${AGENT_STACK}"
need AgentRepositoryUri AgentRuntimeRoleArn

image="${AgentRepositoryUri}:$(image_tag)"
ecr_login "${AgentRepositoryUri%%/*}"
build_and_push "${image}" "${REPO_ROOT}/inquiry-agent"
save AgentImage "${image}"

config="$(cat <<TOML
awsRegion = "${AWS_REGION}"
modelId = "${MODEL_ID}"
investigationTimeoutSeconds = 600
guardrailId = "${GuardrailId}"
guardrailVersion = "${GuardrailVersion}"
knowledgeBaseId = "${KnowledgeBaseId}"
customDataSourceId = "${CustomDataSourceId}"
gatewayUrl = "${GatewayUrl}"
tokenUrl = "${CognitoTokenUrl}"
investigatorClientId = "${InvestigatorClientId}"
applierClientId = "${ApplierClientId}"
clientSecretsArn = "${GatewayClientSecretsArn}"
TOML
)"

request="$(jq \
    --arg name "${PROJECT_NAME//-/_}_inquiry_agent" \
    --arg image "${image}" \
    --arg role "${AgentRuntimeRoleArn}" \
    --arg config "${config}" \
    '.agentRuntimeName = $name
     | .agentRuntimeArtifact.containerConfiguration.containerUri = $image
     | .roleArn = $role
     | .environmentVariables.BAL_CONFIG_DATA = $config' \
    "${AGENTCORE_TEMPLATES}/inquiry-agent.json")"

if [[ -z "${AgentRuntimeId:-}" ]]; then
    log "Creating the inquiry agent runtime"
    sleep 15  # give a newly created IAM role time to propagate
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
