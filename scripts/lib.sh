#!/usr/bin/env bash
# Shared helpers for the deploy and clean-up scripts. Sourced, not run.

set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPTS_DIR}/.." && pwd)"
STATE_DIR="${REPO_ROOT}/.deploy"
OUTPUTS_FILE="${STATE_DIR}/outputs.env"
export AGENTCORE_TEMPLATES="${REPO_ROOT}/infra/agentcore"
export KB_TEMPLATES="${REPO_ROOT}/infra/knowledge-base"

if [[ ! -f "${SCRIPTS_DIR}/env.sh" ]]; then
    echo "Missing scripts/env.sh. Copy scripts/env.example.sh to scripts/env.sh and edit it." >&2
    exit 1
fi
# shellcheck source=env.example.sh
source "${SCRIPTS_DIR}/env.sh"
export AWS_REGION AWS_DEFAULT_REGION="${AWS_REGION}"

mkdir -p "${STATE_DIR}"
touch "${OUTPUTS_FILE}"
# shellcheck disable=SC1090
source "${OUTPUTS_FILE}"

log() { printf '\033[1;34m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
warn() { printf '\033[1;33m[%s] %s\033[0m\n' "$(date +%H:%M:%S)" "$*" >&2; }
die() { printf '\033[1;31m[%s] %s\033[0m\n' "$(date +%H:%M:%S)" "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Safety checks on the settings, so a run in a shared account only ever touches your own
# resources and tags all of them.
# ---------------------------------------------------------------------------
command -v jq >/dev/null 2>&1 || die "'jq' is required but not installed."

[[ "${PROJECT_NAME:-}" =~ ^[a-z][a-z0-9-]{2,30}$ ]] \
    || die "PROJECT_NAME '${PROJECT_NAME:-}' must be 3-31 lowercase letters, digits or hyphens, starting with a letter."
if [[ "${PROJECT_NAME}" == "inquiry-agent" || "${PROJECT_NAME}" == "inq-change-me" ]] \
        && [[ "${ALLOW_DEFAULT_PROJECT_NAME:-}" != "1" ]]; then
    die "Set your own PROJECT_NAME in scripts/env.sh (for example inq-<your-name>). The default could collide with someone else's deployment."
fi
[[ -n "${OWNER_TAG_KEY:-}" && -n "${OWNER_TAG_VALUE:-}" ]] \
    || die "Set OWNER_TAG_KEY and OWNER_TAG_VALUE in scripts/env.sh."
[[ "${OWNER_TAG_KEY}" != *"<"* && "${OWNER_TAG_VALUE}" != *"<"* ]] \
    || die "Replace the OWNER_TAG_KEY and OWNER_TAG_VALUE placeholders in scripts/env.sh."
[[ "${OWNER_TAG_KEY}" =~ ^[A-Za-z0-9_.:/=+@\ -]{1,128}$ && "${OWNER_TAG_KEY}" != aws:* ]] \
    || die "OWNER_TAG_KEY '${OWNER_TAG_KEY}' is not a valid tag key."
# The length is checked apart from the pattern: macOS allows at most {0,255} in a regex.
[[ "${OWNER_TAG_VALUE}" =~ ^[A-Za-z0-9_.:/=+@\ -]*$ && ${#OWNER_TAG_VALUE} -le 256 ]] \
    || die "OWNER_TAG_VALUE '${OWNER_TAG_VALUE}' is not a valid tag value."
[[ "${COGNITO_DOMAIN_PREFIX:-}" =~ ^[a-z0-9-]{3,63}$ && "${COGNITO_DOMAIN_PREFIX}" != *change-me ]] \
    || die "Set a unique COGNITO_DOMAIN_PREFIX in scripts/env.sh (lowercase letters, digits, hyphens)."

# Tags for every resource that supports them.
export TAG_PROJECT_KEY="Project"
# For `aws cloudformation deploy --tags`; CloudFormation copies them to the resources it creates.
STACK_TAGS=("${TAG_PROJECT_KEY}=${PROJECT_NAME}" "${OWNER_TAG_KEY}=${OWNER_TAG_VALUE}")
# For APIs that take a tags map, e.g. AgentCore and Bedrock knowledge bases.
TAGS_JSON="$(jq -cn --arg pk "${TAG_PROJECT_KEY}" --arg p "${PROJECT_NAME}" \
    --arg k "${OWNER_TAG_KEY}" --arg v "${OWNER_TAG_VALUE}" '{($pk): $p, ($k): $v}')"
export TAGS_JSON
# Prefix of the AgentCore runtime names (hyphens are not allowed there).
export RUNTIME_PREFIX="${PROJECT_NAME//-/_}"

require() {
    local cmd
    for cmd in "$@"; do
        command -v "${cmd}" >/dev/null 2>&1 || die "'${cmd}' is required but not installed."
    done
}

# Records KEY=VALUE in .deploy/outputs.env and in the current shell.
save() {
    local key="$1" value="$2" tmp
    tmp="$(mktemp)"
    grep -v "^${key}=" "${OUTPUTS_FILE}" > "${tmp}" || true
    printf '%s=%q\n' "${key}" "${value}" >> "${tmp}"
    mv "${tmp}" "${OUTPUTS_FILE}"
    printf -v "${key}" '%s' "${value}"
    export "${key?}"
}

# Removes KEY from .deploy/outputs.env.
forget() {
    local key="$1" tmp
    tmp="$(mktemp)"
    grep -v "^${key}=" "${OUTPUTS_FILE}" > "${tmp}" || true
    mv "${tmp}" "${OUTPUTS_FILE}"
    unset "${key}"
}

# Fails with a clear message if a value from an earlier step is missing.
need() {
    local key
    for key in "$@"; do
        [[ -n "${!key:-}" ]] || die "${key} is not set. Run the earlier deploy steps first."
    done
}

# Saves every output of a CloudFormation stack.
save_stack_outputs() {
    local stack="$1" key value
    while IFS=$'\t' read -r key value; do
        [[ -n "${key}" ]] && save "${key}" "${value}"
    done < <(aws cloudformation describe-stacks --stack-name "${stack}" \
        --query 'Stacks[0].Outputs[].[OutputKey,OutputValue]' --output text)
}

# Polls a command until it prints one of the wanted values.
#   wait_for "<description>" "<READY|ACTIVE>" "<FAILED|...>" command args...
wait_for() {
    local what="$1" ok="$2" bad="$3" status=""
    shift 3
    for _ in $(seq 1 90); do
        status="$("$@" 2>/dev/null || echo "UNKNOWN")"
        if [[ "|${ok}|" == *"|${status}|"* ]]; then
            log "${what}: ${status}"
            return 0
        fi
        if [[ "|${bad}|" == *"|${status}|"* ]]; then
            die "${what}: ${status}"
        fi
        sleep 10
    done
    die "${what}: timed out waiting (last status ${status})"
}

# URL-encodes one value (used for runtime ARNs in endpoint URLs).
urlencode() {
    jq -rn --arg v "$1" '$v|@uri'
}

# Logs Docker in to the account's ECR registry.
ecr_login() {
    local registry="$1"
    log "Logging in to ${registry}"
    aws ecr get-login-password | docker login --username AWS --password-stdin "${registry}"
}

# A tag for this build: the git commit plus a timestamp.
image_tag() {
    printf '%s-%s' "$(git -C "${REPO_ROOT}" rev-parse --short HEAD 2>/dev/null || echo local)" "$(date +%s)"
}

# Builds an ARM64 image and pushes it.
build_and_push() {
    local image="$1" context="$2"
    log "Building ${image}"
    docker buildx build --platform linux/arm64 --provenance=false -t "${image}" --push "${context}"
}

# Deletes every image in an ECR repository (if the repository exists).
delete_images() {
    local repository="$1" ids
    ids="$(aws ecr list-images --repository-name "${repository}" --query 'imageIds' --output json 2>/dev/null || echo '[]')"
    if [[ "${ids}" != "[]" ]]; then
        log "Deleting images in ${repository}"
        aws ecr batch-delete-image --repository-name "${repository}" --image-ids "${ids}" >/dev/null
    fi
}

# Deletes every object version and delete marker in a bucket, 1,000 at a time, so CloudFormation
# can delete the bucket. Works for versioned and unversioned buckets.
empty_bucket() {
    local bucket="$1" batch
    while true; do
        batch="$(aws s3api list-object-versions --bucket "${bucket}" --max-items 1000 --output json \
            | jq -c '{Objects: (((.Versions // []) + (.DeleteMarkers // []))
                       | map({Key, VersionId}) | .[:1000]), Quiet: true}')"
        local count
        count="$(jq '.Objects | length' <<<"${batch}" 2>/dev/null || true)"
        if [[ -z "${count}" || "${count}" == "0" ]]; then
            return 0
        fi
        aws s3api delete-objects --bucket "${bucket}" --delete "${batch}" >/dev/null
    done
}

# Deploys a CloudFormation stack with the sample's tags, the optional permissions boundary, and
# any extra arguments (for example --capabilities and --parameter-overrides).
deploy_stack() {
    local stack="$1" template="$2"
    shift 2
    aws cloudformation deploy \
        --stack-name "${stack}" \
        --template-file "${template}" \
        --tags "${STACK_TAGS[@]}" \
        --no-fail-on-empty-changeset \
        "$@"
}

# The permissions boundary parameter for templates that create IAM roles.
boundary_parameter() {
    printf 'PermissionsBoundaryArn=%s' "${PERMISSIONS_BOUNDARY_ARN:-}"
}

# Applies the sample's tags to an AgentCore resource (runtime, gateway or credential provider).
# Used after updates, because UpdateAgentRuntime does not take tags.
tag_agentcore() {
    aws bedrock-agentcore-control tag-resource --resource-arn "$1" --tags "${TAGS_JSON}" >/dev/null
}

# Tags the log groups that AgentCore Runtime creates for this sample's runtimes. They appear when
# a runtime first starts a session, so this is best effort and safe to repeat.
tag_runtime_log_groups() {
    local group arn
    while IFS=$'\t' read -r group arn; do
        [[ -n "${group}" ]] || continue
        if aws logs tag-resource --resource-arn "${arn%:\*}" --tags "${TAGS_JSON}" >/dev/null 2>&1; then
            log "Tagged log group ${group}"
        else
            warn "Could not tag log group ${group}"
        fi
    done < <(aws logs describe-log-groups --log-group-name-prefix "/aws/bedrock-agentcore/runtimes/${RUNTIME_PREFIX}_" \
        --query 'logGroups[].[logGroupName,arn]' --output text 2>/dev/null || true)
}
