#!/usr/bin/env bash
#
# Hysteria2 port hopping: range validation, overlap with other UDP
# forwarders, generated nftables rules, rollback, and the install question.
# A stub `nft` records calls; nothing touches the real firewall.

# Globals are shared with the sourced modules, which ShellCheck cannot see.
# shellcheck disable=SC2034,SC2154

set -euo pipefail

testDirectory=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
for module in 01_common 19_hysteria_management; do
    # shellcheck source=/dev/null
    source "${testDirectory}/../src/${module}.sh"
done

temporaryDirectory=$(mktemp -d /tmp/xray-port-hopping-test.XXXXXX)
trap 'rm -rf "${temporaryDirectory}"' EXIT
configPath="${temporaryDirectory}/conf/"
mkdir -p "${configPath}" "${temporaryDirectory}/bin"
hysteria2PortHopFile="${temporaryDirectory}/range"
hysteria2PortHopNftFile="${temporaryDirectory}/rules.nft"
hysteria2PortHopUnit="${temporaryDirectory}/unit.service"
hysteria2Port=8443
jq -n '{inbounds:[{port:8443,protocol:"hysteria"}]}' >"${configPath}05_hysteria2_inbounds.json"

# Stub nft: records calls; "-f" fails when NFT_FAIL=1; "list" succeeds only after a load.
cat >"${temporaryDirectory}/bin/nft" <<'NFT'
#!/usr/bin/env bash
echo "nft $*" >>"${NFT_LOG}"
case "$1" in
    -f) [[ "${NFT_FAIL:-0}" == 1 ]] && exit 1; touch "${NFT_LOADED}" ;;
    delete) rm -f "${NFT_LOADED}" ;;
    list) [[ -f "${NFT_LOADED}" ]] ;;
esac
NFT
chmod +x "${temporaryDirectory}/bin/nft"
export PATH="${temporaryDirectory}/bin:${PATH}" NFT_LOG="${temporaryDirectory}/nft.log" NFT_LOADED="${temporaryDirectory}/loaded"
# Pretend systemd is absent so rules are loaded directly. CI runners boot with
# systemd, so the detection itself must be stubbed, not just systemctl.
hasSystemd() { return 1; }
systemctl() { return 1; }
echoContent() { :; }
allowedPorts=
allowPort() { allowedPorts="$1/$2"; }
fail() {
    echo "FAIL: $*" >&2
    exit 1
}

for range in 20000-50000 1-65535; do
    isValidPortRange "${range}" || fail "${range} should be valid"
done
for range in 50000-20000 20000-20000 0-100 20000-70000 20000 abc 20000-; do
    isValidPortRange "${range}" && fail "${range} should be invalid"
done

# Enabling writes the redirect and opens the range in the firewall.
enablePortHopping 20000-50000 || fail "enable should succeed"
grep -q "udp dport 20000-50000 counter redirect to :8443" "${hysteria2PortHopNftFile}" || fail "redirect rule missing"
grep -q "type nat hook prerouting priority dstnat" "${hysteria2PortHopNftFile}" || fail "must hook prerouting"
[[ "$(currentPortHopRange)" == 20000-50000 ]] || fail "range not recorded"
[[ "${allowedPorts}" == "20000:50000/udp" ]] || fail "firewall must open the UDP range (got ${allowedPorts})"

# A range covering an extra-port UDP forwarder is refused.
jq -n '{inbounds:[{port:30000,protocol:"dokodemo-door"}]}' >"${configPath}02_dokodemodoor_inbounds_hysteria_30000.json"
enablePortHopping 25000-35000 && fail "overlap with an extra port must be refused"
[[ "$(currentPortHopRange)" == 20000-50000 ]] || fail "a refused change must keep the previous range"
rm -f "${configPath}02_dokodemodoor_inbounds_hysteria_30000.json"

# A failing nft load is rolled back to the previous rules.
NFT_FAIL=1 enablePortHopping 40000-45000 && fail "a failing nft load must be reported"
grep -q "udp dport 20000-50000" "${hysteria2PortHopNftFile}" || fail "previous rules must be restored"
[[ "$(currentPortHopRange)" == 20000-50000 ]] || fail "range must stay unchanged after a failed load"

disablePortHopping
[[ -z "$(currentPortHopRange || true)" && ! -f "${hysteria2PortHopNftFile}" ]] || fail "disable must remove range and rules"

# Install question: default no; "y" + Enter takes the default range.
initHysteria2PortHopping <<<"" && [[ -z "${hysteria2PortHopRange}" ]] || fail "default answer must leave hopping off"
initHysteria2PortHopping < <(printf 'y\n\n') && [[ "${hysteria2PortHopRange}" == "${hysteria2PortHopDefaultRange}" ]] \
    || fail "y + Enter must pick the default range"
initHysteria2PortHopping < <(printf 'y\n50000-1\n30000-31000\n') && [[ "${hysteria2PortHopRange}" == 30000-31000 ]] \
    || fail "an invalid range must be asked again"
echo 20000-50000 >"${hysteria2PortHopFile}"
initHysteria2PortHopping <<<"" && [[ "${hysteria2PortHopRange}" == 20000-50000 ]] || fail "reinstall keeps the existing range by default"

echo "port hopping tests passed"
