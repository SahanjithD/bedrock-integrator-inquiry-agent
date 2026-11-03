#!/usr/bin/env bash
# Copy to scripts/env.sh and edit. scripts/env.sh is ignored by git.

export AWS_REGION="us-east-1"
export PROJECT_NAME="inquiry-agent"

# Must be globally unique within the Region, e.g. inquiry-agent-<your-initials>-<digits>.
export COGNITO_DOMAIN_PREFIX="inquiry-agent-change-me"

# Claude Sonnet 5.5 through the US cross-Region inference profile.
export MODEL_ID="us.anthropic.claude-sonnet-5-5"

export FOUNDATION_STACK="${PROJECT_NAME}-foundation"
export DISPATCHER_STACK="${PROJECT_NAME}-dispatcher"
