#!/usr/bin/env bash
# Step 3: the reservation, loyalty and payment MCP servers on Amazon Bedrock AgentCore Runtime,
# behind one AgentCore Gateway MCP endpoint.
#   1. ECR repositories and IAM roles (infra/cloudformation/mcp-servers.yaml)
#   2. Three ARM64 images, built and pushed
#   3. Three MCP runtimes. Each accepts only tokens issued to the gateway's outbound Cognito client.
#   4. The gateway. Inbound: Cognito client-credentials tokens from the investigator and applier
#      clients. Outbound: an AgentCore Identity OAuth credential provider that uses the
#      gateway-outbound Cognito client.
# The requests below and the runtime endpoint URL used for the targets work against AWS: each
# target is READY only after the gateway has listed the MCP server's tools through it.
source "$(dirname "$0")/lib.sh"
require aws docker jq
need CognitoDiscoveryUrl UserPoolId InvestigatorClientId ApplierClientId GatewayOutboundClientId

log "Deploying stack ${MCP_STACK} (repositories and roles)"
deploy_stack "${MCP_STACK}" "${REPO_ROOT}/infra/cloudformation/mcp-servers.yaml" \
    --capabilities CAPABILITY_NAMED_IAM \
    --parameter-overrides "ProjectName=${PROJECT_NAME}" "$(boundary_parameter)"
save_stack_outputs "${MCP_STACK}"
need McpServerRuntimeRoleArn GatewayRoleArn ReservationMcpRepositoryUri LoyaltyMcpRepositoryUri PaymentMcpRepositoryUri

# ---------------------------------------------------------------------------
# Images
# ---------------------------------------------------------------------------
tag="$(image_tag)"
ecr_login "${ReservationMcpRepositoryUri%%/*}"
for server in reservation loyalty payment; do
    repo_key="$(capitalize "${server}")McpRepositoryUri"
    image="${!repo_key}:${tag}"
    build_and_push "${image}" "${REPO_ROOT}/mcp-servers/${server}"
    save "$(capitalize "${server}")McpImage" "${image}"
done

# ---------------------------------------------------------------------------
# Runtimes
# ---------------------------------------------------------------------------
runtime_name_prefix="${PROJECT_NAME//-/_}"

deploy_mcp_runtime() {
    local server="$1" image="$2"
    local id_key="$(capitalize "${server}")McpRuntimeId" arn_key="$(capitalize "${server}")McpRuntimeArn"
    local request
    request="$(jq \
        --arg name "${runtime_name_prefix}_${server}_mcp" \
        --arg description "$(capitalize "${server}") tools for the inquiry agent (synthetic data)" \
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
        request="$(jq --argjson tags "${TAGS_JSON}" '.tags = $tags' <<<"${request}")"
        result="$(aws bedrock-agentcore-control create-agent-runtime --cli-input-json "${request}")"
    else
        log "Updating ${server} MCP runtime ${existing}"
        request="$(jq --arg id "${existing}" 'del(.agentRuntimeName) | .agentRuntimeId = $id' <<<"${request}")"
        result="$(aws bedrock-agentcore-control update-agent-runtime --cli-input-json "${request}")"
    fi
    save "${id_key}" "$(jq -r .agentRuntimeId <<<"${result}")"
    save "${arn_key}" "$(jq -r .agentRuntimeArn <<<"${result}")"
    tag_agentcore "${!arn_key}"

    wait_for "${server} MCP runtime" "READY" "CREATE_FAILED|UPDATE_FAILED" \
        aws bedrock-agentcore-control get-agent-runtime --agent-runtime-id "${!id_key}" \
            --query status --output text
}

if [[ -z "${ReservationMcpRuntimeId:-}" ]]; then
    sleep 15  # give newly created IAM roles time to propagate
fi
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
        --argjson tags "${TAGS_JSON}" \
        '.name = $name
         | .tags = $tags
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
        --argjson tags "${TAGS_JSON}" \
        '.name = $name
         | .tags = $tags
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

# Prints a gateway target's status, or GONE if it does not exist.
target_status() {
    local output
    if output="$(aws bedrock-agentcore-control get-gateway-target --gateway-identifier "${GatewayId}" \
            --target-id "$1" --query status --output text 2>&1)"; then
        printf '%s\n' "${output}"
    elif [[ "${output}" == *ResourceNotFoundException* ]]; then
        printf 'GONE\n'
    else
        printf '%s\n' "${output}" >&2
        return 1
    fi
}

target_reasons() {
    aws bedrock-agentcore-control get-gateway-target --gateway-identifier "${GatewayId}" \
        --target-id "$1" --query statusReasons --output text
}

# Adds a target unless a working one is recorded. A recorded target that failed is deleted and
# added again, and one that no longer exists is added again.
add_target() {
    local name="$1" runtime_arn="$2"
    local key="$(capitalize "${name}")TargetId" status
    if [[ -n "${!key:-}" ]]; then
        status="$(target_status "${!key}")" || die "Could not read target ${name} (${!key})"
        case "${status}" in
            READY)
                log "Target ${name} already exists (${!key})"
                return 0 ;;
            FAILED|SYNCHRONIZE_UNSUCCESSFUL|UPDATE_UNSUCCESSFUL)
                warn "Target ${name} (${!key}) ${status}: $(target_reasons "${!key}")"
                log "Deleting target ${name} (${!key}) to add it again"
                aws bedrock-agentcore-control delete-gateway-target --gateway-identifier "${GatewayId}" \
                    --target-id "${!key}" >/dev/null
                wait_for "Deleting target ${name}" "GONE" "" target_status "${!key}"
                forget "${key}" ;;
            GONE)
                forget "${key}" ;;
            *)
                die "Target ${name} (${!key}) is ${status}; run this step again when it settles" ;;
        esac
    fi
    local endpoint
    endpoint="https://bedrock-agentcore.${AWS_REGION}.amazonaws.com/runtimes/$(urlencode "${runtime_arn}")/invocations?qualifier=DEFAULT"
    log "Adding target ${name}"
    local request
    request="$(jq \
        --arg gateway "${GatewayId}" \
        --arg name "${name}" \
        --arg description "$(capitalize "${name}") MCP server on AgentCore Runtime" \
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
    # Failures are not passed to wait_for, so the reason can be shown before stopping.
    wait_for "Target ${name}" "READY|FAILED|SYNCHRONIZE_UNSUCCESSFUL" "" target_status "${!key}"
    status="$(target_status "${!key}")"
    [[ "${status}" == "READY" ]] || die "Target ${name} (${!key}) ${status}: $(target_reasons "${!key}")"
}

# Target names become tool-name prefixes (e.g. loyalty___creditPoints); they must match
# inquiry-agent/modules/core/tools.bal.
add_target reservation "${ReservationMcpRuntimeArn}"
add_target loyalty "${LoyaltyMcpRuntimeArn}"
add_target payment "${PaymentMcpRuntimeArn}"
tag_agentcore "${OauthProviderArn}"
tag_agentcore "$(aws bedrock-agentcore-control get-gateway --gateway-identifier "${GatewayId}" --query gatewayArn --output text)"
tag_runtime_log_groups
log "Gateway ready at ${GatewayUrl}"
