#!/usr/bin/env bash
# Step 2: the guardrail, and the Amazon Bedrock managed knowledge base with two data sources:
#   - S3 data source: runbooks and policies under s3://<bucket>/knowledge/
#   - custom data source: resolved cases, seeded here and added by the inquiry agent
#
# The guardrail and the knowledge base service role are in infra/cloudformation/knowledge.yaml.
# The knowledge base request bodies are in infra/knowledge-base/; the managed knowledge base
# and custom source mirror what the ballerinax/ai.aws.bedrock module sends.
# TODO(verify): your AWS CLI version supports the MANAGED knowledge base type and
# `ingest-knowledge-base-documents`.
source "$(dirname "$0")/lib.sh"
require aws jq
need KnowledgeBucketName

log "Deploying stack ${KNOWLEDGE_STACK} (guardrail and knowledge base role)"
deploy_stack "${KNOWLEDGE_STACK}" "${REPO_ROOT}/infra/cloudformation/knowledge.yaml" \
    --capabilities CAPABILITY_NAMED_IAM \
    --parameter-overrides \
        "ProjectName=${PROJECT_NAME}" \
        "FoundationStackName=${FOUNDATION_STACK}" \
        "$(boundary_parameter)"
save_stack_outputs "${KNOWLEDGE_STACK}"
need KnowledgeBaseRoleArn

log "Uploading runbooks and policies to s3://${KnowledgeBucketName}/knowledge/"
aws s3 sync "${REPO_ROOT}/data/knowledge/runbooks" "s3://${KnowledgeBucketName}/knowledge/runbooks" --delete
aws s3 sync "${REPO_ROOT}/data/knowledge/policies" "s3://${KnowledgeBucketName}/knowledge/policies" --delete

if [[ -z "${KnowledgeBaseId:-}" ]]; then
    log "Creating managed knowledge base"
    sleep 15  # give a newly created IAM role time to propagate
    kb_id="$(aws bedrock-agent create-knowledge-base \
        --name "${PROJECT_NAME}-kb" \
        --description "Runbooks, policies and resolved cases for the inquiry agent (synthetic data)" \
        --role-arn "${KnowledgeBaseRoleArn}" \
        --knowledge-base-configuration "file://${KB_TEMPLATES}/knowledge-base-configuration.json" \
        --tags "${TAGS_JSON}" \
        --query knowledgeBase.knowledgeBaseId --output text)"
    save KnowledgeBaseId "${kb_id}"
fi
wait_for "Knowledge base ${KnowledgeBaseId}" "ACTIVE" "FAILED|DELETE_UNSUCCESSFUL" \
    aws bedrock-agent get-knowledge-base --knowledge-base-id "${KnowledgeBaseId}" \
        --query knowledgeBase.status --output text
# Tags were set at creation; this keeps them current on re-runs. Data sources take no tags.
aws bedrock-agent tag-resource --tags "${TAGS_JSON}" --resource-arn "$(aws bedrock-agent get-knowledge-base \
    --knowledge-base-id "${KnowledgeBaseId}" --query knowledgeBase.knowledgeBaseArn --output text)"

if [[ -z "${CustomDataSourceId:-}" ]]; then
    log "Creating custom data source for resolved cases"
    ds_id="$(aws bedrock-agent create-data-source \
        --knowledge-base-id "${KnowledgeBaseId}" \
        --name resolved-cases \
        --description "Resolved cases, written by the apply action" \
        --data-source-configuration "file://${KB_TEMPLATES}/custom-data-source.json" \
        --query dataSource.dataSourceId --output text)"
    save CustomDataSourceId "${ds_id}"
fi

if [[ -z "${S3DataSourceId:-}" ]]; then
    log "Creating S3 data source for runbooks and policies"
    # TODO(verify): connector parameters for an S3 source on a managed knowledge base. If this
    # call is rejected, add the S3 source in the console (prefix knowledge/) and run:
    #   echo "S3DataSourceId=<id>" >> .deploy/outputs.env
    s3_config="$(jq --arg arn "arn:aws:s3:::${KnowledgeBucketName}" \
        '.managedKnowledgeBaseConnectorConfiguration.connectorParameters.bucketArn = $arn' \
        "${KB_TEMPLATES}/s3-data-source.json")"
    ds_id="$(aws bedrock-agent create-data-source \
        --knowledge-base-id "${KnowledgeBaseId}" \
        --name runbooks-and-policies \
        --description "Runbooks and policies under s3://${KnowledgeBucketName}/knowledge/" \
        --data-source-configuration "${s3_config}" \
        --query dataSource.dataSourceId --output text)"
    save S3DataSourceId "${ds_id}"
fi

log "Syncing the S3 data source"
job_id="$(aws bedrock-agent start-ingestion-job \
    --knowledge-base-id "${KnowledgeBaseId}" --data-source-id "${S3DataSourceId}" \
    --query ingestionJob.ingestionJobId --output text)"
wait_for "Ingestion job ${job_id}" "COMPLETE" "FAILED|STOPPED" \
    aws bedrock-agent get-ingestion-job --knowledge-base-id "${KnowledgeBaseId}" \
        --data-source-id "${S3DataSourceId}" --ingestion-job-id "${job_id}" \
        --query ingestionJob.status --output text

log "Seeding resolved cases into the custom data source"
documents="${STATE_DIR}/seed-documents.json"
jq '[.[] | {content: {dataSourceType: "CUSTOM", custom: {
        sourceType: "IN_LINE",
        customDocumentIdentifier: {id: .id},
        inlineContent: {type: "TEXT", textContent: {data: .text}}}}}]' \
    "${REPO_ROOT}/data/knowledge/resolved-cases/seed-cases.json" > "${documents}"
aws bedrock-agent ingest-knowledge-base-documents \
    --knowledge-base-id "${KnowledgeBaseId}" --data-source-id "${CustomDataSourceId}" \
    --documents "file://${documents}" --query 'documentDetails[].[identifier.custom.id,status]' --output text

log "Knowledge base ${KnowledgeBaseId} ready"
