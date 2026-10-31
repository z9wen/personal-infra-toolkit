# Initialize the installation directory
mkdirTools() {
    mkdir -p /opt/xray-agent/tls
    mkdir -p /opt/xray-agent/subscribe_local/default
    mkdir -p /opt/xray-agent/subscribe_local/clashMeta
    mkdir -p /opt/xray-agent/subscribe_local/sing-box

    mkdir -p /opt/xray-agent/subscribe_remote/default
    mkdir -p /opt/xray-agent/subscribe_remote/clashMeta

    mkdir -p /opt/xray-agent/subscribe/default
    mkdir -p /opt/xray-agent/subscribe/clashMetaProfiles
    mkdir -p /opt/xray-agent/subscribe/clashMeta

    mkdir -p /opt/xray-agent/xray/conf
    mkdir -p /opt/xray-agent/xray/reality_scan
    mkdir -p /opt/xray-agent/xray/tmp
    mkdir -p /etc/systemd/system/
    mkdir -p /tmp/xray-agent-tls/

    mkdir -p /opt/xray-agent/warp

    mkdir -p /usr/share/nginx/html/
}

# Install tool packages
installTools() {
    echoContent skyBlue "\n进度  $1/${totalProgress} : 安装工具"
    # Work around issues on certain Ubuntu systems
    if [[ "${release}" == "ubuntu" ]]; then
        dpkg --configure -a
    fi

    local packageWaitCount=0
    while pgrep -x apt >/dev/null 2>&1 || pgrep -x apt-get >/dev/null 2>&1 || pgrep -x dpkg >/dev/null 2>&1 || pgrep -x unattended-upgrade >/dev/null 2>&1; do
        if ((packageWaitCount >= 30)); then
            echoContent red " ---> 检测到其他软件包管理任务仍在运行，请等待其完成后重试"
            return 1
        fi
        ((packageWaitCount++)) || true
        sleep 2
    done

    echoContent green " ---> 检查、安装更新【新机器会很慢，如长时间无反应，请手动停止后重新执行】"

    ${upgrade} >/opt/xray-agent/install.log 2>&1
    if grep <"/opt/xray-agent/install.log" -q "changed"; then
        ${updateReleaseInfoChange} >/dev/null 2>&1
    fi

    if ! find /usr/bin /usr/sbin | grep -q -w sudo; then
        echoContent green " ---> 安装sudo"
        ${installType} sudo >/dev/null 2>&1
    fi

    if ! find /usr/bin /usr/sbin | grep -q -w wget; then
        echoContent green " ---> 安装wget"
        ${installType} wget >/dev/null 2>&1
    fi

    if ! find /usr/bin /usr/sbin | grep -q -w netfilter-persistent; then
        # Check whether UFW is installed
        if dpkg -l 2>/dev/null | grep -q "^[[:space:]]*ii[[:space:]]\+ufw" || command -v ufw &>/dev/null; then
            echoContent yellow " ---> 检测到 UFW 防火墙，跳过安装 iptables-persistent"
        else
            echoContent green " ---> 安装iptables"
            echo "iptables-persistent iptables-persistent/autosave_v4 boolean true" | sudo debconf-set-selections
            echo "iptables-persistent iptables-persistent/autosave_v6 boolean true" | sudo debconf-set-selections
            ${installType} iptables-persistent >/dev/null 2>&1
        fi
    fi

    if ! find /usr/bin /usr/sbin | grep -q -w curl; then
        echoContent green " ---> 安装curl"
        ${installType} curl >/dev/null 2>&1
    fi

    if ! find /usr/bin /usr/sbin | grep -q -w unzip; then
        echoContent green " ---> 安装unzip"
        ${installType} unzip >/dev/null 2>&1
    fi

    if ! find /usr/bin /usr/sbin | grep -q -w socat; then
        echoContent green " ---> 安装socat"
        ${installType} socat >/dev/null 2>&1
    fi

    if ! find /usr/bin /usr/sbin | grep -q -w tar; then
        echoContent green " ---> 安装tar"
        ${installType} tar >/dev/null 2>&1
    fi

    if ! find /usr/bin /usr/sbin | grep -q -w cron; then
        echoContent green " ---> 安装cron"
        ${installType} cron >/dev/null 2>&1
    fi
    if ! find /usr/bin /usr/sbin | grep -q -w jq; then
        echoContent green " ---> 安装jq"
        ${installType} jq >/dev/null 2>&1
    fi

    if ! find /usr/bin /usr/sbin | grep -q -w binutils; then
        echoContent green " ---> 安装binutils"
        ${installType} binutils >/dev/null 2>&1
    fi

    if ! find /usr/bin /usr/sbin | grep -q -w openssl; then
        echoContent green " ---> 安装openssl"
        ${installType} openssl >/dev/null 2>&1
    fi

    if ! find /usr/bin /usr/sbin | grep -q -w ping6; then
        echoContent green " ---> 安装ping6"
        ${installType} inetutils-ping >/dev/null 2>&1
    fi

    if ! find /usr/bin /usr/sbin | grep -q -w qrencode; then
        echoContent green " ---> 安装qrencode"
        ${installType} qrencode >/dev/null 2>&1
    fi

    if ! find /usr/bin /usr/sbin | grep -q -w lsb-release; then
        echoContent green " ---> 安装lsb-release"
        ${installType} lsb-release >/dev/null 2>&1
    fi

    if ! find /usr/bin /usr/sbin | grep -q -w lsof; then
        echoContent green " ---> 安装lsof"
        ${installType} lsof >/dev/null 2>&1
    fi

    if ! find /usr/bin /usr/sbin | grep -q -w dig; then
        echoContent green " ---> 安装dig"
        ${installType} dnsutils >/dev/null 2>&1
    fi

    # Detect the nginx version and offer to install/uninstall it
    if [[ -n "${selectCustomInstallType}" ]] && ! selectionNeedsTLS "${selectCustomInstallType}"; then
        echoContent green " ---> 检测到无需依赖Nginx的服务，跳过安装"
    else
        # Detect the nginx bundled with BT Panel/aaPanel (not in the system PATH, but installed)
        local panelNginxBin=""
        if [[ -f "/www/server/nginx/sbin/nginx" ]]; then
            panelNginxBin="/www/server/nginx/sbin/nginx"
        fi
        if ! command -v nginx &>/dev/null && [[ -z "${panelNginxBin}" ]]; then
            echoContent yellow " ---> 未检测到 Nginx，开始安装"
            installNginxTools
        else
            local existingConfCount
            existingConfCount=$(find "${nginxConfigPath}" /etc/nginx/sites-enabled -name "*.conf" 2>/dev/null | wc -l)

            if [[ -n "${panelNginxBin}" ]]; then
                echoContent green " ---> 检测到面板（宝塔/aaPanel）管理的 Nginx，跳过重装"
            elif [[ ${existingConfCount} -gt 0 ]]; then
                echoContent yellow "\n检测到 Nginx 已安装且有 ${existingConfCount} 个配置文件"
                echoContent skyBlue "脚本将在共存模式下运行，不会影响现有业务"
                echoContent green "提示：建议使用不同的域名避免冲突\n"
            fi
        fi
    fi

    # Check whether native ACME is used
    showNativeACMENotice

    if [[ "${nativeACMEEnabled}" != "true" ]]; then
        # Native ACME is not used; install acme.sh
        if [[ ! -d "$HOME/.acme.sh" ]] || [[ -d "$HOME/.acme.sh" && -z $(find "$HOME/.acme.sh/acme.sh") ]]; then
            echoContent green " ---> 安装acme.sh"
            local acmeInstaller="/tmp/acme-install.$$.sh"
            if ! downloadFile "https://get.acme.sh" "${acmeInstaller}"; then
                echoContent red " ---> acme.sh 安装脚本下载失败"
                return 1
            fi
            if ! sh "${acmeInstaller}" >/opt/xray-agent/tls/acme.log 2>&1; then
                rm -f "${acmeInstaller}"
                echoContent red " ---> acme.sh 安装脚本执行失败"
                tail -n 100 /opt/xray-agent/tls/acme.log
                return 1
            fi
            rm -f "${acmeInstaller}"

            if [[ ! -d "$HOME/.acme.sh" ]] || [[ -z $(find "$HOME/.acme.sh/acme.sh") ]]; then
                echoContent red "  acme安装失败--->"
                tail -n 100 /opt/xray-agent/tls/acme.log
                echoContent yellow "错误排查:"
                echoContent red "  1.获取Github文件失败，请等待Github恢复后尝试，恢复进度可查看 [https://www.githubstatus.com/]"
                echoContent red "  2.acme.sh脚本出现bug，可查看[https://github.com/acmesh-official/acme.sh] issues"
                echoContent red "  3.如纯IPv6机器，请设置NAT64,可执行下方命令，如果添加下方命令还是不可用，请尝试更换其他NAT64"
                echoContent skyBlue "  sed -i \"1i\\\nameserver 2a00:1098:2b::1\\\nnameserver 2a00:1098:2c::1\\\nnameserver 2a01:4f8:c2c:123f::1\\\nnameserver 2a01:4f9:c010:3f02::1\" /etc/resolv.conf"
                exit 0
            fi
        else
            echoContent green " ---> acme.sh 已安装"
        fi
    else
        echoContent green " ---> 使用 Native ACME 证书，跳过安装 acme.sh"
    fi
}

# Initialize a random string
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
# ==================== Installation ====================

# Custom-install menu entries and the protocol IDs they map to.
installMenuProtocols=(0 14 6 3 12 1)
installMenuLabels=(
    "VLESS+TCP+TLS Vision      [直连首选，需要域名]"
    "VLESS+XHTTP+TLS           [走443/可套CDN，需要域名]"
    "Hysteria2+QUIC            [UDP/游戏首选，需要域名]"
    "VLESS+Reality+Vision      [无需域名]"
    "VLESS+XHTTP+Reality       [无需域名]"
    "VLESS+WebSocket+TLS       [已弃用，建议改用XHTTP]"
)

# Human-readable names for a protocol ID list such as ",0,14,6,".
describeInstallSelection() {
    local index names=""
    for index in "${!installMenuProtocols[@]}"; do
        if hasProtocol "$1" "${installMenuProtocols[index]}"; then
            names+="${installMenuLabels[index]%%[[:space:]]*}, "
        fi
    done
    echo "${names%, }"
}

# Turn a menu selection such as "1,2,3" into a protocol ID list.
# Everything that needs a domain certificate (XHTTP+TLS, Hysteria2, WS) keeps
# Vision as the TLS front: certificate renewal and the nginx fallback hang
# off it. REALITY protocols can be installed on their own.
mapInstallMenuSelection() {
    local menuSelection=${1//[[:space:]]/} menuItem protocolId selection=","
    [[ "${menuSelection}" =~ ^[1-6](,[1-6])*$ ]] || return 1
    local -a menuItems=()
    IFS=',' read -r -a menuItems <<<"${menuSelection}"
    for menuItem in "${menuItems[@]}"; do
        protocolId=${installMenuProtocols[menuItem - 1]}
        hasProtocol "${selection}" "${protocolId}" || selection+="${protocolId},"
    done
    if selectionNeedsTLS "${selection}" && ! hasProtocol "${selection}" 0; then
        selection=",0${selection}"
    fi
    echo "${selection}"
}

customXrayInstall() {
    echoContent skyBlue "\n========================自选协议安装==========================="
    local index installMenuSelection
    for index in "${!installMenuLabels[@]}"; do
        echoContent yellow "$((index + 1)).${installMenuLabels[index]}"
    done
    echoContent green "提示：选择需要域名的协议时会自动包含 TLS Vision 作为证书和回落入口"
    read -r -p "请选择[多选，英文逗号分隔，例如:1,2,3]:" installMenuSelection
    installMenuSelection=${installMenuSelection//，/,}
    if ! selectCustomInstallType=$(mapInstallMenuSelection "${installMenuSelection}"); then
        echoContent red " ---> 输入不合法，请输入1-6并以逗号分隔"
        return 1
    fi
    runInstall
}

installRecommended() {
    selectCustomInstallType=${recommendedInstallSelection}
    echoContent skyBlue "\n推荐组合: $(describeInstallSelection "${selectCustomInstallType}")"
    runInstall
}

# Stop an installation after a failed step without leaving nginx (stopped
# earlier in the flow) down. Always returns 1.
abortInstall() {
    echoContent red " ---> $1，已中止安装"
    handleNginx start
    return 1
}

# Install the protocols in selectCustomInstallType.
runInstall() {
    local step=0 needsTLS=false restartStatus=0
    selectionNeedsTLS "${selectCustomInstallType}" && needsTLS=true
    totalProgress=11
    echoContent green " ---> 将安装: $(describeInstallSelection "${selectCustomInstallType}")"

    readLastInstallationConfig
    unInstallSubscribe
    if [[ "${needsTLS}" == "true" ]]; then
        checkBTPanel
        check1Panel
    fi
    installTools $((++step))

    if [[ "${needsTLS}" != "true" ]]; then
        echoContent skyBlue "\n进度  $((++step))/${totalProgress} : 仅安装 Reality，跳过域名与证书"
    elif [[ -n "${btDomain}" ]]; then
        echoContent skyBlue "\n进度  $((++step))/${totalProgress} : 检测到宝塔/aaPanel/1Panel，使用面板站点证书"
        customPortFunction
    else
        initTLSNginxConfig $((++step))
        installTLS $((++step))
    fi

    # REALITY-only installs do not use nginx; keep the host's sites up.
    if [[ "${needsTLS}" == "true" ]]; then
        handleNginx stop
    fi
    if hasProtocol "${selectCustomInstallType}" 1 || hasProtocol "${selectCustomInstallType}" 12 \
        || hasProtocol "${selectCustomInstallType}" 14; then
        randomPathFunction $((++step))
    fi
    if [[ "${needsTLS}" == "true" && -z "${btDomain}" ]]; then
        nginxBlog $((++step))
    fi

    installXray $((++step)) false || abortInstall "Xray 下载或安装失败" || return 1
    installXrayService $((++step))
    initXrayConfig custom $((++step)) || abortInstall "Xray 配置生成失败" || return 1
    syncRelayRouting || abortInstall "无法恢复中转路由" || return 1
    if hasProtocol "${selectCustomInstallType}" 6; then
        syncPortHopping
    elif [[ -n "$(currentPortHopRange)" ]]; then
        disablePortHopping
    fi

    if [[ "${needsTLS}" == "true" ]]; then
        updateRedirectNginxConf || abortInstall "无法生成Nginx配置" || return 1
        # Panel sites serve 443 themselves; XHTTP goes through a location there.
        if hasProtocol "${selectCustomInstallType}" 14; then
            if [[ -n "${btDomain}" ]]; then
                echo 443 >"${xhttpStateFile}"
            else
                echo "${port}" >"${xhttpStateFile}"
            fi
            syncPanelXhttpLocation install
        else
            syncPanelXhttpLocation remove
            rm -f "${xhttpStateFile}"
        fi
        installCronTLS $((++step))
    fi

    restartXray || restartStatus=$?
    handleNginx start
    ((restartStatus == 0)) || return 1
    if hasProtocol "${selectCustomInstallType}" 14; then
        checkPanelXhttpReachable
    fi
    checkGFWStatue $((++step))
    showAccounts $((++step))
}
