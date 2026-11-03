#!/usr/bin/env bash
# Step 5: AgentCore Gateway with one MCP endpoint and three targets (the MCP runtimes).
#   Inbound:  Cognito client-credentials tokens from the investigator and applier clients.
#   Outbound: the gateway gets tokens for the runtimes through an AgentCore Identity OAuth
#             credential provider that uses the gateway-outbound Cognito client.
# TODO(verify): request fields against `aws bedrock-agentcore-control <command> help`, and the
# runtime endpoint URL format used for MCP server targets.
source "$(dirname "$0")/lib.sh"
require aws jq
need GatewayRoleArn CognitoDiscoveryUrl UserPoolId InvestigatorClientId ApplierClientId \
    GatewayOutboundClientId ReservationMcpRuntimeArn LoyaltyMcpRuntimeArn PaymentMcpRuntimeArn

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
