#!/usr/bin/env bash
# Step 4: the inquiry agent on Amazon ECS (infra/cloudformation/agent-ecs.yaml).
#   1. On the first run, create the stack with no tasks, to get the ECR repository.
#   2. Build the ARM64 agent image and push it.
#   3. Update the stack with the new image tag and two tasks, and wait for the service.
source "$(dirname "$0")/lib.sh"
require aws docker
need GuardrailId GuardrailArn GuardrailVersion KnowledgeBaseId CustomDataSourceId GatewayUrl

deploy_agent_stack() {
    local image_tag="$1" desired_count="$2"
    aws cloudformation deploy \
        --stack-name "${AGENT_STACK}" \
        --template-file "${REPO_ROOT}/infra/cloudformation/agent-ecs.yaml" \
        --capabilities CAPABILITY_IAM \
        --parameter-overrides \
            "ProjectName=${PROJECT_NAME}" \
            "FoundationStackName=${FOUNDATION_STACK}" \
            "ImageTag=${image_tag}" \
            "DesiredCount=${desired_count}" \
            "ModelId=${MODEL_ID}" \
            "GuardrailId=${GuardrailId}" \
            "GuardrailArn=${GuardrailArn}" \
            "GuardrailVersion=${GuardrailVersion}" \
            "KnowledgeBaseId=${KnowledgeBaseId}" \
            "CustomDataSourceId=${CustomDataSourceId}" \
            "GatewayUrl=${GatewayUrl}" \
        --no-fail-on-empty-changeset
    save_stack_outputs "${AGENT_STACK}"
}

if [[ -z "${AgentRepositoryUri:-}" ]]; then
    log "Creating stack ${AGENT_STACK} with no tasks, to get the image repository"
    deploy_agent_stack "none" 0
fi

tag="$(image_tag)"
ecr_login "${AgentRepositoryUri%%/*}"
build_and_push "${AgentRepositoryUri}:${tag}" "${REPO_ROOT}/inquiry-agent"
save AgentImageTag "${tag}"

log "Deploying the agent service with image ${tag}"
deploy_agent_stack "${tag}" 2

log "Waiting for the service to become stable"
aws ecs wait services-stable --cluster "${ClusterName}" --services "${ServiceName}"
log "Inquiry agent running on ECS (cluster ${ClusterName}, service ${ServiceName})"
log "Logs: aws logs tail ${AgentLogGroupName} --follow"
