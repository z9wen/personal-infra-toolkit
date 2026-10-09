#!/usr/bin/env bash
#
# Extra-port management must only ever touch the files of the ports it was
# given. A previous version deleted every file matching "*${port}*", so a
# trailing comma (empty port) wiped the whole config directory.

# Globals are shared with the sourced modules, which ShellCheck cannot see.
# shellcheck disable=SC2034,SC2154

set -euo pipefail

testDirectory=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "${testDirectory}/../src/01_common.sh"
source "${testDirectory}/../src/12_operations.sh"

temporaryDirectory=$(mktemp -d /tmp/xray-core-ports-test.XXXXXX)
trap 'rm -rf "${temporaryDirectory}"' EXIT
configPath="${temporaryDirectory}/"
hysteria2Port=
customPort=

echoContent() { :; }

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

for port in 0 65536 08 abc "" "1 2"; do
    isValidPort "${port}" && fail "isValidPort accepted '${port}'"
done
for port in 1 443 65535; do
    isValidPort "${port}" || fail "isValidPort rejected '${port}'"
done

parseCorePortList "2053,2083,,2053, 2087," || fail "trailing and empty items should be ignored"
[[ "${corePortList[*]}" == "2053 2083 2087" ]] || fail "unexpected port list: ${corePortList[*]}"
parseCorePortList "2053,abc" && fail "invalid items must reject the whole input"
parseCorePortList " , " && fail "input without ports must be rejected"

# Unrelated files whose names contain short port numbers must survive.
for file in 09_routing.json 05_hysteria2_inbounds.json relay_1700000000_95_outbound.json; do
    echo '{}' >"${configPath}${file}"
done

applyCorePorts "2083" 9 5 2083 || fail "applyCorePorts failed"
for file in 09_routing.json 05_hysteria2_inbounds.json relay_1700000000_95_outbound.json; do
    [[ -f "${configPath}${file}" ]] || fail "${file} was deleted"
done
jq -e '.inbounds[0].port == 9 and .inbounds[0].settings.port == 443' \
    "${configPath}02_dokodemodoor_inbounds_9.json" >/dev/null || fail "port 9 inbound is wrong"
[[ -f "${configPath}02_dokodemodoor_inbounds_2083_default.json" ]] || fail "default marker missing"

# Choosing a new default demotes the old one instead of deleting it.
applyCorePorts "9" 9 || fail "re-applying port 9 failed"
[[ -f "${configPath}02_dokodemodoor_inbounds_2083.json" ]] || fail "old default port was lost"
[[ -f "${configPath}02_dokodemodoor_inbounds_9_default.json" ]] || fail "new default marker missing"
[[ ! -f "${configPath}02_dokodemodoor_inbounds_9.json" ]] || fail "port 9 has two inbound files"

[[ "$(listCorePorts | awk '{print $1}' | tr '\n' ' ')" == "5 9 2083 " ]] || fail "listCorePorts is wrong"

echo "core port tests passed"
