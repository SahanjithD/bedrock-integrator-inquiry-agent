#!/usr/bin/env bash
# Step 6: create the three sample cases through the support portal and wait for their
# investigations. Start the portal first, in another terminal:
#   ./scripts/portal-config.sh && cd support-portal && bal run
# This script starts nothing itself.
source "$(dirname "$0")/lib.sh"
require curl jq

portal="${PORTAL_URL:-http://localhost:9090}"
timeout_seconds="${DEMO_TIMEOUT_SECONDS:-1200}"

curl -sf "${portal}/cases" >/dev/null \
    || die "The support portal is not running at ${portal}. Start it with: cd support-portal && bal run"

case_ids=()
for sample in 1 2 3; do
    case_id="$(curl -sf -X POST "${portal}/cases" -H 'content-type: application/json' \
        -d "{\"sample\": ${sample}}" | jq -r .caseId)"
    [[ -n "${case_id}" && "${case_id}" != "null" ]] || die "Could not create sample ${sample}"
    log "Sample ${sample}: ${case_id}"
    case_ids+=("${case_id}")
done

# Waits until a case leaves QUEUED and INVESTIGATING.
wait_for_case() {
    local case_id="$1" status="" waited=0
    while (( waited < timeout_seconds )); do
        status="$(curl -sf "${portal}/cases/${case_id}" | jq -r .status)"
        case "${status}" in
            QUEUED|INVESTIGATING) sleep 10; waited=$(( waited + 10 )) ;;
            *) break ;;
        esac
    done
    printf '%s\n' "${status}"
}

echo
for case_id in "${case_ids[@]}"; do
    status="$(wait_for_case "${case_id}")"
    tool="$(curl -sf "${portal}/cases/${case_id}" | jq -r '.proposedAction.tool // "no change proposed"')"
    log "${case_id}: ${status} (${tool})"
done

# AgentCore Runtime creates its log groups when a runtime first starts a session; tag them now.
tag_runtime_log_groups

echo
log "Review the cases at ${portal}, or with curl, for example:"
echo "  curl -s ${portal}/cases/${case_ids[0]} | jq"
echo
log "Approve one (or use \"reject\"):"
echo "  curl -s -X POST ${portal}/cases/${case_ids[0]}/decision -H 'content-type: application/json' -d '{\"decision\": \"approve\"}'"
echo
log "Then check that it reaches APPLIED and shows the write tool's response:"
echo "  curl -s ${portal}/cases/${case_ids[0]} | jq '{status, applyResult}'"
