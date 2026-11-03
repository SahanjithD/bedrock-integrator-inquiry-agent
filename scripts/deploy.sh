#!/usr/bin/env bash
# Deploys the whole sample, in order. Each step can also be run on its own; values from
# earlier steps are kept in .deploy/outputs.env.
set -euo pipefail
dir="$(cd "$(dirname "$0")" && pwd)"

"${dir}/01-foundation.sh"
"${dir}/02-build-push.sh"
"${dir}/03-knowledge-base.sh"
"${dir}/04-mcp-runtimes.sh"
"${dir}/05-gateway.sh"
"${dir}/06-agent-runtime.sh"
"${dir}/07-workflows.sh"

echo
echo "Deployed. Try it:"
echo "  python3 scripts/console.py submit --sample 1"
