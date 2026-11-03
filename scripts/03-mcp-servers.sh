#!/usr/bin/env bash
# Step 3: the reservation, loyalty and payment MCP servers on Amazon Bedrock AgentCore Runtime,
# behind one AgentCore Gateway MCP endpoint.
#   1. Build the three ARM64 images and push them to ECR.
#   2. Create or update the three MCP runtimes. Each accepts only tokens issued to the gateway's
#      outbound Cognito client.
#   3. Create the gateway. Inbound: Cognito client-credentials tokens from the investigator and
#      applier clients. Outbound: an AgentCore Identity OAuth credential provider that uses the
#      gateway-outbound Cognito client.
# TODO(verify): request fields against `aws bedrock-agentcore-control <command> help`, and the
# runtime endpoint URL format used for MCP server targets.
source "$(dirname "$0")/lib.sh"
require aws docker jq
need McpServerRuntimeRoleArn GatewayRoleArn CognitoDiscoveryUrl UserPoolId InvestigatorClientId \
    ApplierClientId GatewayOutboundClientId ReservationMcpRepositoryUri LoyaltyMcpRepositoryUri \
    PaymentMcpRepositoryUri

# ---------------------------------------------------------------------------
# Images
# ---------------------------------------------------------------------------
tag="$(image_tag)"
ecr_login "${ReservationMcpRepositoryUri%%/*}"
for server in reservation loyalty payment; do
    repo_key="${server^}McpRepositoryUri"
    image="${!repo_key}:${tag}"
    build_and_push "${image}" "${REPO_ROOT}/mcp-servers/${server}"
    save "${server^}McpImage" "${image}"
done

# ---------------------------------------------------------------------------
# Runtimes
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# Gateway
# ---------------------------------------------------------------------------
gateway_name="${PROJECT_NAME}-gateway"

if [[ -z "${OauthProviderArn:-}" ]]; then
    log "Creating the outbound OAuth credential provider"
    outbound_secret="$(aws cognito-idp describe-user-pool-client \
        --user-pool-id "${UserPoolId}" --client-id "${GatewayOutboundClientId}" \
        --query UserPoolClient.ClientSecret --output text)"
    request="$(jq \
        --arg name "${PROJECT_NAME}-runtime-oauth" \
        --arg discovery "${CognitoDiscoveryUrl}" \
        --arg client "${GatewayOutboundClientId}" \
        --arg secret "${outbound_secret}" \
        '.name = $name
         | .oauth2ProviderConfigInput.customOauth2ProviderConfig.oauthDiscovery.discoveryUrl = $discovery
         | .oauth2ProviderConfigInput.customOauth2ProviderConfig.clientId = $client
         | .oauth2ProviderConfigInput.customOauth2ProviderConfig.clientSecret = $secret' \
        "${AGENTCORE_TEMPLATES}/oauth-provider.json")"
    provider_arn="$(aws bedrock-agentcore-control create-oauth2-credential-provider \
        --cli-input-json "${request}" --query credentialProviderArn --output text)"
    unset outbound_secret request
    save OauthProviderName "${PROJECT_NAME}-runtime-oauth"
    save OauthProviderArn "${provider_arn}"
fi

if [[ -z "${GatewayId:-}" ]]; then
    log "Creating gateway ${gateway_name}"
    request="$(jq \
        --arg name "${gateway_name}" \
        --arg role "${GatewayRoleArn}" \
        --arg discovery "${CognitoDiscoveryUrl}" \
        --arg investigator "${InvestigatorClientId}" \
        --arg applier "${ApplierClientId}" \
        '.name = $name
         | .description = "One MCP endpoint for the inquiry agent: reservation, loyalty and payment tools"
         | .roleArn = $role
         | .authorizerConfiguration.customJWTAuthorizer.discoveryUrl = $discovery
         | .authorizerConfiguration.customJWTAuthorizer.allowedClients = [$investigator, $applier]' \
        "${AGENTCORE_TEMPLATES}/gateway.json")"
    result="$(aws bedrock-agentcore-control create-gateway --cli-input-json "${request}")"
    save GatewayId "$(jq -r .gatewayId <<<"${result}")"
    save GatewayUrl "$(jq -r .gatewayUrl <<<"${result}")"
fi
wait_for "Gateway ${GatewayId}" "READY" "FAILED" \
    aws bedrock-agentcore-control get-gateway --gateway-identifier "${GatewayId}" \
        --query status --output text

add_target() {
    local name="$1" runtime_arn="$2"
    local key="${name^}TargetId"
    if [[ -n "${!key:-}" ]]; then
        log "Target ${name} already exists (${!key})"
        return 0
    fi
    local endpoint
    endpoint="https://bedrock-agentcore.${AWS_REGION}.amazonaws.com/runtimes/$(urlencode "${runtime_arn}")/invocations?qualifier=DEFAULT"
    log "Adding target ${name}"
    local request
    request="$(jq \
        --arg gateway "${GatewayId}" \
        --arg name "${name}" \
        --arg description "${name^} MCP server on AgentCore Runtime" \
        --arg endpoint "${endpoint}" \
        --arg provider "${OauthProviderArn}" \
        '.gatewayIdentifier = $gateway
         | .name = $name
         | .description = $description
         | .targetConfiguration.mcp.mcpServer.endpoint = $endpoint
         | .credentialProviderConfigurations[0].credentialProvider.oauthCredentialProvider.providerArn = $provider' \
        "${AGENTCORE_TEMPLATES}/gateway-target.json")"
    save "${key}" "$(aws bedrock-agentcore-control create-gateway-target \
        --cli-input-json "${request}" --query targetId --output text)"
    wait_for "Target ${name}" "READY" "FAILED|SYNCHRONIZE_UNSUCCESSFUL" \
        aws bedrock-agentcore-control get-gateway-target --gateway-identifier "${GatewayId}" \
            --target-id "${!key}" --query status --output text
}

# Target names become tool-name prefixes (e.g. loyalty___creditPoints); they must match
# inquiry-agent/modules/core/tools.bal.
add_target reservation "${ReservationMcpRuntimeArn}"
add_target loyalty "${LoyaltyMcpRuntimeArn}"
add_target payment "${PaymentMcpRuntimeArn}"
log "Gateway ready at ${GatewayUrl}"
