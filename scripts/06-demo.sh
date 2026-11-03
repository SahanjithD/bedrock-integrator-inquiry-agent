#!/usr/bin/env bash
# Step 6: create the three sample cases and wait for their investigations.
# Approve or reject each one afterwards with scripts/console.py decide.
source "$(dirname "$0")/lib.sh"
require python3

console=(python3 "${SCRIPTS_DIR}/console.py")
case_ids=()
for sample in 1 2 3; do
    case_id="$("${console[@]}" submit --sample "${sample}" --id-only)"
    log "Sample ${sample}: ${case_id}"
    case_ids+=("${case_id}")
done

for case_id in "${case_ids[@]}"; do
    echo
    log "Waiting for ${case_id}"
    "${console[@]}" show "${case_id}" --watch
done

echo
log "Review each case, then approve or reject it, for example:"
echo "  python3 scripts/console.py decide ${case_ids[0]} --approve"
echo "  python3 scripts/console.py show ${case_ids[0]} --watch"
