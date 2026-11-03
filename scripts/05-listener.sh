#!/usr/bin/env bash
# Step 5: the inquiry listener on Amazon ECS (infra/cloudformation/listener-ecs.yaml).
#   1. On the first run, create the stack with no tasks, to get the ECR repository.
#   2. Build the ARM64 listener image and push it.
#   3. Update the stack with the new image tag and one task, and wait for the service.
source "$(dirname "$0")/lib.sh"
require aws docker
need AgentRuntimeArn

deploy_listener_stack() {
    local image_tag="$1" desired_count="$2"
    aws cloudformation deploy \
        --stack-name "${LISTENER_STACK}" \
        --template-file "${REPO_ROOT}/infra/cloudformation/listener-ecs.yaml" \
        --capabilities CAPABILITY_IAM \
        --parameter-overrides \
            "ProjectName=${PROJECT_NAME}" \
            "FoundationStackName=${FOUNDATION_STACK}" \
            "ImageTag=${image_tag}" \
            "DesiredCount=${desired_count}" \
            "AgentRuntimeArn=${AgentRuntimeArn}" \
        --no-fail-on-empty-changeset
    save_stack_outputs "${LISTENER_STACK}"
}

if [[ -z "${ListenerRepositoryUri:-}" ]]; then
    log "Creating stack ${LISTENER_STACK} with no tasks, to get the image repository"
    deploy_listener_stack "none" 0
fi

tag="$(image_tag)"
ecr_login "${ListenerRepositoryUri%%/*}"
build_and_push "${ListenerRepositoryUri}:${tag}" "${REPO_ROOT}/inquiry-listener"
save ListenerImageTag "${tag}"

log "Deploying the listener service with image ${tag}"
deploy_listener_stack "${tag}" 1

log "Waiting for the service to become stable"
aws ecs wait services-stable --cluster "${ClusterName}" --services "${ServiceName}"
log "Inquiry listener running on ECS (cluster ${ClusterName}, service ${ServiceName})"
log "Logs: aws logs tail ${ListenerLogGroupName} --follow"
