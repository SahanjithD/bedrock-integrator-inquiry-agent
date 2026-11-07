#!/usr/bin/env bash
# Deletes everything the deploy scripts created for PROJECT_NAME, in reverse order. It lists what
# it will delete and asks you to type the prefix first (or set CONFIRM_CLEANUP=<prefix>). Safe to
# re-run: steps whose resources are already gone are skipped.
source "$(dirname "$0")/lib.sh"
require aws jq

try() { "$@" >/dev/null 2>&1 || warn "Skipped (already gone or failed): $*"; }

delete_stack() {
    local stack="$1"
    log "Deleting stack ${stack}"
    try aws cloudformation delete-stack --stack-name "${stack}"
    try aws cloudformation wait stack-delete-complete --stack-name "${stack}"
}

# --- What will be deleted -------------------------------------------------------
# Only resources named with this prefix, or recorded in .deploy/outputs.env.
echo
log "This deletes everything deployed for '${PROJECT_NAME}' in $(aws sts get-caller-identity --query Account --output text) / ${AWS_REGION}:"
log "  Stacks:        ${LISTENER_STACK}, ${AGENT_STACK}, ${MCP_STACK}, ${KNOWLEDGE_STACK}, ${FOUNDATION_STACK}"
log "  ECR images:    ${PROJECT_NAME}/inquiry-listener, inquiry-agent, reservation-mcp, loyalty-mcp, payment-mcp"
runtimes="$(printf '%s ' "${AgentRuntimeId:-}" "${ReservationMcpRuntimeId:-}" "${LoyaltyMcpRuntimeId:-}" "${PaymentMcpRuntimeId:-}" | xargs)"
log "  AgentCore:     runtimes ${runtimes:-none}"
log "                 gateway ${GatewayId:-none}"
providers="$(printf '%s ' "${OauthProviderName:-}" "${InvestigatorProviderName:-}" "${ApplierProviderName:-}" | xargs)"
log "                 credential providers ${providers:-none}"
log "  Knowledge base ${KnowledgeBaseId:-none} and its data sources"
log "  Bucket:        ${KnowledgeBucketName:-none} (all object versions)"
log "  Log groups:    /aws/bedrock-agentcore/runtimes/${RUNTIME_PREFIX}_*"
echo
if [[ "${CONFIRM_CLEANUP:-}" != "${PROJECT_NAME}" ]]; then
    read -r -p "Type '${PROJECT_NAME}' to delete these resources: " answer
    [[ "${answer}" == "${PROJECT_NAME}" ]] || die "Not confirmed. Nothing was deleted."
fi

# --- Step 5: the listener on ECS ----------------------------------------------
delete_images "${PROJECT_NAME}/inquiry-listener" || true
delete_stack "${LISTENER_STACK}"
for key in ListenerRepositoryUri ListenerImageTag ClusterName ServiceName ListenerLogGroupName; do forget "${key}"; done

# --- Step 4: the agent on AgentCore Runtime ------------------------------------
if [[ -n "${AgentRuntimeId:-}" ]]; then
    log "Deleting the inquiry agent runtime"
    try aws bedrock-agentcore-control delete-agent-runtime --agent-runtime-id "${AgentRuntimeId}"
    forget AgentRuntimeId; forget AgentRuntimeArn; forget AgentImage
fi

for role in Investigator Applier; do
    key="${role}ProviderName"
    if [[ -n "${!key:-}" ]]; then
        log "Deleting the $(lowercase "${role}") credential provider"
        try aws bedrock-agentcore-control delete-oauth2-credential-provider --name "${!key}"
        forget "${key}"; forget "${role}ProviderSecretArn"
    fi
done

# --- Step 3: gateway, MCP runtimes, repositories ------------------------------
if [[ -n "${GatewayId:-}" ]]; then
    for key in ReservationTargetId LoyaltyTargetId PaymentTargetId; do
        if [[ -n "${!key:-}" ]]; then
            log "Deleting gateway target ${!key}"
            try aws bedrock-agentcore-control delete-gateway-target \
                --gateway-identifier "${GatewayId}" --target-id "${!key}"
            forget "${key}"
        fi
    done
    sleep 15
    log "Deleting gateway ${GatewayId}"
    try aws bedrock-agentcore-control delete-gateway --gateway-identifier "${GatewayId}"
    forget GatewayId; forget GatewayUrl
fi

if [[ -n "${OauthProviderName:-}" ]]; then
    log "Deleting the OAuth credential provider"
    try aws bedrock-agentcore-control delete-oauth2-credential-provider --name "${OauthProviderName}"
    forget OauthProviderName; forget OauthProviderArn
fi

for server in Reservation Loyalty Payment; do
    key="${server}McpRuntimeId"
    if [[ -n "${!key:-}" ]]; then
        log "Deleting the $(lowercase "${server}") MCP runtime"
        try aws bedrock-agentcore-control delete-agent-runtime --agent-runtime-id "${!key}"
        forget "${key}"; forget "${server}McpRuntimeArn"; forget "${server}McpImage"
    fi
done

# The runtimes' own log groups are created by AgentCore Runtime, not by a stack.
while IFS= read -r group; do
    [[ -n "${group}" && "${group}" != "None" ]] || continue
    log "Deleting log group ${group}"
    try aws logs delete-log-group --log-group-name "${group}"
done < <(aws logs describe-log-groups --log-group-name-prefix "/aws/bedrock-agentcore/runtimes/${RUNTIME_PREFIX}_" \
    --query 'logGroups[].logGroupName' --output text 2>/dev/null | tr '\t' '\n' || true)

# --- ECR repositories and roles for the agent and the MCP servers ---------------
delete_images "${PROJECT_NAME}/inquiry-agent" || true
delete_stack "${AGENT_STACK}"
forget AgentRepositoryUri; forget AgentRuntimeRoleArn
for server in reservation loyalty payment; do
    delete_images "${PROJECT_NAME}/${server}-mcp" || true
done
delete_stack "${MCP_STACK}"

# --- Step 2: knowledge base and guardrail -------------------------------------
if [[ -n "${KnowledgeBaseId:-}" ]]; then
    for key in S3DataSourceId CustomDataSourceId; do
        if [[ -n "${!key:-}" ]]; then
            log "Deleting data source ${!key}"
            try aws bedrock-agent delete-data-source \
                --knowledge-base-id "${KnowledgeBaseId}" --data-source-id "${!key}"
            forget "${key}"
        fi
    done
    log "Deleting knowledge base ${KnowledgeBaseId}"
    try aws bedrock-agent delete-knowledge-base --knowledge-base-id "${KnowledgeBaseId}"
    forget KnowledgeBaseId
fi
delete_stack "${KNOWLEDGE_STACK}"

# --- Step 1: foundation --------------------------------------------------------
if [[ -n "${KnowledgeBucketName:-}" ]]; then
    log "Emptying s3://${KnowledgeBucketName} (all object versions and delete markers)"
    empty_bucket "${KnowledgeBucketName}" || warn "Could not empty the bucket"
fi

delete_stack "${FOUNDATION_STACK}"

rm -f "${OUTPUTS_FILE}" "${STATE_DIR}"/*.json
log "Clean-up finished. Check the output above for anything reported as skipped."
