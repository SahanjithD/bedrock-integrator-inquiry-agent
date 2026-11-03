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
