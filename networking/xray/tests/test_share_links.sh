#!/usr/bin/env bash
#
# Share links in account management: the per-account user filter and the
# account choice (one account, all, or a wrong number).

# Globals are shared with the sourced modules, which ShellCheck cannot see.
# shellcheck disable=SC2034,SC2154

set -euo pipefail

testDirectory=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "${testDirectory}/load_modules.sh"

temporaryDirectory=$(mktemp -d /tmp/xray-share-links-test.XXXXXX)
trap 'rm -rf "${temporaryDirectory}"' EXIT

echoContent() { :; }
fail() {
    echo "FAIL: $*" >&2
    exit 1
}

configPath="${temporaryDirectory}/conf/"
mkdir -p "${configPath}"
jq -n '{inbounds:[{protocol:"vless",tag:"VLESSTCP",port:443,streamSettings:{network:"tcp",security:"tls"},
    settings:{clients:[{id:"uuid-a",email:"alice-VLESS_TCP/TLS_Vision"},{id:"uuid-b",email:"bob-VLESS_TCP/TLS_Vision"}]}}]}' \
    >"${configPath}02_VLESS_TCP_inbounds.json"
jq -n '{inbounds:[{protocol:"hysteria",tag:"Hysteria2",port:443,streamSettings:{network:"hysteria",security:"tls"},
    settings:{version:2,clients:[{auth:"uuid-a",email:"alice-Hysteria2"}]}}]}' \
    >"${configPath}05_hysteria2_inbounds.json"

# --- users of an inbound ----------------------------------------------------
[[ $(inboundUsers "${configPath}02_VLESS_TCP_inbounds.json" | wc -l) -eq 2 ]] || fail "no filter lists every user"
[[ "$(inboundUsers "${configPath}02_VLESS_TCP_inbounds.json" uuid-b | jq -r .id)" == uuid-b ]] || fail "filter by VLESS id"
[[ "$(inboundUsers "${configPath}05_hysteria2_inbounds.json" uuid-a | jq -r .auth)" == uuid-a ]] || fail "filter by Hysteria2 auth"
[[ -z "$(inboundUsers "${configPath}05_hysteria2_inbounds.json" uuid-b)" ]] || fail "bob is not a Hysteria2 user"

# --- choosing the account ---------------------------------------------------
shownWith="unset"
showAccounts() { shownWith="$*"; }
collectAccounts
bobNumber=$(jq -r 'map(.tag) | index("bob") + 1' <<<"${discoveredAccounts}")

showAccountShareLinks <<<"${bobNumber}"
[[ "${shownWith}" == "1 uuid-b" ]] || fail "choosing bob shows only bob, got: ${shownWith}"
showAccountShareLinks <<<""
[[ "${shownWith}" == "1 " ]] || fail "enter shows every account, got: ${shownWith}"
shownWith="unset"
showAccountShareLinks <<<"3" && fail "a number past the list must fail"
showAccountShareLinks <<<"x" && fail "a non-number must fail"
[[ "${shownWith}" == unset ]] || fail "a wrong choice must not print links"

# One account: nothing to choose.
rm "${configPath}05_hysteria2_inbounds.json"
jq -n '{inbounds:[{protocol:"vless",tag:"VLESSTCP",port:443,streamSettings:{network:"tcp",security:"tls"},
    settings:{clients:[{id:"uuid-a",email:"alice-VLESS_TCP/TLS_Vision"}]}}]}' \
    >"${configPath}02_VLESS_TCP_inbounds.json"
showAccountShareLinks </dev/null
[[ "${shownWith}" == "1 " ]] || fail "a single account is shown without asking, got: ${shownWith}"

echo "share link tests passed"
