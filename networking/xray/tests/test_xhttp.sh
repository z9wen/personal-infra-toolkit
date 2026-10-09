#!/usr/bin/env bash
#
# XHTTP support: install-menu mapping, account identities, the nginx
# location and the aaPanel integration (against a fake panel tree).

# Globals are shared with the sourced modules, which ShellCheck cannot see.
# shellcheck disable=SC2034,SC2154

set -euo pipefail

testDirectory=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
for module in 01_common 07_nginx 10_xray_config 12_operations 16_install_management; do
    # shellcheck source=/dev/null
    source "${testDirectory}/../src/${module}.sh"
done

temporaryDirectory=$(mktemp -d /tmp/xray-xhttp-test.XXXXXX)
trap 'rm -rf "${temporaryDirectory}"' EXIT

echoContent() { :; }
fail() {
    echo "FAIL: $*" >&2
    exit 1
}

# --- install menu -----------------------------------------------------------
[[ "$(mapInstallMenuSelection "1,2,3")" == ",0,14,6," ]] || fail "1,2,3 should map to Vision, XHTTP+TLS, Hysteria2"
[[ "$(mapInstallMenuSelection "2")" == ",0,14," ]] || fail "XHTTP+TLS must bring Vision as the TLS front"
[[ "$(mapInstallMenuSelection "4,5")" == ",3,12," ]] || fail "REALITY protocols install without Vision"
[[ "$(mapInstallMenuSelection "5")" == ",12," ]] || fail "XHTTP+REALITY alone"
[[ "$(mapInstallMenuSelection "2,2, 2")" == ",0,14," ]] || fail "duplicates must collapse"
mapInstallMenuSelection "7" >/dev/null && fail "7 is not a menu entry"
mapInstallMenuSelection "1,,2" >/dev/null && fail "empty entries are invalid"
selectionNeedsTLS ",3,12," && fail "REALITY-only installs need no certificate"
selectionNeedsTLS ",12,14," || fail "XHTTP+TLS needs a certificate"
[[ "$(describeInstallSelection "${recommendedInstallSelection}")" == "VLESS+TCP+TLS, VLESS+XHTTP+TLS, Hysteria2+QUIC, VLESS+Reality+Vision" ]] \
    || fail "unexpected recommended description: $(describeInstallSelection "${recommendedInstallSelection}")"

# --- account identities -----------------------------------------------------
jq -e '.email == "alice-VLESS_XHTTP" and (has("flow") | not)' <<<"$(buildXrayClient 14 uuid-1 alice)" >/dev/null \
    || fail "XHTTP+TLS users carry no flow"
jq -e '.email == "alice-VLESS_XHTTP_Reality" and (has("flow") | not)' <<<"$(buildXrayClient 12 uuid-1 alice)" >/dev/null \
    || fail "XHTTP+REALITY users carry no flow"
[[ "$(normalizeXrayEmail alice-VLESS_XHTTP_Reality)" == alice ]] || fail "strip the XHTTP REALITY suffix"
[[ "$(normalizeXrayEmail alice-VLESS_XHTTP)" == alice ]] || fail "strip the XHTTP suffix"

configPath="${temporaryDirectory}/conf/"
mkdir -p "${configPath}"
jq -n '{inbounds:[{protocol:"vless",tag:"VLESSXHTTP",port:31305,streamSettings:{network:"xhttp"},settings:{clients:[]}}]}' \
    >"${configPath}14_VLESS_XHTTP_TLS_inbounds.json"
jq -n '{inbounds:[{protocol:"vless",tag:"VLESSRealityXHTTP",port:9443,streamSettings:{network:"xhttp",security:"reality"},settings:{clients:[]}}]}' \
    >"${configPath}12_VLESS_XHTTP_inbounds.json"
discoverAccountProtocols
[[ "${accountProtocolClientTypes[*]}" == "12 14" ]] || fail "account types for XHTTP inbounds: ${accountProtocolClientTypes[*]}"

# --- nginx location ---------------------------------------------------------
location=$(xhttpNginxLocation /abcxhttp)
grep -q 'location ^~ /abcxhttp/ {' <<<"${location}" || fail "location must use ^~ and a trailing slash"
grep -q "grpc_pass grpc://127.0.0.1:${xhttpInboundPort};" <<<"${location}" || fail "grpc_pass to the XHTTP inbound"
grep -q "grpc_set_header ${xhttpTrustedHeader} 1;" <<<"${location}" || fail "trusted header must be set by nginx"
grep -qF 'grpc_set_header X-Forwarded-For $proxy_add_x_forwarded_for;' <<<"${location}" || fail "X-Forwarded-For must stay literal"

# --- aaPanel integration ----------------------------------------------------
panelVhostRoot="${temporaryDirectory}/vhost"
btDomain=example.com
customPath=abc
mkdir -p "${panelVhostRoot}/nginx" "${panelVhostRoot}/rewrite"
nginxTestResult=0
nginx() { return "${nginxTestResult}"; }
systemctl() { return 1; }

# Older panels: only the rewrite (URL rewrite) file is included; our block
# must sit next to the user's own rules and leave them intact.
printf 'server {\n    include %s/rewrite/example.com.conf;\n}\n' "${panelVhostRoot}" >"${panelVhostRoot}/nginx/example.com.conf"
printf 'location / { try_files $uri $uri/ /index.php?$args; }\n' >"${panelVhostRoot}/rewrite/example.com.conf"
syncPanelXhttpLocation install || fail "install into the rewrite file"
grep -q 'try_files' "${panelVhostRoot}/rewrite/example.com.conf" || fail "user rewrite rules were lost"
grep -q 'location ^~ /abcxhttp/' "${panelVhostRoot}/rewrite/example.com.conf" || fail "XHTTP block missing"
syncPanelXhttpLocation install || fail "re-install should succeed"
[[ $(grep -c 'location ^~ /abcxhttp/' "${panelVhostRoot}/rewrite/example.com.conf") -eq 1 ]] || fail "re-install must not duplicate the block"
syncPanelXhttpLocation remove || fail "remove"
grep -q 'abcxhttp' "${panelVhostRoot}/rewrite/example.com.conf" && fail "block left behind after remove"
grep -q 'try_files' "${panelVhostRoot}/rewrite/example.com.conf" || fail "remove dropped user rules"

# A failing nginx test restores the previous file.
before=$(cat "${panelVhostRoot}/rewrite/example.com.conf")
nginxTestResult=1
syncPanelXhttpLocation install && fail "a failing nginx -t must be reported"
[[ "$(cat "${panelVhostRoot}/rewrite/example.com.conf")" == "${before}" ]] || fail "file not restored after failed nginx -t"
nginxTestResult=0

# Newer panels include a per-site extension directory: we own a file there.
printf 'server {\n    include %s/nginx/extension/example.com/*.conf;\n    include %s/rewrite/example.com.conf;\n}\n' \
    "${panelVhostRoot}" "${panelVhostRoot}" >"${panelVhostRoot}/nginx/example.com.conf"
syncPanelXhttpLocation install || fail "install into the extension directory"
[[ -f "${panelVhostRoot}/nginx/extension/example.com/xray-agent-xhttp.conf" ]] || fail "extension file missing"
grep -q 'abcxhttp' "${panelVhostRoot}/rewrite/example.com.conf" && fail "rewrite file must not be used when extension exists"
removeAllPanelXhttpLocations
[[ ! -f "${panelVhostRoot}/nginx/extension/example.com/xray-agent-xhttp.conf" ]] || fail "uninstall left the extension file"

# Without a known include, nothing in the panel is touched.
printf 'server {\n}\n' >"${panelVhostRoot}/nginx/example.com.conf"
syncPanelXhttpLocation install >/dev/null || fail "missing include should only print instructions"
[[ -z "$(find "${panelVhostRoot}/nginx/extension" -type f)" ]] || fail "unexpected file written"

echo "xhttp tests passed"
