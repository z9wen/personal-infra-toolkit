#!/usr/bin/env bash
#
# End-to-end checks against a deployed URL shortener API.
#
# Usage: smoke_test.sh <api-url>
# Requires: curl, jq

set -euo pipefail

API_URL="${1:?usage: $0 <api-url>}"
API_URL="${API_URL%/}"

work_dir="$(mktemp -d)"
trap 'rm -rf "${work_dir}"' EXIT

failures=0

# request <method> <path> [json-body] -> prints the HTTP status, body in work_dir/body
request() {
    local method=$1 path=$2 body=${3:-}
    local args=(--silent --show-error --max-time 10 --output "${work_dir}/body"
        --dump-header "${work_dir}/headers" --write-out '%{http_code}' --request "${method}")
    if [[ -n ${body} ]]; then
        args+=(--header 'Content-Type: application/json' --data "${body}")
    fi
    : >"${work_dir}/body"
    : >"${work_dir}/headers"
    # On connection errors curl prints 000, which the check reports as a failure.
    curl "${args[@]}" "${API_URL}${path}" || true
}

json_field() {
    jq -r "$1 // empty" "${work_dir}/body" 2>/dev/null || true
}

check() {
    local name=$1 expected=$2 actual=$3
    if [[ ${actual} == "${expected}" ]]; then
        echo "PASS ${name}"
    else
        echo "FAIL ${name}: expected ${expected}, got ${actual}" >&2
        failures=$((failures + 1))
    fi
}

check "health returns 200" 200 "$(request GET /health)"
check "health reports ok" ok "$(json_field .status)"

target="https://example.com/smoke-test?run=$(date +%s)"
payload="$(jq -cn --arg url "${target}" '{url: $url, ttl_days: 1}')"
check "create link returns 201" 201 "$(request POST /links "${payload}")"
code="$(json_field .code)"

if [[ -n ${code} ]]; then
    check "short link redirects" 301 "$(request GET "/${code}")"
    location="$(tr -d '\r' <"${work_dir}/headers" | awk -F': ' 'tolower($1) == "location" {print $2}')"
    check "redirect target matches" "${target}" "${location}"
else
    check "create link returned a code" "a code" "nothing"
fi

check "invalid URL is rejected" 400 "$(request POST /links '{"url": "javascript:alert(1)"}')"
check "unknown code is 404" 404 "$(request GET /doesNotExist1)"

if ((failures > 0)); then
    echo "${failures} smoke test(s) failed" >&2
    exit 1
fi
echo "All smoke tests passed"
