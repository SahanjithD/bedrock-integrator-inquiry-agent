#!/usr/bin/env bash
# Step 0: checks before anything is created. deploy.sh runs it first; run it on its own any time.
# It creates nothing. It stops with an error if a check fails:
#   - the account, Region, caller and tags you are about to use,
#   - the tools the deploy steps need,
#   - that nothing named with your prefix exists yet (on a first deployment),
#   - that the Cognito domain prefix is free and there is room for one more VPC,
#   - that the model can be called (one tiny request; set SKIP_MODEL_CHECK=1 to skip).
source "$(dirname "$0")/lib.sh"
require aws curl docker git

failures=0
pass() { log "OK    $*"; }
fail() { warn "FAIL  $*"; failures=$(( failures + 1 )); }
unknown() { warn "CHECK $*"; }

# Runs a describe/get command for a resource that should not exist yet.
#   expect_absent "<description>" command args...
expect_absent() {
    local what="$1" output
    shift
    if output="$("$@" 2>&1)"; then
        fail "${what} already exists. Choose another PROJECT_NAME, or clean up that deployment first."
    elif grep -qiE "NoSuchEntity|NotFound|NonExistent|does not exist|not exist|ResourceNotFound" <<<"${output}"; then
        pass "${what} is free"
    else
        unknown "could not check ${what}: $(head -1 <<<"${output}")"
    fi
}

# Fails if a list query returns any names.
#   expect_none "<description>" command args...
expect_none() {
    local what="$1" output
    shift
    if ! output="$("$@" 2>&1)"; then
        unknown "could not check ${what}: $(head -1 <<<"${output}")"
    elif [[ -n "${output}" && "${output}" != "None" && "${output}" != "[]" ]]; then
        fail "${what} already exists: ${output}"
    else
        pass "${what} is free"
    fi
}

# ---------------------------------------------------------------------------
log "Who and where"
identity="$(aws sts get-caller-identity --output json)" || die "No AWS credentials. Sign in first (for example aws sso login)."
log "  Account:  $(jq -r .Account <<<"${identity}")"
log "  Caller:   $(jq -r .Arn <<<"${identity}")"
log "  Region:   ${AWS_REGION}"
log "  Prefix:   ${PROJECT_NAME} (AgentCore names: ${RUNTIME_PREFIX}_...)"
log "  Tags:     ${TAGS_JSON}"
log "  Boundary: ${PERMISSIONS_BOUNDARY_ARN:-none}"

# ---------------------------------------------------------------------------
log "Tools"
if aws --version 2>&1 | grep -q '^aws-cli/2'; then pass "AWS CLI v2"; else fail "AWS CLI v2 is required ($(aws --version 2>&1))"; fi
for command in bedrock-agent bedrock-agentcore-control bedrock-agentcore; do
    if aws "${command}" help >/dev/null 2>&1; then pass "aws ${command}"; else fail "aws ${command} is missing; update the AWS CLI"; fi
done
if docker buildx version >/dev/null 2>&1; then pass "Docker Buildx"; else fail "Docker Buildx is required"; fi
if docker buildx ls 2>/dev/null | grep -q "linux/arm64"; then
    pass "Buildx can build linux/arm64"
else
    unknown "no Buildx builder lists linux/arm64; install QEMU emulation or use an ARM64 machine"
fi
if command -v bal >/dev/null 2>&1; then pass "bal ($(bal version 2>/dev/null | head -1))"; else unknown "bal not found; install WSO2 Integrator to run the support portal"; fi

# ---------------------------------------------------------------------------
if [[ -n "${CaseTableName:-}" ]]; then
    log "Names: .deploy/outputs.env already records a deployment of ${PROJECT_NAME}; skipping the name checks"
else
    log "Names (nothing with your prefix may exist yet)"
    for stack in "${FOUNDATION_STACK}" "${KNOWLEDGE_STACK}" "${MCP_STACK}" "${AGENT_STACK}" "${LISTENER_STACK}"; do
        expect_absent "stack ${stack}" aws cloudformation describe-stacks --stack-name "${stack}"
    done
    expect_absent "queue ${PROJECT_NAME}-jobs" aws sqs get-queue-url --queue-name "${PROJECT_NAME}-jobs"
    expect_absent "table ${PROJECT_NAME}-cases" aws dynamodb describe-table --table-name "${PROJECT_NAME}-cases"
    expect_absent "secret ${PROJECT_NAME}/gateway-clients" aws secretsmanager describe-secret --secret-id "${PROJECT_NAME}/gateway-clients"
    for role in knowledge-base mcp-runtime gateway agent-runtime; do
        expect_absent "IAM role ${PROJECT_NAME}-${role}" aws iam get-role --role-name "${PROJECT_NAME}-${role}"
    done
    for repository in inquiry-agent inquiry-listener reservation-mcp loyalty-mcp payment-mcp; do
        expect_absent "ECR repository ${PROJECT_NAME}/${repository}" \
            aws ecr describe-repositories --repository-names "${PROJECT_NAME}/${repository}"
    done
    expect_none "AgentCore runtimes ${RUNTIME_PREFIX}_*" aws bedrock-agentcore-control list-agent-runtimes \
        --query "agentRuntimes[?starts_with(agentRuntimeName, '${RUNTIME_PREFIX}_')].agentRuntimeName" --output text
    expect_none "gateway ${PROJECT_NAME}-gateway" aws bedrock-agentcore-control list-gateways \
        --query "items[?name=='${PROJECT_NAME}-gateway'].name" --output text
    expect_none "OAuth credential provider ${PROJECT_NAME}-runtime-oauth" aws bedrock-agentcore-control \
        list-oauth2-credential-providers --query "credentialProviders[?name=='${PROJECT_NAME}-runtime-oauth'].name" --output text
    expect_none "knowledge base ${PROJECT_NAME}-kb" aws bedrock-agent list-knowledge-bases \
        --query "knowledgeBaseSummaries[?name=='${PROJECT_NAME}-kb'].name" --output text

    domain_owner="$(aws cognito-idp describe-user-pool-domain --domain "${COGNITO_DOMAIN_PREFIX}" \
        --query DomainDescription.UserPoolId --output text 2>&1)" || domain_owner="ERROR ${domain_owner}"
    case "${domain_owner}" in
        ""|None) pass "Cognito domain ${COGNITO_DOMAIN_PREFIX} is free" ;;
        ERROR*) unknown "could not check Cognito domain ${COGNITO_DOMAIN_PREFIX}: ${domain_owner#ERROR }" ;;
        *) fail "Cognito domain ${COGNITO_DOMAIN_PREFIX} is taken; choose another COGNITO_DOMAIN_PREFIX" ;;
    esac

    if vpcs="$(aws ec2 describe-vpcs --query 'length(Vpcs)' --output text 2>&1)"; then
        if (( vpcs >= 5 )); then
            fail "the Region already has ${vpcs} VPCs; the default limit is 5. Ask your administrator for headroom."
        else
            pass "${vpcs} VPCs in the Region; the listener stack adds one (default limit 5)"
        fi
    else
        unknown "could not count VPCs: ${vpcs}"
    fi
fi

# ---------------------------------------------------------------------------
if [[ "${SKIP_MODEL_CHECK:-}" == "1" ]]; then
    log "Model: skipped (SKIP_MODEL_CHECK=1)"
else
    log "Model"
    if aws bedrock-runtime converse --model-id "${MODEL_ID}" \
            --messages '[{"role":"user","content":[{"text":"Reply with OK."}]}]' \
            --inference-config maxTokens=5 >/dev/null 2>&1; then
        pass "${MODEL_ID} can be called"
    else
        fail "${MODEL_ID} could not be called. Ask your administrator to enable model access (or set SKIP_MODEL_CHECK=1 if your role may not call models)."
    fi
fi

# ---------------------------------------------------------------------------
echo
if (( failures > 0 )); then
    die "Preflight found ${failures} problem(s). Nothing was created."
fi
log "Preflight passed. Lines marked CHECK could not be verified with your permissions; review them."
