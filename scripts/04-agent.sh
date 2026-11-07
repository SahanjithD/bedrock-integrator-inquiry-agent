#!/usr/bin/env bash
# Step 4: the inquiry agent on Amazon Bedrock AgentCore Runtime (HTTP protocol, port 8080, ARM64).
#   1. Two AgentCore Identity credential providers for the gateway: investigator (read scope)
#      and applier (write scope). Each holds its Cognito client's secret; the agent never does.
#   2. ECR repository and execution role (infra/cloudformation/agent-runtime.yaml). The role may
#      read only these two providers' secrets.
#   3. Build the ARM64 agent image and push it.
#   4. Create or update the runtime (infra/agentcore/inquiry-agent.json). Each setting is its own
#      BAL_CONFIG_VAR_<NAME> environment variable, because AgentCore Runtime rejects line breaks in
#      environment variable values (so a multi-line BAL_CONFIG_DATA cannot be used). No secrets
#      are passed. The runtime uses IAM (SigV4) inbound auth, so only
#      principals with bedrock-agentcore:InvokeAgentRuntime - here, the listener's task role - can
#      call it. The listener sends a runtime user ID, so the runtime passes the agent a workload
#      access token, which the agent exchanges for gateway tokens.
# TODO(verify): request fields against `aws bedrock-agentcore-control create-agent-runtime help`.
source "$(dirname "$0")/lib.sh"
require aws docker jq
need GuardrailId GuardrailArn GuardrailVersion KnowledgeBaseId CustomDataSourceId GatewayUrl \
    UserPoolId CognitoDiscoveryUrl InvestigatorClientId ApplierClientId

# ---------------------------------------------------------------------------
# Credential providers
# ---------------------------------------------------------------------------
# Creates one provider for a Cognito client, unless it already exists, and saves its name, its
# ARN and the ARN of the secret AgentCore Identity stores the client secret in.
#   create_credential_provider <Investigator|Applier> <client ID>
create_credential_provider() {
    local role="$1" client_id="$2"
    local name_key="${role}ProviderName" arn_key="${role}ProviderArn" secret_key="${role}ProviderSecretArn"
    if [[ -n "${!secret_key:-}" ]]; then
        log "Credential provider ${!name_key} already exists"
        # Provider ARNs follow a fixed format. Building it saves a lookup, which AgentCore also
        # authorizes against the token vault.
        if [[ -z "${!arn_key:-}" ]]; then
            save "${arn_key}" "arn:aws:bedrock-agentcore:${AWS_REGION}:$(cut -d: -f5 <<<"${!secret_key}"):token-vault/default/oauth2credentialprovider/${!name_key}"
        fi
        tag_agentcore "${!arn_key}"
        return 0
    fi
    local name="${PROJECT_NAME}-$(lowercase "${role}")" client_secret request result
    log "Creating credential provider ${name}"
    client_secret="$(aws cognito-idp describe-user-pool-client \
        --user-pool-id "${UserPoolId}" --client-id "${client_id}" \
        --query UserPoolClient.ClientSecret --output text)"
    request="$(jq \
        --arg name "${name}" \
        --arg discovery "${CognitoDiscoveryUrl}" \
        --arg client "${client_id}" \
        --arg secret "${client_secret}" \
        --argjson tags "${TAGS_JSON}" \
        '.name = $name
         | .tags = $tags
         | .oauth2ProviderConfigInput.customOauth2ProviderConfig.oauthDiscovery.discoveryUrl = $discovery
         | .oauth2ProviderConfigInput.customOauth2ProviderConfig.clientId = $client
         | .oauth2ProviderConfigInput.customOauth2ProviderConfig.clientSecret = $secret' \
        "${AGENTCORE_TEMPLATES}/oauth-provider.json")"
    result="$(aws bedrock-agentcore-control create-oauth2-credential-provider --cli-input-json "${request}")"
    unset client_secret request
    save "${name_key}" "${name}"
    save "${arn_key}" "$(jq -r .credentialProviderArn <<<"${result}")"
    save "${secret_key}" "$(jq -r .clientSecretArn.secretArn <<<"${result}")"
}

create_credential_provider Investigator "${InvestigatorClientId}"
create_credential_provider Applier "${ApplierClientId}"

# ---------------------------------------------------------------------------
# Repository and execution role
# ---------------------------------------------------------------------------
log "Deploying stack ${AGENT_STACK} (repository and execution role)"
deploy_stack "${AGENT_STACK}" "${REPO_ROOT}/infra/cloudformation/agent-runtime.yaml" \
    --capabilities CAPABILITY_NAMED_IAM \
    --parameter-overrides \
        "ProjectName=${PROJECT_NAME}" \
        "GuardrailArn=${GuardrailArn}" \
        "KnowledgeBaseId=${KnowledgeBaseId}" \
        "InvestigatorProviderSecretArn=${InvestigatorProviderSecretArn}" \
        "ApplierProviderSecretArn=${ApplierProviderSecretArn}" \
        "$(boundary_parameter)"
save_stack_outputs "${AGENT_STACK}"
need AgentRepositoryUri AgentRuntimeRoleArn

# ---------------------------------------------------------------------------
# Image and runtime
# ---------------------------------------------------------------------------
image="${AgentRepositoryUri}:$(image_tag)"
ecr_login "${AgentRepositoryUri%%/*}"
build_and_push "${image}" "${REPO_ROOT}/inquiry-agent"
save AgentImage "${image}"

# Ballerina reads BAL_CONFIG_VAR_<NAME> for a configurable named <name> in the root module, with
# the name in capitals. This works for simple values (strings, numbers, booleans) only.
settings="$(jq -n \
    --arg region "${AWS_REGION}" \
    --arg model "${MODEL_ID}" \
    --arg guardrail "${GuardrailId}" \
    --arg guardrailVersion "${GuardrailVersion}" \
    --arg knowledgeBase "${KnowledgeBaseId}" \
    --arg dataSource "${CustomDataSourceId}" \
    --arg gateway "${GatewayUrl}" \
    --arg investigator "${InvestigatorProviderName}" \
    --arg applier "${ApplierProviderName}" \
    '{
        BAL_CONFIG_VAR_AWSREGION: $region,
        BAL_CONFIG_VAR_MODELID: $model,
        BAL_CONFIG_VAR_INVESTIGATIONTIMEOUTSECONDS: "600",
        BAL_CONFIG_VAR_GUARDRAILID: $guardrail,
        BAL_CONFIG_VAR_GUARDRAILVERSION: $guardrailVersion,
        BAL_CONFIG_VAR_KNOWLEDGEBASEID: $knowledgeBase,
        BAL_CONFIG_VAR_CUSTOMDATASOURCEID: $dataSource,
        BAL_CONFIG_VAR_GATEWAYURL: $gateway,
        BAL_CONFIG_VAR_INVESTIGATORCREDENTIALPROVIDER: $investigator,
        BAL_CONFIG_VAR_APPLIERCREDENTIALPROVIDER: $applier
    }')"

request="$(jq \
    --arg name "${PROJECT_NAME//-/_}_inquiry_agent" \
    --arg image "${image}" \
    --arg role "${AgentRuntimeRoleArn}" \
    --argjson settings "${settings}" \
    '.agentRuntimeName = $name
     | .agentRuntimeArtifact.containerConfiguration.containerUri = $image
     | .roleArn = $role
     | .environmentVariables = $settings' \
    "${AGENTCORE_TEMPLATES}/inquiry-agent.json")"

if [[ -z "${AgentRuntimeId:-}" ]]; then
    log "Creating the inquiry agent runtime"
    sleep 15  # give a newly created IAM role time to propagate
    request="$(jq --argjson tags "${TAGS_JSON}" '.tags = $tags' <<<"${request}")"
    result="$(aws bedrock-agentcore-control create-agent-runtime --cli-input-json "${request}")"
else
    log "Updating the inquiry agent runtime ${AgentRuntimeId}"
    request="$(jq --arg id "${AgentRuntimeId}" 'del(.agentRuntimeName) | .agentRuntimeId = $id' <<<"${request}")"
    result="$(aws bedrock-agentcore-control update-agent-runtime --cli-input-json "${request}")"
fi
save AgentRuntimeId "$(jq -r .agentRuntimeId <<<"${result}")"
save AgentRuntimeArn "$(jq -r .agentRuntimeArn <<<"${result}")"
tag_agentcore "${AgentRuntimeArn}"

wait_for "Inquiry agent runtime" "READY" "CREATE_FAILED|UPDATE_FAILED" \
    aws bedrock-agentcore-control get-agent-runtime --agent-runtime-id "${AgentRuntimeId}" \
        --query status --output text
log "Inquiry agent runtime ready: ${AgentRuntimeArn}"
