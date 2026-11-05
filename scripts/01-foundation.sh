#!/usr/bin/env bash
# Step 1: SQS queues with DLQs, the DynamoDB case table, the knowledge bucket, and Cognito
# machine clients. Their secrets go to AgentCore Identity credential providers in steps 3 and 4.
source "$(dirname "$0")/lib.sh"
require aws

log "Deploying stack ${FOUNDATION_STACK}"
aws cloudformation deploy \
    --stack-name "${FOUNDATION_STACK}" \
    --template-file "${REPO_ROOT}/infra/cloudformation/foundation.yaml" \
    --parameter-overrides \
        "ProjectName=${PROJECT_NAME}" \
        "CognitoDomainPrefix=${COGNITO_DOMAIN_PREFIX}" \
    --no-fail-on-empty-changeset

save_stack_outputs "${FOUNDATION_STACK}"
log "Foundation ready. Outputs saved to .deploy/outputs.env"
