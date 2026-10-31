downloadGeoData() {
    local releaseVersion=$1 destinationDir=$2 fileName stagingDir
    mkdir -p "${destinationDir}"
    stagingDir=$(mktemp -d /tmp/xray-agent-geo.XXXXXX) || return 1
    for fileName in geosite.dat geoip.dat; do
        local url="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/download/${releaseVersion}/${fileName}"
        if ! downloadVerifiedFile "${url}" "${stagingDir}/${fileName}" "${url}.sha256sum"; then
            echoContent red " ---> ${fileName} 下载或校验失败"
            rm -rf "${stagingDir}"
            return 1
        fi
    done
    mv -f "${stagingDir}/geosite.dat" "${stagingDir}/geoip.dat" "${destinationDir%/}/"
    rmdir "${stagingDir}"
}
# Cron job to update the geo files
installCronUpdateGeo() {
    if [[ "${coreInstallType}" == "1" ]]; then
        if crontab -l | grep -q "UpdateGeo"; then
            echoContent red "\n ---> 已添加自动更新定时任务，请不要重复添加"
            exit 0
        fi
        echoContent skyBlue "\n进度 1/1 : 添加定时更新geo文件"
        crontab -l >/opt/xray-agent/backup_crontab.cron
        echo "35 1 * * * /bin/bash /opt/xray-agent/install.sh UpdateGeo >> /opt/xray-agent/crontab_tls.log 2>&1" >>/opt/xray-agent/backup_crontab.cron
        crontab /opt/xray-agent/backup_crontab.cron
        echoContent green "\n ---> 添加定时更新geo文件成功"
    fi
}

# True when version $1 >= $2 (a leading "v" is ignored).
xrayVersionAtLeast() {
    local currentVersion=${1#v}
    local requiredVersion=${2#v}
    [[ -n "${currentVersion}" && -n "${requiredVersion}" ]] || return 1
    [[ "$(printf '%s\n%s\n' "${requiredVersion}" "${currentVersion}" | sort -V | head -n 1)" == "${requiredVersion}" ]]
}

# Install xray
installXray() {
    readInstallType

    echoContent skyBlue "\n进度  $1/${totalProgress} : 安装Xray"

    if [[ ! -f "/opt/xray-agent/xray/xray" ]]; then

        # A fresh install uses the latest stable release; pre-releases are
        # chosen afterwards in version management.
        version=$(latestStableXray)
        if [[ -z "${version}" ]]; then
            echoContent red " ---> 无法获取 Xray-core 最新正式版版本号"
            return 1
        fi
        echoContent green " ---> Xray-core版本:${version}"
        installXrayVersion "${version}" --no-restart || return 1

        version=$(curl -fsSL --retry 3 https://api.github.com/repos/Loyalsoldier/v2ray-rules-dat/releases?per_page=1 | jq -r '.[]|.tag_name')
        echoContent skyBlue "------------------------Version-------------------------------"
        echo "version:${version}"
        downloadGeoData "${version}" "/opt/xray-agent/xray" || return 1
    elif [[ -z "${lastInstallationConfig}" ]]; then
        echoContent green " ---> Xray-core版本:$(installedXrayVersion)"
        read -r -p "是否更新、升级？[y/n]:" reInstallXrayStatus
        if [[ "${reInstallXrayStatus}" == "y" ]]; then
            updateXray stable
        fi
    fi
}

# xray version management
xrayVersionManageMenu() {
    echoContent skyBlue "\n进度  $1/${totalProgress} : Xray版本管理"
    if [[ "${coreInstallType}" != "1" ]]; then
        echoContent red " ---> 没有检测到安装目录，请执行脚本安装内容"
        exit 0
    fi
    echoContent red "\n=============================================================="
    echoContent yellow "1.升级Xray-core"
    echoContent yellow "2.升级Xray-core 预览版"
    echoContent yellow "3.切换到指定版本(回退)"
    echoContent yellow "4.关闭Xray-core"
    echoContent yellow "5.打开Xray-core"
    echoContent yellow "6.重启Xray-core"
    echoContent yellow "7.更新geosite、geoip"
    echoContent yellow "8.设置自动更新geo文件[每天凌晨更新]"
    echoContent yellow "9.查看日志"
    echoContent red "=============================================================="
    read -r -p "请选择:" selectXrayType
    if [[ "${selectXrayType}" == "1" ]]; then
        updateXray stable
    elif [[ "${selectXrayType}" == "2" ]]; then
        updateXray prerelease
    elif [[ "${selectXrayType}" == "3" ]]; then
        rollbackXray
    elif [[ "${selectXrayType}" == "4" ]]; then
        handleXray stop
    elif [[ "${selectXrayType}" == "5" ]]; then
        handleXray start
    elif [[ "${selectXrayType}" == "6" ]]; then
        restartXray || return 1
    elif [[ "${selectXrayType}" == "7" ]]; then
        updateGeoSite
    elif [[ "${selectXrayType}" == "8" ]]; then
        installCronUpdateGeo
    elif [[ "${selectXrayType}" == "9" ]]; then
        checkLog 1
    fi
}

# Update geosite
updateGeoSite() {
    echoContent yellow "\n来源 https://github.com/Loyalsoldier/v2ray-rules-dat"

    version=$(curl -fsSL --retry 3 https://api.github.com/repos/Loyalsoldier/v2ray-rules-dat/releases?per_page=1 | jq -r '.[]|.tag_name')
    echoContent skyBlue "------------------------Version-------------------------------"
    echo "version:${version}"
    downloadGeoData "${version}" "${configPath}../" || return 1

    restartXray || return 1
    echoContent green " ---> 更新完毕"

}

xrayReleasesApi="https://api.github.com/repos/XTLS/Xray-core/releases"

# Installed core version as a release tag (e.g. v26.3.27), empty if none.
installedXrayVersion() {
    local version
    version=$("${xrayBinary}" version 2>/dev/null | awk 'NR == 1 {print $2}')
    [[ -n "${version}" ]] && echo "v${version}"
}

# Latest stable release. /releases/latest never returns a pre-release, unlike
# the first page of /releases, which has been all pre-releases since v26.3.27.
latestStableXray() {
    curl -fsSL --retry 3 --max-time 30 "${xrayReleasesApi}/latest" | jq -r '.tag_name // empty'
}

# Print "<tag> <stable|prerelease>" for recent releases, newest first.
listXrayReleases() {
    local limit=${1:-10}
    curl -fsSL --retry 3 --max-time 30 "${xrayReleasesApi}?per_page=100" \
        | jq -r --argjson limit "${limit}" '
            [.[] | select(.draft == false)] | .[:$limit][] |
            .tag_name + " " + (if .prerelease then "prerelease" else "stable" end)'
}

# Newest pre-release, or the latest stable when that is newer, so "upgrade to
# pre-release" never downgrades.
latestPrereleaseXray() {
    local prerelease stable
    prerelease=$(listXrayReleases 100 | awk '$2 == "prerelease" {print $1; exit}')
    stable=$(latestStableXray)
    if [[ -n "${stable}" ]] && { [[ -z "${prerelease}" ]] || xrayVersionAtLeast "${stable}" "${prerelease}"; }; then
        echo "${stable}"
    else
        echo "${prerelease}"
    fi
}

# Download, verify and switch to an Xray-core release.
#
# Only the binary is replaced: the release archive also contains the stock
# geoip/geosite files, which would overwrite the Loyalsoldier data in use.
# Before switching, the new binary must accept the current config
# (`xray run -test`); after switching, the previous binary is restored if the
# service does not stay up.
#
# Usage: installXrayVersion <tag> [--no-restart]
installXrayVersion() {
    local version=$1 noRestart=${2:-} stagingDir url output
    url="https://github.com/XTLS/Xray-core/releases/download/${version}/${xrayCoreCPUVendor}.zip"
    stagingDir=$(mktemp -d /tmp/xray-core-update.XXXXXX) || return 1

    if ! downloadVerifiedFile "${url}" "${stagingDir}/core.zip" "${url}.dgst" \
        || ! unzip -oq "${stagingDir}/core.zip" xray -d "${stagingDir}" || [[ ! -s "${stagingDir}/xray" ]]; then
        echoContent red " ---> Xray-core ${version} 下载或校验失败，保留当前版本"
        rm -rf "${stagingDir}"
        return 1
    fi
    chmod 755 "${stagingDir}/xray"

    normalizeHysteria2UserField
    if compgen -G "${configPath}*.json" >/dev/null; then
        if ! output=$("${stagingDir}/xray" run -test -confdir "${configPath}" 2>&1); then
            echoContent red " ---> Xray-core ${version} 不接受当前配置，已保留当前版本"
            echoContent yellow "$(echo "${output}" | grep -iE 'fail|error' | tail -3)"
            rm -rf "${stagingDir}"
            return 1
        fi
    fi

    mkdir -p "$(dirname "${xrayBinary}")"
    [[ -f "${xrayBinary}" ]] && cp -p "${xrayBinary}" "${stagingDir}/xray.previous"
    cp -p "${stagingDir}/xray" "${xrayBinary}.new" && mv -f "${xrayBinary}.new" "${xrayBinary}" || {
        rm -rf "${stagingDir}"
        return 1
    }

    if [[ "${noRestart}" != "--no-restart" ]] && ! restartXray; then
        if [[ -f "${stagingDir}/xray.previous" ]]; then
            echoContent yellow " ---> ${version} 未能保持运行，正在恢复之前的版本"
            mv -f "${stagingDir}/xray.previous" "${xrayBinary}"
            restartXray
        fi
        rm -rf "${stagingDir}"
        return 1
    fi
    rm -rf "${stagingDir}"
    echoContent green " ---> Xray-core 已切换到 ${version}"
}

# Since v26.9.8, REALITY servers reject Client Hellos without an
# X25519MLKEM768 key share (XTLS/REALITY 8cdf7bf, not configurable). Xray
# clients send it; some non-Xray clients do not.
warnRealityClientChange() {
    local from=$1 to=$2
    [[ -f "${configPath}07_VLESS_vision_reality_inbounds.json" ]] || return 0
    if xrayVersionAtLeast "${to}" "v26.9.8" && ! xrayVersionAtLeast "${from:-v0}" "v26.9.8"; then
        echoContent yellow " ---> 注意: v26.9.8 起 REALITY 只接受带 X25519MLKEM768 的客户端，Xray 内核客户端不受影响，sing-box/Clash Meta 客户端可能无法连接 REALITY"
    fi
}

# Usage: updateXray [stable|prerelease|<tag>]
updateXray() {
    local target=${1:-stable} current version confirm
    current=$(installedXrayVersion)
    case "${target}" in
        stable) version=$(latestStableXray) ;;
        prerelease) version=$(latestPrereleaseXray) ;;
        *) version=${target} ;;
    esac
    if [[ -z "${version}" ]]; then
        echoContent red " ---> 无法获取 Xray-core 版本信息（GitHub API 可能限流），请稍后重试"
        return 1
    fi

    echoContent green " ---> 当前版本: ${current:-未安装}  目标版本: ${version}"
    warnRealityClientChange "${current}" "${version}"
    if [[ "${version}" == "${current}" ]]; then
        read -r -p "已是 ${version}，是否重新安装？[y/n]:" confirm
    else
        read -r -p "是否切换到 ${version}？[y/n]:" confirm
    fi
    if [[ "${confirm}" != "y" ]]; then
        echoContent green " ---> 已取消"
        return 0
    fi
    installXrayVersion "${version}"
}

# Pick any of the recent releases (stable or pre-release) to switch to.
rollbackXray() {
    local releases count selection version
    releases=$(listXrayReleases 10)
    count=$(grep -c . <<<"${releases}")
    if ((count == 0)); then
        echoContent red " ---> 无法获取版本列表（GitHub API 可能限流），请稍后重试"
        return 1
    fi
    echoContent yellow "\n回退的版本如果不支持当前配置，会在切换前被拒绝，当前版本保持不变"
    echoContent skyBlue "------------------------Version-------------------------------"
    awk '{printf "%d:%s %s\n", NR, $1, ($2 == "stable" ? "[正式版]" : "[预览版]")}' <<<"${releases}"
    echoContent skyBlue "--------------------------------------------------------------"
    read -r -p "请输入要切换的版本编号:" selection
    if [[ ! "${selection}" =~ ^[1-9][0-9]*$ ]] || ((selection > count)); then
        echoContent red " ---> 输入有误"
        return 1
    fi
    version=$(awk -v n="${selection}" 'NR == n {print $1}' <<<"${releases}")
    updateXray "${version}"
}

# Core management
coreVersionManageMenu() {

    if [[ -z "${coreInstallType}" ]]; then
        echoContent red "\n ---> 没有检测到安装目录，请执行脚本安装内容"
        menu
        exit 0
    fi
    # Only Xray-core is supported now; go straight to version management
    xrayVersionManageMenu 1
}
