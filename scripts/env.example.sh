#!/usr/bin/env bash
# Copy to scripts/env.sh and edit. scripts/env.sh is ignored by git.

export AWS_REGION="us-east-1"

# Prefix for every resource name. Use your own, e.g. inq-<your-name>, so you never touch anyone
# else's stacks in a shared account. Lowercase letters, digits and hyphens, 3-31 characters.
# The scripts refuse to run with the default "inquiry-agent".
export PROJECT_NAME="inq-change-me"

# Owner tag added to every resource that supports tags (as well as Project=<PROJECT_NAME>).
# Many shared accounts require one. Example: OWNER_TAG_KEY="Jane_Doe", OWNER_TAG_VALUE="jane@example.com".
export OWNER_TAG_KEY="<Your_Name>"
export OWNER_TAG_VALUE="<you@example.com>"

# Optional: a permissions boundary for every IAM role the sample creates. Leave empty if your
# account does not require one.
export PERMISSIONS_BOUNDARY_ARN=""

# Must be unique within the Region, e.g. ${PROJECT_NAME}-<digits>.
export COGNITO_DOMAIN_PREFIX="${PROJECT_NAME}-change-me"

# Claude Sonnet 5.5 through the US cross-Region inference profile.
export MODEL_ID="us.anthropic.claude-sonnet-5-5"

export FOUNDATION_STACK="${PROJECT_NAME}-foundation"
export KNOWLEDGE_STACK="${PROJECT_NAME}-knowledge"
export MCP_STACK="${PROJECT_NAME}-mcp-servers"
export AGENT_STACK="${PROJECT_NAME}-agent"
export LISTENER_STACK="${PROJECT_NAME}-listener"
