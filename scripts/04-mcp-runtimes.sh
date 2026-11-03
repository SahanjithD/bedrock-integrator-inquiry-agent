#!/usr/bin/env bash
# Step 4: host the reservation, loyalty and payment MCP servers on AgentCore Runtime.
# Each runtime accepts only tokens issued to the gateway's outbound Cognito client.
# TODO(verify): request fields against `aws bedrock-agentcore-control create-agent-runtime help`.
source "$(dirname "$0")/lib.sh"
require aws jq
need McpServerRuntimeRoleArn CognitoDiscoveryUrl GatewayOutboundClientId \
    ReservationMcpImage LoyaltyMcpImage PaymentMcpImage

runtime_name_prefix="${PROJECT_NAME//-/_}"

deploy_mcp_runtime() {
    local server="$1" image="$2"
    local id_key="${server^}McpRuntimeId" arn_key="${server^}McpRuntimeArn"
    local request
    request="$(jq \
        --arg name "${runtime_name_prefix}_${server}_mcp" \
        --arg description "${server^} tools for the inquiry agent (synthetic data)" \
        --arg image "${image}" \
        --arg role "${McpServerRuntimeRoleArn}" \
        --arg discovery "${CognitoDiscoveryUrl}" \
        --arg client "${GatewayOutboundClientId}" \
        '.agentRuntimeName = $name
         | .description = $description
         | .agentRuntimeArtifact.containerConfiguration.containerUri = $image
         | .roleArn = $role
         | .authorizerConfiguration.customJWTAuthorizer.discoveryUrl = $discovery
         | .authorizerConfiguration.customJWTAuthorizer.allowedClients = [$client]' \
        "${AGENTCORE_TEMPLATES}/mcp-runtime.json")"

    local existing="${!id_key:-}" result
    if [[ -z "${existing}" ]]; then
        log "Creating ${server} MCP runtime"
        result="$(aws bedrock-agentcore-control create-agent-runtime --cli-input-json "${request}")"
    else
        log "Updating ${server} MCP runtime ${existing}"
        request="$(jq --arg id "${existing}" 'del(.agentRuntimeName) | .agentRuntimeId = $id' <<<"${request}")"
        result="$(aws bedrock-agentcore-control update-agent-runtime --cli-input-json "${request}")"
    fi
    save "${id_key}" "$(jq -r .agentRuntimeId <<<"${result}")"
    save "${arn_key}" "$(jq -r .agentRuntimeArn <<<"${result}")"

    wait_for "${server} MCP runtime" "READY" "CREATE_FAILED|UPDATE_FAILED" \
        aws bedrock-agentcore-control get-agent-runtime --agent-runtime-id "${!id_key}" \
            --query status --output text
}

deploy_mcp_runtime reservation "${ReservationMcpImage}"
deploy_mcp_runtime loyalty "${LoyaltyMcpImage}"
deploy_mcp_runtime payment "${PaymentMcpImage}"
log "MCP runtimes ready"
