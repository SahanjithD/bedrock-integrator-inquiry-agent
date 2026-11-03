#!/usr/bin/env bash
# Step 7: Lambda dispatcher, the investigate and apply state machines, and the two pipes.
source "$(dirname "$0")/lib.sh"
require aws
need KnowledgeBucketName AgentRuntimeArn

packaged="${STATE_DIR}/workflows.packaged.yaml"
log "Packaging the workflows template"
aws cloudformation package \
    --template-file "${REPO_ROOT}/infra/cloudformation/workflows.yaml" \
    --s3-bucket "${KnowledgeBucketName}" \
    --s3-prefix deploy \
    --output-template-file "${packaged}" >/dev/null

log "Deploying stack ${WORKFLOWS_STACK}"
aws cloudformation deploy \
    --stack-name "${WORKFLOWS_STACK}" \
    --template-file "${packaged}" \
    --capabilities CAPABILITY_IAM \
    --parameter-overrides \
        "ProjectName=${PROJECT_NAME}" \
        "FoundationStackName=${FOUNDATION_STACK}" \
        "AgentRuntimeArn=${AgentRuntimeArn}" \
    --no-fail-on-empty-changeset

save_stack_outputs "${WORKFLOWS_STACK}"
log "Workflows ready"
