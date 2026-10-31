# Reliable download: retry on failure, write to a temp file, and replace the target only on success.
# Download a URL to a file atomically: the destination only appears once the
# whole body arrived and is non-empty.
# Usage: downloadFile <url> <destination> [--https-only]
# --https-only refuses plain HTTP, including on redirects.
downloadFile() {
    local url=$1 destination=$2 httpsOnly=${3:-} temporaryFile
    local -a curlProtocol=() wgetProtocol=()
    if [[ "${httpsOnly}" == "--https-only" ]]; then
        [[ "${url}" == https://* ]] || return 1
        curlProtocol=(--proto '=https' --proto-redir '=https')
        wgetProtocol=(--https-only)
    fi
    temporaryFile="${destination}.download.$$"
    mkdir -p "$(dirname "${destination}")"
    rm -f "${temporaryFile}"

    if command -v curl >/dev/null 2>&1; then
        curl --fail --location --silent --show-error --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 300 \
            ${curlProtocol[@]+"${curlProtocol[@]}"} --output "${temporaryFile}" "${url}" || {
            rm -f "${temporaryFile}"
            return 1
        }
    elif command -v wget >/dev/null 2>&1; then
        wget --tries=3 --timeout=30 ${wgetProtocol[@]+"${wgetProtocol[@]}"} -q -O "${temporaryFile}" "${url}" || {
            rm -f "${temporaryFile}"
            return 1
        }
    else
        echoContent red " ---> 缺少 curl 或 wget，无法下载文件"
        return 1
    fi

    [[ -s "${temporaryFile}" ]] || {
        rm -f "${temporaryFile}"
        return 1
    }
    mv -f "${temporaryFile}" "${destination}"
}

verifySha256() {
    local file=$1 checksumFile=$2 expected actual
    expected=$(awk -F '= ' '/256=/ {print $2; exit}' "${checksumFile}" | tr -d '\r')
    if [[ -z "${expected}" ]]; then
        expected=$(awk '{for (i=1; i<=NF; i++) if (length($i) == 64 && $i ~ /^[[:xdigit:]]+$/) {print $i; exit}}' "${checksumFile}")
    fi
    expected=$(printf '%s' "${expected}" | tr '[:upper:]' '[:lower:]')
    [[ -n "${expected}" ]] || return 1
    if command -v sha256sum >/dev/null 2>&1; then
        actual=$(sha256sum "${file}" | awk '{print $1}')
    else
        actual=$(shasum -a 256 "${file}" | awk '{print $1}')
    fi
    actual=$(printf '%s' "${actual}" | tr '[:upper:]' '[:lower:]')
    [[ "${actual}" == "${expected}" ]]
}

downloadVerifiedFile() {
    local url=$1 destination=$2 checksumUrl=$3
    local verifiedFile="${destination}.verified.$$" checksumFile="${destination}.checksum.$$"
    if ! downloadFile "${url}" "${verifiedFile}" || ! downloadFile "${checksumUrl}" "${checksumFile}"; then
        rm -f "${verifiedFile}" "${checksumFile}"
        return 1
    fi
    if ! verifySha256 "${verifiedFile}" "${checksumFile}"; then
        echoContent red " ---> SHA256 校验失败: $(basename "${destination}")"
        rm -f "${verifiedFile}" "${checksumFile}"
        return 1
    fi
    rm -f "${checksumFile}"
    mv -f "${verifiedFile}" "${destination}"
}
