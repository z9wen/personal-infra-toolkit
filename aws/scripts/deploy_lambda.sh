#!/usr/bin/env bash
#
# Shift the Lambda "live" alias to the version published by the last
# `terraform apply`, using a CodeDeploy canary deployment.
#
# CodeDeploy moves a slice of traffic to the new version, watches the rollback
# alarms during the bake time and either completes the shift or moves traffic
# back. This script starts the deployment, generates light traffic so the
# canary is actually exercised, and exits non-zero if the deployment fails.
#
# Usage: deploy_lambda.sh [terraform-app-dir]
# Requires: aws CLI v2, terraform, jq, curl

set -euo pipefail

TF_DIR="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../terraform/app" && pwd)}"
TIMEOUT_SECONDS="${DEPLOY_TIMEOUT_SECONDS:-1200}"
POLL_SECONDS=10

log() {
    echo "$(date -u '+%H:%M:%S') $*"
}

die() {
    log "ERROR: $*" >&2
    exit 1
}

for tool in aws terraform jq curl; do
    command -v "${tool}" >/dev/null 2>&1 || die "${tool} is required"
done

outputs="$(terraform -chdir="${TF_DIR}" output -json)"
output() {
    jq -er --arg name "$1" '.[$name].value' <<<"${outputs}"
}

function_name="$(output function_name)"
alias_name="$(output alias_name)"
target_version="$(output function_version)"
application="$(output codedeploy_application)"
deployment_group="$(output codedeploy_deployment_group)"
api_url="$(output api_url)"

current_version="$(aws lambda get-alias \
    --function-name "${function_name}" \
    --name "${alias_name}" \
    --query FunctionVersion \
    --output text)"

if [[ ${current_version} == "${target_version}" ]]; then
    log "${function_name}:${alias_name} already serves version ${target_version}; nothing to deploy"
    exit 0
fi

log "Deploying ${function_name}:${alias_name} ${current_version} -> ${target_version}"

appspec="$(jq -cn \
    --arg name "${function_name}" \
    --arg alias "${alias_name}" \
    --arg current "${current_version}" \
    --arg target "${target_version}" \
    '{version: 0.0, Resources: [{app: {Type: "AWS::Lambda::Function",
      Properties: {Name: $name, Alias: $alias, CurrentVersion: $current, TargetVersion: $target}}}]}')"

revision="$(jq -cn --arg content "${appspec}" \
    '{revisionType: "AppSpecContent", appSpecContent: {content: $content}}')"

deployment_id="$(aws deploy create-deployment \
    --application-name "${application}" \
    --deployment-group-name "${deployment_group}" \
    --revision "${revision}" \
    --description "Shift ${alias_name} to version ${target_version}" \
    --query deploymentId \
    --output text)"

log "Started CodeDeploy deployment ${deployment_id}"

# One line per /health response, recording which version answered it.
responses="$(mktemp)"
trap 'rm -f "${responses}"' EXIT
deadline=$((SECONDS + TIMEOUT_SECONDS))

while ((SECONDS < deadline)); do
    status="$(aws deploy get-deployment \
        --deployment-id "${deployment_id}" \
        --query deploymentInfo.status \
        --output text)"

    case "${status}" in
        Succeeded)
            log "Deployment succeeded; ${alias_name} now serves version ${target_version}"
            exit 0
            ;;
        Failed | Stopped)
            aws deploy get-deployment \
                --deployment-id "${deployment_id}" \
                --query 'deploymentInfo.{status: status, error: errorInformation, rollback: rollbackInfo}' \
                --output json >&2
            die "Deployment ${status}; CodeDeploy has shifted traffic back to version ${current_version}"
            ;;
    esac

    # Exercise the canary so the rollback alarms have real traffic to judge.
    for _ in 1 2 3 4 5; do
        curl -fsS --max-time 5 "${api_url%/}/health" 2>/dev/null | jq -r '"v" + .version' 2>/dev/null \
            || echo "error"
    done >>"${responses}"

    summary="$(sort "${responses}" | uniq -c | awk '{printf " %s=%s", $2, $1}')"
    log "Status: ${status}; responses by version:${summary}"
    sleep "${POLL_SECONDS}"
done

die "Timed out after ${TIMEOUT_SECONDS}s waiting for deployment ${deployment_id}"
