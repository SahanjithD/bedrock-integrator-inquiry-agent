#!/usr/bin/env bash
# Step 5: the Lambda dispatcher (infra/cloudformation/dispatcher.yaml). Two functions read the
# jobs and decisions queues and call the inquiry agent on AgentCore Runtime.
source "$(dirname "$0")/lib.sh"
require aws
need KnowledgeBucketName AgentRuntimeArn

packaged="${STATE_DIR}/dispatcher.packaged.yaml"
log "Packaging the dispatcher template"
aws cloudformation package \
    --template-file "${REPO_ROOT}/infra/cloudformation/dispatcher.yaml" \
    --s3-bucket "${KnowledgeBucketName}" \
    --s3-prefix deploy \
    --output-template-file "${packaged}" >/dev/null

log "Deploying stack ${DISPATCHER_STACK}"
aws cloudformation deploy \
    --stack-name "${DISPATCHER_STACK}" \
    --template-file "${packaged}" \
    --capabilities CAPABILITY_IAM \
    --parameter-overrides \
        "ProjectName=${PROJECT_NAME}" \
        "FoundationStackName=${FOUNDATION_STACK}" \
        "AgentRuntimeArn=${AgentRuntimeArn}" \
    --no-fail-on-empty-changeset

save_stack_outputs "${DISPATCHER_STACK}"
log "Dispatcher ready. Logs: aws logs tail ${InvestigateLogGroupName} --follow"
