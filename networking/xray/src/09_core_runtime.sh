initRandomPath() {
    local chars="abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
    local initCustomPath=
    for i in {1..6}; do
        echo "${i}" >/dev/null
        initCustomPath+="${chars:RANDOM%${#chars}:1}"
    done
    customPath=${initCustomPath}
}

# Custom/random path
randomPathFunction() {
    if [[ -n $1 ]]; then
        echoContent skyBlue "\n进度  $1/${totalProgress} : 生成随机路径"
    else
        echoContent skyBlue "生成随机路径"
    fi

    # Always ask whether to reuse the previous path, regardless of lastInstallationConfig
    if [[ -n "${currentPath}" ]]; then
        echo
        read -r -p "读取到上次安装记录，是否使用上次安装时的path路径 ？[y/n]:" historyPathStatus
        echo
    fi

    if [[ "${historyPathStatus}" == "y" ]]; then
        customPath=${currentPath}
        echoContent green " ---> 使用成功\n"
    else
        echoContent yellow "请输入自定义路径[例: alone]，不需要斜杠，[回车]随机路径"
        read -r -p '路径:' customPath
        if [[ -z "${customPath}" ]]; then
            initRandomPath
            currentPath=${customPath}
        else
            currentPath=${customPath}
        fi
    fi
    echoContent yellow "\n path:${currentPath}"
    echoContent skyBlue "\n----------------------------"
}
# Random number
randomNum() {
    shuf -i "$1"-"$2" -n 1
}

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

deployNginxTemplate() {
    local templateNumber=$1 stagingDir archive backupDir
    [[ -n "${nginxStaticPath}" && "${nginxStaticPath}" != "/" ]] || return 1
    stagingDir=$(mktemp -d /tmp/xray-agent-site.XXXXXX) || return 1
    archive="${stagingDir}/site.zip"

    if ! downloadFile "https://raw.githubusercontent.com/mack-a/v2ray-agent/master/fodder/blog/unable/html${templateNumber}.zip" "${archive}" || ! unzip -tq "${archive}" >/dev/null 2>&1; then
        rm -rf "${stagingDir}"
        echoContent red " ---> 伪装站下载或压缩包校验失败，保留现有站点"
        return 1
    fi
    unzip -oq "${archive}" -d "${stagingDir}/content" || {
        rm -rf "${stagingDir}"
        return 1
    }
    rm -f "${archive}"
    [[ -n $(find "${stagingDir}/content" -mindepth 1 -print -quit 2>/dev/null) ]] || {
        rm -rf "${stagingDir}"
        return 1
    }

    mkdir -p "${nginxStaticPath}"
    backupDir=$(mktemp -d /tmp/xray-agent-site-backup.XXXXXX) || {
        rm -rf "${stagingDir}"
        return 1
    }
    cp -a "${nginxStaticPath}/." "${backupDir}/" 2>/dev/null || true
    find "${nginxStaticPath}" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
    if ! cp -a "${stagingDir}/content/." "${nginxStaticPath}/"; then
        find "${nginxStaticPath}" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
        cp -a "${backupDir}/." "${nginxStaticPath}/" 2>/dev/null || true
        rm -rf "${stagingDir}" "${backupDir}"
        echoContent red " ---> 伪装站部署失败，已恢复原站点"
        return 1
    fi
    rm -rf "${stagingDir}" "${backupDir}"
}
# Nginx masquerade blog
nginxBlog() {
    if [[ -n "$1" ]]; then
        echoContent skyBlue "\n进度 $1/${totalProgress} : 添加伪装站点"
    else
        echoContent yellow "\n开始添加伪装站点"
    fi

    if [[ -d "${nginxStaticPath}" && -f "${nginxStaticPath}/check" ]]; then
        echo
        if [[ -z "${lastInstallationConfig}" ]]; then
            read -r -p "检测到安装伪装站点，是否需要重新安装[y/n]:" nginxBlogInstallStatus
        else
            nginxBlogInstallStatus="n"
        fi

        if [[ "${nginxBlogInstallStatus}" == "y" ]]; then
            randomNum=$(randomNum 1 9)
            deployNginxTemplate "${randomNum}" || return 1
            echoContent green " ---> 添加伪装站点成功"
        fi
    else
        randomNum=$(randomNum 1 9)
        deployNginxTemplate "${randomNum}" || return 1
        echoContent green " ---> 添加伪装站点成功"
    fi

}

# Modify the http_port_t port
updateSELinuxHTTPPortT() {

    $(find /usr/bin /usr/sbin | grep -w journalctl) -xe >/opt/xray-agent/nginx_error.log 2>&1

    if find /usr/bin /usr/sbin | grep -q -w semanage && find /usr/bin /usr/sbin | grep -q -w getenforce && grep -E "31300|31302" </opt/xray-agent/nginx_error.log | grep -q "Permission denied"; then
        echoContent red " ---> 检查SELinux端口是否开放"
        if ! $(find /usr/bin /usr/sbin | grep -w semanage) port -l | grep http_port | grep -q 31300; then
            $(find /usr/bin /usr/sbin | grep -w semanage) port -a -t http_port_t -p tcp 31300
            echoContent green " ---> http_port_t 31300 端口开放成功"
        fi

        if ! $(find /usr/bin /usr/sbin | grep -w semanage) port -l | grep http_port | grep -q 31302; then
            $(find /usr/bin /usr/sbin | grep -w semanage) port -a -t http_port_t -p tcp 31302
            echoContent green " ---> http_port_t 31302 端口开放成功"
        fi
        handleNginx start

    else
        exit 0
    fi
}

# Manage Nginx
handleNginx() {
    # Detect how Nginx is managed
    local nginxCtl=""

    # Check for BT Panel/1Panel first
    if [[ -n "${btDomain}" ]] || [[ -n $(pgrep -f "BT-Panel") ]] || [[ -f "/etc/init.d/nginx" ]]; then
        if [[ -f "/etc/init.d/nginx" ]]; then
            nginxCtl="/etc/init.d/nginx"
        elif [[ -f "/www/server/nginx/sbin/nginx" ]]; then
            nginxCtl="/www/server/nginx/sbin/nginx"
        fi
    fi

    # If not BT Panel, check systemd
    if [[ -z "${nginxCtl}" ]] && systemctl list-unit-files | grep -q "nginx.service"; then
        nginxCtl="systemctl"
    fi

    # Start Nginx
    if { [[ -z "${selectCustomInstallType}" ]] || selectionNeedsTLS "${selectCustomInstallType}"; } \
        && [[ -z $(pgrep -f "nginx") ]] && [[ "$1" == "start" ]]; then
        # Validate the config syntax
        local nginxTestResult=
        if [[ "${nginxCtl}" == "/www/server/nginx/sbin/nginx" ]]; then
            nginxTestResult=$(/www/server/nginx/sbin/nginx -t -c /www/server/nginx/conf/nginx.conf 2>&1)
        else
            nginxTestResult=$(nginx -t 2>&1)
        fi
        if ! echo "${nginxTestResult}" | grep -q "successful"; then
            echoContent red " ---> Nginx配置验证失败，请检查配置"
            echo "${nginxTestResult}" | tee /opt/xray-agent/nginx_error.log
            return 1
        fi
        if [[ "${nginxCtl}" == "systemctl" ]]; then
            systemctl start nginx 2>/opt/xray-agent/nginx_error.log
        elif [[ "${nginxCtl}" == "/etc/init.d/nginx" ]]; then
            /etc/init.d/nginx start 2>/opt/xray-agent/nginx_error.log
        elif [[ "${nginxCtl}" == "/www/server/nginx/sbin/nginx" ]]; then
            /www/server/nginx/sbin/nginx -c /www/server/nginx/conf/nginx.conf 2>/opt/xray-agent/nginx_error.log
        else
            nginx 2>/opt/xray-agent/nginx_error.log
        fi

        sleep 0.5

        if [[ -z $(pgrep -f "nginx") ]]; then
            echoContent red " ---> Nginx启动失败"
            echoContent red " ---> 请将下方日志反馈给开发者"
            cat /opt/xray-agent/nginx_error.log 2>/dev/null
            if grep -q "journalctl -xe" </opt/xray-agent/nginx_error.log; then
                updateSELinuxHTTPPortT
            fi
        else
            echoContent green " ---> Nginx启动成功"
        fi

    # Stop Nginx
    elif [[ -n $(pgrep -x nginx) ]] && [[ "$1" == "stop" ]]; then
        if [[ "${nginxCtl}" == "systemctl" ]]; then
            systemctl stop nginx 2>/dev/null
        elif [[ "${nginxCtl}" == "/etc/init.d/nginx" ]]; then
            /etc/init.d/nginx stop 2>/dev/null
        elif [[ "${nginxCtl}" == "/www/server/nginx/sbin/nginx" ]]; then
            /www/server/nginx/sbin/nginx -s stop 2>/dev/null
        fi

        local nginxStopWait=0
        while [[ -n $(pgrep -x nginx) && ${nginxStopWait} -lt 10 ]]; do
            sleep 1
            ((nginxStopWait++)) || true
        done

        if [[ -z $(pgrep -x nginx) ]]; then
            echoContent green " ---> Nginx关闭成功"
        elif [[ -z ${btDomain} ]]; then
            echoContent red " ---> Nginx未能正常停止，已保留进程以免强制中断现有网站"
            return 1
        else
            echoContent yellow " ---> Nginx关闭完成（宝塔/1Panel管理）"
        fi
    fi
}

# Cron job to renew the TLS certificate
installCronTLS() {
    if [[ -z "${btDomain}" ]]; then
        echoContent skyBlue "\n进度 $1/${totalProgress} : 添加定时维护证书"
        if [[ "${acmeManagedCertSelected}" == "true" || -f "/opt/xray-agent/tls/acme_managed.conf" ]]; then
            echoContent green " ---> 证书由 acme.sh 管理，保留 acme.sh 原有续期任务"
            echoContent green " ---> 续期部署完成后会自动重载 Xray"
            return 0
        fi
        crontab -l >/opt/xray-agent/backup_crontab.cron 2>/dev/null || true
        local historyCrontab
        historyCrontab=$(sed '/xray-agent-renew-tls/d;/xray-agent\/install.sh RenewTLS/d' /opt/xray-agent/backup_crontab.cron)
        echo "${historyCrontab}" >/opt/xray-agent/backup_crontab.cron
        echo "30 1 * * * /bin/bash /opt/xray-agent/install.sh RenewTLS >> /opt/xray-agent/crontab_tls.log 2>&1 # xray-agent-renew-tls" >>/opt/xray-agent/backup_crontab.cron
        crontab /opt/xray-agent/backup_crontab.cron
        echoContent green "\n ---> 添加定时维护证书成功"
    fi
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

# Renew the certificate
renewalTLS() {

    if [[ -n $1 ]]; then
        echoContent skyBlue "\n进度  $1/1 : 更新证书"
    fi

    if [[ -f "/opt/xray-agent/tls/acme_managed.conf" ]]; then
        local managedAcmeHome=
        managedAcmeHome=$(awk -F= '$1 == "ACME_HOME" {sub(/^ACME_HOME=/, ""); print; exit}' /opt/xray-agent/tls/acme_managed.conf)
        if [[ -x "${managedAcmeHome}/acme.sh" ]]; then
            echoContent green " ---> 使用 acme.sh 原有配置检查并续期证书"
            "${managedAcmeHome}/acme.sh" --cron --home "${managedAcmeHome}"
            echoContent green " ---> acme.sh 证书维护完成"
            return 0
        fi
        echoContent red " ---> 找不到已登记的 acme.sh: ${managedAcmeHome}/acme.sh"
        return 1
    fi

    readAcmeTLS
    local domain=${currentHost}
    if [[ -z "${currentHost}" && -n "${tlsDomain}" ]]; then
        domain=${tlsDomain}
    fi

    if [[ -d "$HOME/.acme.sh/${domain}_ecc" && -f "$HOME/.acme.sh/${domain}_ecc/${domain}.key" && -f "$HOME/.acme.sh/${domain}_ecc/${domain}.cer" ]] || [[ "${installedDNSAPIStatus}" == "true" ]]; then
        modifyTime=

        if [[ "${installedDNSAPIStatus}" == "true" ]]; then
            modifyTime=$(stat --format=%z "${dnsTLSAcmeCertPath}")
        else
            modifyTime=$(stat --format=%z "$HOME/.acme.sh/${domain}_ecc/${domain}.cer")
        fi

        modifyTime=$(date +%s -d "${modifyTime}")
        currentTime=$(date +%s)
        ((stampDiff = currentTime - modifyTime))
        ((days = stampDiff / 86400))
        ((remainingDays = sslRenewalDays - days))

        tlsStatus=${remainingDays}
        if [[ ${remainingDays} -le 0 ]]; then
            tlsStatus="已过期"
        fi

        echoContent skyBlue " ---> 证书检查日期:$(date "+%F %H:%M:%S")"
        echoContent skyBlue " ---> 证书生成日期:$(date -d @"${modifyTime}" +"%F %H:%M:%S")"
        echoContent skyBlue " ---> 证书生成天数:${days}"
        echoContent skyBlue " ---> 证书剩余天数:"${tlsStatus}
        echoContent skyBlue " ---> 证书过期前最后一天自动更新，如更新失败请手动更新"

        if [[ ${remainingDays} -le 1 ]]; then
            echoContent yellow " ---> 重新生成证书"
            handleNginx stop || return 1

            if [[ "${coreInstallType}" == "1" ]]; then
                handleXray stop
            fi

            sudo "$HOME/.acme.sh/acme.sh" --cron --home "$HOME/.acme.sh"
            local renewalDomain="${domain}"
            if [[ "${installedDNSAPIStatus}" == "true" ]]; then
                renewalDomain="*.${dnsTLSDomain}"
            fi
            sudo "$HOME/.acme.sh/acme.sh" --install-cert -d "${renewalDomain}" --fullchain-file "/opt/xray-agent/tls/${domain}.crt" --key-file "/opt/xray-agent/tls/${domain}.key" --ecc
            # Start nginx regardless of the Xray result so the fallback site,
            # subscriptions and WS paths are not left down overnight.
            local restartStatus=0
            restartXray || restartStatus=$?
            handleNginx start
            return "${restartStatus}"
        else
            echoContent green " ---> 证书有效"
        fi
    elif [[ -f "/opt/xray-agent/tls/${tlsDomain}.crt" && -f "/opt/xray-agent/tls/${tlsDomain}.key" && -n $(cat "/opt/xray-agent/tls/${tlsDomain}.crt") ]]; then
        echoContent yellow " ---> 检测到使用自定义证书，无法执行renew操作。"
    else
        echoContent red " ---> 未安装"
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

# Hysteria2 configs written by older versions of this script on a v26.5.9+
# core use "users", which stable v26.3.27 accepts in `run -test` but ignores
# at runtime. "clients" works everywhere, so convert before switching cores.
normalizeHysteria2UserField() {
    local file="${configPath}05_hysteria2_inbounds.json" converted
    [[ -f "${file}" ]] || return 0
    jq -e '.inbounds[0].settings | has("users") and (has("clients") | not)' "${file}" >/dev/null 2>&1 || return 0
    converted=$(jq '.inbounds[0].settings |= (.clients = .users | del(.users))' "${file}") || return 1
    echo "${converted}" >"${file}.tmp.$$" && mv "${file}.tmp.$$" "${file}"
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

# Verify that the whole service is working
checkGFWStatue() {
    readInstallType
    echoContent skyBlue "\n进度 $1/${totalProgress} : 验证服务启动状态"
    if [[ "${coreInstallType}" == "1" ]] && [[ -n $(pgrep -f "xray/xray") ]]; then
        echoContent green " ---> 服务启动成功"
    else
        echoContent red " ---> 服务启动失败，请检查终端是否有日志打印"
        exit 0
    fi
}

# Enable Xray start on boot
installXrayService() {
    echoContent skyBlue "\n进度  $1/${totalProgress} : 配置Xray开机自启"
    execStart='/opt/xray-agent/xray/xray run -confdir /opt/xray-agent/xray/conf'
    if [[ -n $(find /bin /usr/bin -name "systemctl") ]]; then
        rm -rf /etc/systemd/system/xray.service
        touch /etc/systemd/system/xray.service
        cat <<EOF >/etc/systemd/system/xray.service
[Unit]
Description=Xray Service
Documentation=https://github.com/xtls
After=network.target nss-lookup.target
[Service]
User=root
ExecStart=${execStart}
Restart=on-failure
RestartPreventExitStatus=23
LimitNPROC=infinity
LimitNOFILE=infinity
[Install]
WantedBy=multi-user.target
EOF
        bootStartup "xray.service"
        echoContent green " ---> 配置Xray开机自启成功"
    fi
}

# Manage xray
handleXray() {
    if [[ -n $(find /bin /usr/bin -name "systemctl") ]] && [[ -n $(find /etc/systemd/system/ -name "xray.service") ]]; then
        if [[ -z $(pgrep -f "xray/xray") ]] && [[ "$1" == "start" ]]; then
            systemctl start xray.service
        elif [[ -n $(pgrep -f "xray/xray") ]] && [[ "$1" == "stop" ]]; then
            systemctl stop xray.service
        fi
    fi

    sleep 0.8

    if [[ "$1" == "start" ]]; then
        if [[ -n $(pgrep -f "xray/xray") ]]; then
            echoContent green " ---> Xray启动成功"
        else
            echoContent red "Xray启动失败"
            echoContent red "请手动执行以下的命令后【/opt/xray-agent/xray/xray -confdir /opt/xray-agent/xray/conf】将错误日志进行反馈"
            return 1
        fi
    elif [[ "$1" == "stop" ]]; then
        if [[ -z $(pgrep -f "xray/xray") ]]; then
            echoContent green " ---> Xray关闭成功"
        else
            echoContent red "xray关闭失败"
            echoContent red "请手动执行【ps -ef|grep -v grep|grep xray|awk '{print \$2}'|xargs kill -9】"
            return 1
        fi
    fi
}

xraySystemdServiceAvailable() {
    command -v systemctl >/dev/null 2>&1 && [[ -f /etc/systemd/system/xray.service ]]
}

# Restart Xray through systemd in one step, so the script cannot exit between
# a successful stop and the start.
#
# Success requires the service to stay up for several consecutive checks
# without systemd restarting it; with Restart=on-failure a crash-looping
# Xray is briefly "active" between crashes and would otherwise pass.
restartXray() {
    local stableChecks=0 restartsBefore restartsNow
    if xraySystemdServiceAvailable; then
        if ! systemctl restart xray.service; then
            echoContent yellow " ---> Xray 重启失败，正在尝试重新启动"
            systemctl start xray.service || {
                echoContent red " ---> Xray 服务无法启动"
                return 1
            }
        fi

        restartsBefore=$(systemctl show -p NRestarts --value xray.service 2>/dev/null)
        for _ in 1 2 3 4 5 6 7 8 9 10; do
            sleep 0.5
            restartsNow=$(systemctl show -p NRestarts --value xray.service 2>/dev/null)
            if systemctl is-active --quiet xray.service && pgrep -f "xray/xray" >/dev/null \
                && [[ "${restartsNow}" == "${restartsBefore}" ]]; then
                stableChecks=$((stableChecks + 1))
                if ((stableChecks >= 3)); then
                    echoContent green " ---> Xray重启成功"
                    return 0
                fi
            else
                stableChecks=0
                restartsBefore=${restartsNow}
            fi
        done
        echoContent red " ---> Xray重启后未保持运行"
        echoContent yellow " ---> 请执行【journalctl -u xray.service -n 50 --no-pager】查看错误"
        return 1
    fi

    handleXray stop || return 1
    handleXray start
}

xrayBinary=/opt/xray-agent/xray/xray

# Validate the complete config directory the way the service will load it.
validateXrayConfig() {
    "${xrayBinary}" run -test -confdir "${configPath}"
}

# Apply a change to the Xray configuration as one transaction.
#
# The config directory (and the relay state, which lives outside it) is
# snapshotted, the change command runs, and the result is validated with
# `xray run -test`. If the command or the validation fails, the snapshot is
# restored exactly, including removing files the change created. Restarting
# Xray is left to the caller so several changes can share one restart.
#
# Usage: applyXrayConfigChange <description> <command> [args...]
applyXrayConfigChange() {
    local description=$1 snapshot validationOutput=""
    shift
    snapshot=$(mktemp -d /tmp/xray-config-snapshot.XXXXXX) || return 1
    if ! cp -Rp "${configPath}." "${snapshot}/conf"; then
        rm -rf "${snapshot}"
        return 1
    fi
    if [[ -n "${relayStateFile:-}" && -f "${relayStateFile}" ]]; then
        cp -p "${relayStateFile}" "${snapshot}/relay_state.json"
    fi

    if "$@" && validationOutput=$(validateXrayConfig 2>&1); then
        rm -rf "${snapshot}"
        return 0
    fi

    find "${configPath}" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
    cp -Rp "${snapshot}/conf/." "${configPath}"
    if [[ -f "${snapshot}/relay_state.json" ]]; then
        cp -p "${snapshot}/relay_state.json" "${relayStateFile}"
    fi
    echoContent red " ---> ${description}失败，已恢复上一版配置"
    [[ -n "${validationOutput}" ]] && echoContent yellow "${validationOutput}"
    rm -rf "${snapshot}"
    return 1
}

# Read the Xray user data and initialize
