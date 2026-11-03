#!/usr/bin/env bash
# Deletes everything the deploy scripts created, in reverse order. Safe to re-run: steps
# whose resources are already gone are skipped.
source "$(dirname "$0")/lib.sh"
require aws python3

try() { "$@" >/dev/null 2>&1 || warn "Skipped (already gone or failed): $*"; }

log "Deleting stack ${WORKFLOWS_STACK}"
try aws cloudformation delete-stack --stack-name "${WORKFLOWS_STACK}"
try aws cloudformation wait stack-delete-complete --stack-name "${WORKFLOWS_STACK}"

if [[ -n "${AgentRuntimeId:-}" ]]; then
    log "Deleting the inquiry agent runtime"
    try aws bedrock-agentcore-control delete-agent-runtime --agent-runtime-id "${AgentRuntimeId}"
    forget AgentRuntimeId; forget AgentRuntimeArn
fi

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
        forget "${key}"; forget "${server}McpRuntimeArn"
    fi
done

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

log "Deleting stack ${FOUNDATION_STACK}"
try aws cloudformation delete-stack --stack-name "${FOUNDATION_STACK}"
try aws cloudformation wait stack-delete-complete --stack-name "${FOUNDATION_STACK}"

rm -f "${OUTPUTS_FILE}" "${STATE_DIR}"/*.json "${STATE_DIR}"/*.yaml
log "Clean-up finished. Check the console for anything reported as skipped above."
