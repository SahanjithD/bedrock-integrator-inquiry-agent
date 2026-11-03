#!/usr/bin/env bash
# Deletes everything the deploy scripts created, in reverse order. Safe to re-run: steps
# whose resources are already gone are skipped.
source "$(dirname "$0")/lib.sh"
require aws python3

try() { "$@" >/dev/null 2>&1 || warn "Skipped (already gone or failed): $*"; }

delete_stack() {
    local stack="$1"
    log "Deleting stack ${stack}"
    try aws cloudformation delete-stack --stack-name "${stack}"
    try aws cloudformation wait stack-delete-complete --stack-name "${stack}"
}

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
        log "Deleting the ${server,,} MCP runtime"
        try aws bedrock-agentcore-control delete-agent-runtime --agent-runtime-id "${!key}"
        forget "${key}"; forget "${server}McpRuntimeArn"; forget "${server}McpImage"
    fi
done

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
    log "Emptying s3://${KnowledgeBucketName} (all object versions)"
    BUCKET="${KnowledgeBucketName}" python3 - <<'PY' || warn "Could not empty the bucket"
import os
import boto3
bucket = boto3.resource("s3").Bucket(os.environ["BUCKET"])
bucket.object_versions.delete()
PY
fi

if [[ -n "${GatewayClientSecretsArn:-}" ]]; then
    # Without this, the secret name stays reserved for 30 days and a redeploy fails.
    log "Deleting the gateway client secret without a recovery window"
    try aws secretsmanager delete-secret --secret-id "${GatewayClientSecretsArn}" \
        --force-delete-without-recovery
fi

delete_stack "${FOUNDATION_STACK}"

rm -f "${OUTPUTS_FILE}" "${STATE_DIR}"/*.json
log "Clean-up finished. Check the output above for anything reported as skipped."
