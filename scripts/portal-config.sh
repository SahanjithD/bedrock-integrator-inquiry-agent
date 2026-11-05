#!/usr/bin/env bash
# Writes support-portal/Config.toml from the deploy outputs (.deploy/outputs.env), so the
# support portal uses the deployed case table and queues. Run after 01-foundation.sh.
source "$(dirname "$0")/lib.sh"
need CaseTableName JobQueueUrl DecisionQueueUrl JobDeadLetterQueueUrl DecisionDeadLetterQueueUrl

config="${REPO_ROOT}/support-portal/Config.toml"
cat > "${config}" <<TOML
# Written by scripts/portal-config.sh from .deploy/outputs.env. Not committed.
port = 9090
awsRegion = "${AWS_REGION}"
caseTable = "${CaseTableName}"
jobQueueUrl = "${JobQueueUrl}"
decisionQueueUrl = "${DecisionQueueUrl}"
jobDeadLetterQueueUrl = "${JobDeadLetterQueueUrl}"
decisionDeadLetterQueueUrl = "${DecisionDeadLetterQueueUrl}"
representative = "${USER:-support-rep}"
TOML
log "Wrote ${config}"
