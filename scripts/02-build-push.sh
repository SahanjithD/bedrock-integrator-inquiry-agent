#!/usr/bin/env bash
# Step 2: build the four ARM64 images (AgentCore Runtime runs ARM64) and push them to ECR.
source "$(dirname "$0")/lib.sh"
require aws docker
need InquiryAgentRepositoryUri ReservationMcpRepositoryUri LoyaltyMcpRepositoryUri PaymentMcpRepositoryUri

tag="$(git -C "${REPO_ROOT}" rev-parse --short HEAD 2>/dev/null || date +%Y%m%d%H%M%S)-$(date +%s)"
registry="${InquiryAgentRepositoryUri%%/*}"

log "Logging in to ${registry}"
aws ecr get-login-password | docker login --username AWS --password-stdin "${registry}"

build_and_push() {
    local key="$1" repository="$2" context="$3"
    local image="${repository}:${tag}"
    log "Building ${image}"
    docker buildx build --platform linux/arm64 --provenance=false -t "${image}" --push "${context}"
    save "${key}" "${image}"
}

build_and_push InquiryAgentImage "${InquiryAgentRepositoryUri}" "${REPO_ROOT}/inquiry-agent"
build_and_push ReservationMcpImage "${ReservationMcpRepositoryUri}" "${REPO_ROOT}/mcp-servers/reservation"
build_and_push LoyaltyMcpImage "${LoyaltyMcpRepositoryUri}" "${REPO_ROOT}/mcp-servers/loyalty"
build_and_push PaymentMcpImage "${PaymentMcpRepositoryUri}" "${REPO_ROOT}/mcp-servers/payment"
log "Images pushed with tag ${tag}"
