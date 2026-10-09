# Nginx environment detection
checkNginxEnvironment() {
    local nginxBin="nginx"
    # Prefer the nginx bundled with the panel
    if [[ -f "/www/server/nginx/sbin/nginx" ]]; then
        nginxBin="/www/server/nginx/sbin/nginx"
    fi

    if command -v nginx &>/dev/null || [[ -f "/www/server/nginx/sbin/nginx" ]]; then
        echoContent skyBlue "\n========== Nginx 环境检测 ==========\n"

        # Nginx version
        local nginxVer
        nginxVer=$(${nginxBin} -v 2>&1 | awk -F'/' '{print $2}')
        echoContent green "Nginx 版本: ${nginxVer}"

        # Number of config files - uses nginxConfigPath
        local confCount
        confCount=$(find "${nginxConfigPath}" /etc/nginx/sites-enabled -name "*.conf" 2>/dev/null | wc -l)
        echoContent yellow "现有配置文件: ${confCount} 个"

        # Listening ports
        local ports
        ports=$(netstat -tlnp 2>/dev/null | grep nginx | awk '{print $4}' | awk -F':' '{print $NF}' | sort -u | tr '\n' ',' | sed 's/,$//')
        if [[ -n "${ports}" ]]; then
            echoContent yellow "监听端口: ${ports}"
        fi

        # Configured domains - uses nginxConfigPath
        local domains
        domains=$(grep -rh "server_name" "${nginxConfigPath}" /etc/nginx/sites-enabled 2>/dev/null | grep -v "server_name _" | awk '{for(i=2;i<=NF;i++)print $i}' | sed 's/;//g' | sort -u | head -5)
        if [[ -n "${domains}" ]]; then
            echoContent yellow "已配置域名:"
            echo "${domains}" | while read -r d; do
                echoContent skyBlue "  - ${d}"
            done
        fi

        echoContent skyBlue "\n====================================\n"
    fi
}

# Early panel path detection (no user input; only sets nginxConfigPath)
detectPanelNginxPath() {
    # The aaPanel/BT Panel process may not be running or may have a different name; Nginx and the vhost directory
    # are the reliable indicators of the config location.
    if [[ -x "/www/server/nginx/sbin/nginx" ]] && [[ -d "/www/server/panel/vhost/nginx" ]]; then
        nginxConfigPath="/www/server/panel/vhost/nginx/"
    elif [[ -d "/opt/1panel/apps/openresty/openresty/conf/conf.d" ]]; then
        nginxConfigPath="/opt/1panel/apps/openresty/openresty/conf/conf.d/"
    fi
}

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
# Enable start on boot
bootStartup() {
    local serviceName=$1
    systemctl daemon-reload
    systemctl enable "${serviceName}"
}
# Install Nginx
installNginxTools() {

    if [[ "${release}" == "debian" ]]; then
        sudo apt install gnupg2 ca-certificates lsb-release -y >/dev/null 2>&1
        # Use the stable release instead of mainline
        echo "deb http://nginx.org/packages/debian $(lsb_release -cs) nginx" | sudo tee /etc/apt/sources.list.d/nginx.list >/dev/null 2>&1
        echo -e "Package: *\nPin: origin nginx.org\nPin: release o=nginx\nPin-Priority: 900\n" | sudo tee /etc/apt/preferences.d/99nginx >/dev/null 2>&1
        downloadFile "https://nginx.org/keys/nginx_signing.key" "/tmp/nginx_signing.key" || return 1
        # gpg --dry-run --quiet --import --import-options import-show /tmp/nginx_signing.key
        sudo mv /tmp/nginx_signing.key /etc/apt/trusted.gpg.d/nginx_signing.asc
        sudo apt update >/dev/null 2>&1

    elif [[ "${release}" == "ubuntu" ]]; then
        sudo apt install gnupg2 ca-certificates lsb-release -y >/dev/null 2>&1
        # Use the stable release instead of mainline
        echo "deb http://nginx.org/packages/ubuntu $(lsb_release -cs) nginx" | sudo tee /etc/apt/sources.list.d/nginx.list >/dev/null 2>&1
        echo -e "Package: *\nPin: origin nginx.org\nPin: release o=nginx\nPin-Priority: 900\n" | sudo tee /etc/apt/preferences.d/99nginx >/dev/null 2>&1
        downloadFile "https://nginx.org/keys/nginx_signing.key" "/tmp/nginx_signing.key" || return 1
        # gpg --dry-run --quiet --import --import-options import-show /tmp/nginx_signing.key
        sudo mv /tmp/nginx_signing.key /etc/apt/trusted.gpg.d/nginx_signing.asc
        sudo apt update >/dev/null 2>&1

    fi
    ${installType} nginx >/dev/null 2>&1
    bootStartup nginx
}
