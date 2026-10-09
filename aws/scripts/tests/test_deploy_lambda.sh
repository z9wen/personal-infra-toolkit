#!/usr/bin/env bash
#
# Tests deploy_lambda.sh against stub aws/terraform/curl commands, so the
# CodeDeploy control flow is verified without an AWS account.

set -euo pipefail

test_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="${test_directory}/../deploy_lambda.sh"

work_dir="$(mktemp -d)"
trap 'rm -rf "${work_dir}"' EXIT
stub_bin="${work_dir}/bin"
mkdir -p "${stub_bin}"

cat >"${stub_bin}/terraform" <<'STUB'
#!/usr/bin/env bash
cat <<JSON
{
  "function_name": {"value": "demo-api"},
  "alias_name": {"value": "live"},
  "function_version": {"value": "${TARGET_VERSION}"},
  "codedeploy_application": {"value": "demo"},
  "codedeploy_deployment_group": {"value": "demo-live"},
  "api_url": {"value": "https://example.invalid/"}
}
JSON
STUB

# Statuses returned by get-deployment are consumed one line at a time from
# STATUS_FILE; every call is appended to CALLS_FILE.
cat >"${stub_bin}/aws" <<'STUB'
#!/usr/bin/env bash
echo "aws $*" >>"${CALLS_FILE}"
case "$1 $2" in
    "lambda get-alias") echo "${CURRENT_VERSION}" ;;
    "deploy create-deployment") echo "d-TEST123" ;;
    "deploy get-deployment")
        if [[ $* == *"deploymentInfo.status"* ]]; then
            head -n 1 "${STATUS_FILE}"
            tail -n +2 "${STATUS_FILE}" >"${STATUS_FILE}.next"
            mv "${STATUS_FILE}.next" "${STATUS_FILE}"
        else
            echo '{"status": "Failed"}'
        fi
        ;;
    *) echo "unexpected aws call: $*" >&2; exit 1 ;;
esac
STUB

cat >"${stub_bin}/curl" <<'STUB'
#!/usr/bin/env bash
echo '{"status": "ok", "version": "'"${TARGET_VERSION}"'"}'
STUB

cat >"${stub_bin}/sleep" <<'STUB'
#!/usr/bin/env bash
:
STUB

chmod +x "${stub_bin}"/*

export PATH="${stub_bin}:${PATH}"
export CALLS_FILE="${work_dir}/calls"
export STATUS_FILE="${work_dir}/statuses"

run_deploy() {
    : >"${CALLS_FILE}"
    printf '%s\n' "$@" >"${STATUS_FILE}"
    bash "${script}" "${work_dir}" >"${work_dir}/output" 2>&1
}

fail() {
    echo "FAIL: $*" >&2
    cat "${work_dir}/output" >&2
    exit 1
}

# Alias already on the target version: no deployment is created.
export CURRENT_VERSION=3 TARGET_VERSION=3
run_deploy || fail "no-op deploy should succeed"
grep -q "create-deployment" "${CALLS_FILE}" && fail "no-op deploy must not create a deployment"

# Canary progresses and succeeds; the AppSpec moves 3 -> 4.
export CURRENT_VERSION=3 TARGET_VERSION=4
run_deploy InProgress InProgress Succeeded || fail "successful deployment should exit 0"
grep -q '\\"CurrentVersion\\":\\"3\\"' "${CALLS_FILE}" || fail "AppSpec must carry CurrentVersion 3"
grep -q '\\"TargetVersion\\":\\"4\\"' "${CALLS_FILE}" || fail "AppSpec must carry TargetVersion 4"
grep -q "v4=" "${work_dir}/output" || fail "canary traffic should be summarised by version"

# An alarm-triggered rollback must fail the pipeline.
if run_deploy InProgress Stopped; then
    fail "rolled-back deployment must exit non-zero"
fi
grep -q "shifted traffic back to version 3" "${work_dir}/output" || fail "rollback should be reported"

echo "deploy_lambda tests passed"
