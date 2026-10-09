#!/usr/bin/env bash
#
# Hysteria2 settings that depend on the Xray core version.

# Globals are shared with the sourced modules, which ShellCheck cannot see.
# shellcheck disable=SC2034,SC2154

set -euo pipefail

testDirectory=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
for module in 01_common 08_tls_hysteria 09_core_runtime 12_operations 19_hysteria_management; do
    # shellcheck source=/dev/null
    source "${testDirectory}/../src/${module}.sh"
done

temporaryDirectory=$(mktemp -d /tmp/xray-hysteria-test.XXXXXX)
trap 'rm -rf "${temporaryDirectory}"' EXIT
configPath="${temporaryDirectory}/conf/"
xrayBinary="${temporaryDirectory}/xray"
mkdir -p "${configPath}"

echoContent() { :; }
restartXray() { :; }
fail() {
    echo "FAIL: $*" >&2
    exit 1
}

fakeCore() {
    cat >"${xrayBinary}" <<CORE
#!/usr/bin/env bash
case "\$1" in
    version) echo "Xray $1 (Xray, Penetrates Everything.)" ;;
    run) exit 0 ;;
esac
CORE
    chmod +x "${xrayBinary}"
}

hysteriaConfig="${configPath}05_hysteria2_inbounds.json"
jq -n '{inbounds:[{protocol:"hysteria",settings:{version:2,users:[{auth:"a",email:"alice-Hysteria2"}]},
    streamSettings:{finalmask:{quicParams:{congestion:"bbr",bbrProfile:"standard"}}}}]}' >"${hysteriaConfig}"

# Stable v26.3.27 has no bbrProfile: refuse instead of pretending.
fakeCore 26.3.27
bbrProfileSupported && fail "v26.3.27 must not claim bbrProfile support"
before=$(cat "${hysteriaConfig}")
setHysteria2BbrProfile aggressive && fail "setting a profile the core ignores must fail"
[[ "$(cat "${hysteriaConfig}")" == "${before}" ]] || fail "config changed although the core ignores it"

# v26.4.13+ understands it.
fakeCore 26.9.30
bbrProfileSupported || fail "v26.9.30 supports bbrProfile"
setHysteria2BbrProfile aggressive || fail "setting the profile should succeed"
jq -e '.inbounds[0].streamSettings.finalmask.quicParams.bbrProfile == "aggressive"' "${hysteriaConfig}" >/dev/null \
    || fail "profile not written"

# "users" (ignored by stable at runtime) is converted to "clients".
normalizeHysteria2UserField
jq -e '.inbounds[0].settings | has("clients") and (has("users") | not) and .clients[0].auth == "a"' "${hysteriaConfig}" >/dev/null \
    || fail "users must become clients"

# Adding an account to a legacy "users" config also writes "clients".
jq '.inbounds[0].settings |= (.users = .clients | del(.clients))' "${hysteriaConfig}" >"${hysteriaConfig}.tmp" && mv "${hysteriaConfig}.tmp" "${hysteriaConfig}"
appendHysteria2User "${hysteriaConfig}" b bob
jq -e '.inbounds[0].settings | (.clients | map(.auth)) == ["a", "b"] and (has("users") | not)' "${hysteriaConfig}" >/dev/null \
    || fail "appendHysteria2User must keep every account under clients"

# Installation never asks for the BBR profile (stdin is closed here): new
# installs get "standard", a reinstall keeps the profile chosen in the menu.
hysteria2BbrProfile=
initHysteria2BbrProfile </dev/null
[[ "${hysteria2BbrProfile}" == standard ]] || fail "new installs default to standard"
hysteria2BbrProfile=aggressive
initHysteria2BbrProfile </dev/null
[[ "${hysteria2BbrProfile}" == aggressive ]] || fail "reinstall must keep the profile chosen in the menu"
hysteria2BbrProfile=bogus
initHysteria2BbrProfile </dev/null
[[ "${hysteria2BbrProfile}" == standard ]] || fail "invalid profiles fall back to standard"

# HTTP/3 masquerade: enabled by default (local site), "4" turns it off and
# removes the key; it can be switched back later from the menu.
nginxStaticPath=/srv/decoy/
initHysteria2Masquerade <<<"" >/dev/null
jq -e '.type == "file" and .dir == "/srv/decoy/"' <<<"${hysteria2MasqueradeConfig}" >/dev/null || fail "default masquerade is the local site"
initHysteria2Masquerade <<<"4" >/dev/null
[[ "${hysteria2MasqueradeConfig}" == null ]] || fail "option 4 turns masquerade off"

jq '.inbounds[0].streamSettings.hysteriaSettings = {version:2, masquerade:{type:"file", dir:"/www/wwwroot/panel/html/"}}' \
    "${hysteriaConfig}" >"${hysteriaConfig}.tmp" && mv "${hysteriaConfig}.tmp" "${hysteriaConfig}"
setHysteria2Masquerade <<<"4" >/dev/null || fail "turning masquerade off should succeed"
jq -e '.inbounds[0].streamSettings.hysteriaSettings | has("masquerade") | not' "${hysteriaConfig}" >/dev/null \
    || fail "disabled masquerade must remove the key"
[[ "$(describeHysteria2Masquerade)" == "未启用" ]] || fail "status should say disabled"
setHysteria2Masquerade <<<"2
v.example.com" >/dev/null || fail "switching to a redirect should succeed"
jq -e '.inbounds[0].streamSettings.hysteriaSettings.masquerade | .type == "string" and .statusCode == 301 and .headers.Location == "https://v.example.com/"' \
    "${hysteriaConfig}" >/dev/null || fail "redirect masquerade not written"

echo "hysteria tests passed"
