#!/usr/bin/env bash
# Deploys the whole sample, in order. Each step can also be run on its own; values from
# earlier steps are kept in .deploy/outputs.env.
set -euo pipefail
dir="$(cd "$(dirname "$0")" && pwd)"

"${dir}/01-foundation.sh"
"${dir}/02-knowledge-base.sh"
"${dir}/03-mcp-servers.sh"
"${dir}/04-agent.sh"
"${dir}/05-listener.sh"
"${dir}/portal-config.sh"

echo
echo "Deployed. Start the support portal, then run the demo:"
echo "  cd support-portal && bal run        # then open http://localhost:9090"
echo "  ./scripts/06-demo.sh                # in another terminal"
