#!/usr/bin/env bash
# Step 1: queues, case table, knowledge bucket, container repositories, guardrail,
# Cognito machine clients and IAM roles.
source "$(dirname "$0")/lib.sh"
require aws

log "Deploying stack ${FOUNDATION_STACK}"
aws cloudformation deploy \
    --stack-name "${FOUNDATION_STACK}" \
    --template-file "${REPO_ROOT}/infra/cloudformation/foundation.yaml" \
    --capabilities CAPABILITY_NAMED_IAM \
    --parameter-overrides \
        "ProjectName=${PROJECT_NAME}" \
        "CognitoDomainPrefix=${COGNITO_DOMAIN_PREFIX}" \
    --no-fail-on-empty-changeset

save_stack_outputs "${FOUNDATION_STACK}"
log "Foundation ready. Outputs saved to .deploy/outputs.env"
