#!/usr/bin/env bash
# Writes the IAM policies for a shared account, filled in for your prefix, account and Region:
#   .deploy/iam/deployer-core.json, deployer-compute.json, deployer-ai.json  - to deploy and clean up
#   .deploy/iam/portal.json                                                   - to run the support portal
# Give them to your account administrator to review and attach. Templates: infra/iam/.
# Set ACCOUNT_ID to render without AWS credentials.
source "$(dirname "$0")/lib.sh"

account_id="${ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text)}"
[[ "${account_id}" =~ ^[0-9]{12}$ ]] || die "Could not determine the AWS account ID (got '${account_id}')."
out_dir="${STATE_DIR}/iam"
mkdir -p "${out_dir}"

for template in "${REPO_ROOT}"/infra/iam/*.json; do
    name="$(basename "${template}")"
    rendered="$(sed \
        -e "s|__RUNTIME_PREFIX__|${RUNTIME_PREFIX}|g" \
        -e "s|__PREFIX__|${PROJECT_NAME}|g" \
        -e "s|__ACCOUNT_ID__|${account_id}|g" \
        -e "s|__REGION__|${AWS_REGION}|g" \
        "${template}")"

    # With a permissions boundary, roles may only be created (or re-bounded) with that boundary.
    if [[ "${name}" == "deployer-compute.json" && -n "${PERMISSIONS_BOUNDARY_ARN:-}" ]]; then
        rendered="$(jq --arg boundary "${PERMISSIONS_BOUNDARY_ARN}" --arg roles "arn:aws:iam::${account_id}:role/${PROJECT_NAME}-*" '
            .Statement |= map(if .Sid == "OwnRoles"
                then .Action -= ["iam:CreateRole", "iam:PutRolePermissionsBoundary", "iam:DeleteRolePermissionsBoundary"]
                else . end)
            | .Statement += [{
                Sid: "CreateRolesWithBoundary",
                Effect: "Allow",
                Action: ["iam:CreateRole", "iam:PutRolePermissionsBoundary"],
                Resource: $roles,
                Condition: {StringEquals: {"iam:PermissionsBoundary": $boundary}}
              }]' <<<"${rendered}")"
    fi

    jq . <<<"${rendered}" > "${out_dir}/${name}"
    size="$(tr -d ' \n\t' < "${out_dir}/${name}" | wc -c)"
    (( size <= 6144 )) || warn "${name} is ${size} characters, above the 6,144 limit for a managed policy."
    log "Wrote .deploy/iam/${name} (${size} characters)"
done

echo
log "Ask your account administrator to review these and attach them to the role you deploy with:"
log "  deployer-core.json, deployer-compute.json, deployer-ai.json (deploy and clean up)"
log "  portal.json (run the support portal; also needed by whoever runs it)"
