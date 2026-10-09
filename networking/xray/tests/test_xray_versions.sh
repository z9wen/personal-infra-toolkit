#!/usr/bin/env bash
#
# Version management against a release list shaped like the real one in
# 2026: the latest stable (v26.3.27) is older than many pre-releases, so the
# first page of /releases contains no stable release at all.

# Globals are shared with the sourced modules, which ShellCheck cannot see.
# shellcheck disable=SC2034,SC2154

set -euo pipefail

testDirectory=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "${testDirectory}/../src/09_core_runtime.sh"

temporaryDirectory=$(mktemp -d /tmp/xray-versions-test.XXXXXX)
trap 'rm -rf "${temporaryDirectory}"' EXIT
configPath="${temporaryDirectory}/conf/"
xrayBinary="${temporaryDirectory}/bin/xray"
xrayCoreCPUVendor="Xray-linux-64"
mkdir -p "${configPath}" "${temporaryDirectory}/bin"
echo '{}' >"${configPath}00_log.json"

echoContent() { :; }
restartXray() { return "${fakeRestartStatus:-0}"; }

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

releasesJson='[{"tag_name":"v26.9.30","prerelease":true,"draft":false},
{"tag_name":"v26.9.9","prerelease":true,"draft":false},
{"tag_name":"v26.4.13","prerelease":true,"draft":false},
{"tag_name":"v26.3.27","prerelease":false,"draft":false},
{"tag_name":"v26.3.23","prerelease":true,"draft":false},
{"tag_name":"v26.2.6","prerelease":false,"draft":false}]'
latestJson='{"tag_name":"v26.3.27","prerelease":false}'

curl() {
    case "${*: -1}" in
        */releases/latest) echo "${latestJson}" ;;
        */releases\?per_page=*) echo "${releasesJson}" ;;
        *) return 22 ;;
    esac
}

# A fake core whose `run -test` result is controlled by the test.
makeFakeCore() {
    local version=$1 testExit=$2 zipFile=$3
    mkdir -p "${temporaryDirectory}/build"
    cat >"${temporaryDirectory}/build/xray" <<CORE
#!/usr/bin/env bash
case "\$1" in
    version) echo "Xray ${version#v} (Xray, Penetrates Everything.)" ;;
    run) exit ${testExit} ;;
esac
CORE
    chmod +x "${temporaryDirectory}/build/xray"
    echo "stock geodata" >"${temporaryDirectory}/build/geoip.dat"
    (cd "${temporaryDirectory}/build" && python3 -c 'import sys, zipfile
z = zipfile.ZipFile(sys.argv[1], "w")
for name in ("xray", "geoip.dat"):
    info = zipfile.ZipInfo(name); info.external_attr = 0o755 << 16
    z.writestr(info, open(name, "rb").read())
z.close()' "${zipFile}")
}
downloadVerifiedFile() { cp "${fakeArchive}" "$2"; }

[[ "$(latestStableXray)" == "v26.3.27" ]] || fail "stable must come from /releases/latest"
[[ "$(latestPrereleaseXray)" == "v26.9.30" ]] || fail "newest pre-release expected"
[[ "$(listXrayReleases 3 | tr '\n' ' ')" == "v26.9.30 prerelease v26.9.9 prerelease v26.4.13 prerelease " ]] \
    || fail "release listing is wrong"

# When the latest stable is newer than every pre-release, "upgrade to
# pre-release" must not downgrade.
releasesJson='[{"tag_name":"v26.3.27","prerelease":false,"draft":false},{"tag_name":"v26.3.23","prerelease":true,"draft":false}]'
[[ "$(latestPrereleaseXray)" == "v26.3.27" ]] || fail "pre-release older than stable must not be chosen"

# Current installation: v26.3.27 plus Loyalsoldier geodata that must survive.
makeFakeCore v26.3.27 0 "${temporaryDirectory}/old.zip"
cp "${temporaryDirectory}/build/xray" "${xrayBinary}"
echo "loyalsoldier geodata" >"${temporaryDirectory}/bin/geoip.dat"

# A new core that rejects the current config is never switched to.
makeFakeCore v26.9.30 1 "${temporaryDirectory}/bad.zip"
fakeArchive="${temporaryDirectory}/bad.zip"
installXrayVersion v26.9.30 && fail "a core that rejects the config must not be installed"
[[ "$(installedXrayVersion)" == "v26.3.27" ]] || fail "old core must stay after a rejected update"

# A core that does not stay up after restart is rolled back.
makeFakeCore v26.9.30 0 "${temporaryDirectory}/good.zip"
fakeArchive="${temporaryDirectory}/good.zip"
fakeRestartStatus=1
installXrayVersion v26.9.30 && fail "a failed restart must be reported"
[[ "$(installedXrayVersion)" == "v26.3.27" ]] || fail "previous core must be restored after a failed restart"

# A good update switches the binary and leaves geodata alone.
fakeRestartStatus=0
installXrayVersion v26.9.30 || fail "a valid update should succeed"
[[ "$(installedXrayVersion)" == "v26.9.30" ]] || fail "core was not updated"
[[ "$(cat "${temporaryDirectory}/bin/geoip.dat")" == "loyalsoldier geodata" ]] || fail "update must not replace geodata"

# The REALITY client notice only fires when crossing v26.9.8 with REALITY installed.
echo '{}' >"${configPath}07_VLESS_vision_reality_inbounds.json"
notices=0
echoContent() {
    [[ "$2" == *X25519MLKEM768* ]] && notices=$((notices + 1))
    return 0
}
warnRealityClientChange v26.3.27 v26.9.30
warnRealityClientChange v26.9.9 v26.9.30
[[ ${notices} -eq 1 ]] || fail "REALITY notice expected exactly once, got ${notices}"

echo "xray version management tests passed"
