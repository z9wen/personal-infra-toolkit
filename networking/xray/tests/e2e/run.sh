#!/usr/bin/env bash
#
# End-to-end test of the Xray installer in Docker. Downloads (and verifies)
# the latest stable and pre-release Xray cores, then for each one generates
# a full config with the installer's functions and checks every protocol
# against every core: config compatibility across upgrades and rollbacks.
#
# Usage: run.sh [version...]    (default: latest stable and latest pre-release)
# Requires: docker, curl, jq, unzip, sha256sum or shasum

set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
src=$(cd "${here}/../../src" && pwd)
cache=${XRAY_E2E_CACHE:-${TMPDIR:-/tmp}/xray-e2e-cache}

case "$(uname -m)" in
    arm64 | aarch64) asset=Xray-linux-arm64-v8a platform=linux/arm64 ;;
    *) asset=Xray-linux-64 platform=linux/amd64 ;;
esac

versions=("$@")
if ((${#versions[@]} == 0)); then
    api=https://api.github.com/repos/XTLS/Xray-core/releases
    versions=(
        "$(curl -fsSL "${api}/latest" | jq -r .tag_name)"
        "$(curl -fsSL "${api}?per_page=30" | jq -r 'first(.[] | select(.prerelease)).tag_name')"
    )
fi

sha256() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1"; else shasum -a 256 "$1"; fi | awk '{print $1}'
}

for version in "${versions[@]}"; do
    dir="${cache}/linux-${version}"
    [[ -x "${dir}/xray" ]] && continue
    mkdir -p "${dir}"
    url="https://github.com/XTLS/Xray-core/releases/download/${version}/${asset}.zip"
    curl -fsSL -o "${dir}/core.zip" "${url}"
    expected=$(curl -fsSL "${url}.dgst" | awk -F'= ' '/256=/ {print $2; exit}')
    [[ "$(sha256 "${dir}/core.zip")" == "${expected}" ]] || {
        echo "SHA256 mismatch for ${version}" >&2
        exit 1
    }
    unzip -oq "${dir}/core.zip" xray -d "${dir}"
done

failed=0
for generator in "${versions[@]}"; do
    docker run --rm --platform "${platform}" \
        -v "${cache}:/bins:ro" -v "${src}:/src:ro" -v "${here}/inside.sh:/inside.sh:ro" \
        debian:bookworm-slim timeout 600 bash /inside.sh "${generator}" "${versions[@]}" | tee "${cache}/last-${generator}.log"
    grep -qE "FAILED|failed" "${cache}/last-${generator}.log" && failed=1
done
# Port hopping needs real nftables and a separate network namespace, hence
# a privileged container. The newest version is the server.
docker run --rm --privileged --platform "${platform}" \
    -v "${cache}:/bins:ro" -v "${src}:/src:ro" -v "${here}/port-hopping.sh:/port-hopping.sh:ro" \
    debian:bookworm-slim timeout 600 bash /port-hopping.sh "${versions[${#versions[@]} - 1]}" "${versions[@]}" | tee "${cache}/last-port-hopping.log"
grep -qE "FAILED|failed" "${cache}/last-port-hopping.log" && failed=1

((failed == 0)) && echo "xray e2e passed" || {
    echo "xray e2e FAILED" >&2
    exit 1
}
