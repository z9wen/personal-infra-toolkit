#!/usr/bin/env bash

# Detection section
# -------------------------------------------------------------
# Check the OS
export LANG=en_US.UTF-8

echoContent() {
    case $1 in
        # Red
        "red")
            # shellcheck disable=SC2154
            ${echoType} "\033[31m${printN}$2 \033[0m"
            ;;
            # Sky blue
        "skyBlue")
            ${echoType} "\033[1;36m${printN}$2 \033[0m"
            ;;
            # Green
        "green")
            ${echoType} "\033[32m${printN}$2 \033[0m"
            ;;
            # White
        "white")
            ${echoType} "\033[37m${printN}$2 \033[0m"
            ;;
        "magenta")
            ${echoType} "\033[31m${printN}$2 \033[0m"
            ;;
            # Yellow
        "yellow")
            ${echoType} "\033[33m${printN}$2 \033[0m"
            ;;
    esac
}
checkSystem() {
    if { [[ -f "/etc/issue" ]] && grep -qi "debian" /etc/issue; } || { [[ -f "/proc/version" ]] && grep -qi "debian" /proc/version; } || { [[ -f "/etc/os-release" ]] && grep -qi "ID=debian" /etc/os-release; }; then
        release="debian"
        installType='apt -y install'
        upgrade="apt update"
        updateReleaseInfoChange='apt-get --allow-releaseinfo-change update'

    elif { [[ -f "/etc/issue" ]] && grep -qi "ubuntu" /etc/issue; } || { [[ -f "/proc/version" ]] && grep -qi "ubuntu" /proc/version; }; then
        release="ubuntu"
        installType='apt -y install'
        upgrade="apt update"
        updateReleaseInfoChange='apt-get --allow-releaseinfo-change update'
        if grep </etc/issue -q -i "16."; then
            release=
        fi
    fi

    if [[ -z ${release} ]]; then
        echoContent red "\n本脚本不支持此系统，请将下方日志反馈给开发者\n"
        echoContent yellow "$(cat /etc/issue)"
        echoContent yellow "$(cat /proc/version)"
        exit 0
    fi
}

# Check the CPU vendor
checkCPUVendor() {
    if [[ -n $(which uname) ]]; then
        if [[ "$(uname)" == "Linux" ]]; then
            case "$(uname -m)" in
                'amd64' | 'x86_64')
                    xrayCoreCPUVendor="Xray-linux-64"
                    warpRegCoreCPUVendor="main-linux-amd64"
                    ;;
                'armv8' | 'aarch64')
                    xrayCoreCPUVendor="Xray-linux-arm64-v8a"
                    warpRegCoreCPUVendor="main-linux-arm64"
                    ;;
                *)
                    echo "  不支持此CPU架构--->"
                    exit 1
                    ;;
            esac
        fi
    else
        echoContent red "  无法识别此CPU架构，默认amd64、x86_64--->"
        xrayCoreCPUVendor="Xray-linux-64"
    fi
}

# Protocol IDs used in selectCustomInstallType / currentInstallProtocolType,
# always written as a comma-wrapped list such as ",0,14,6,":
#   0  VLESS + TCP + TLS Vision        3  VLESS + REALITY + Vision
#   14 VLESS + XHTTP + TLS (via nginx) 12 VLESS + XHTTP + REALITY
#   6  Hysteria2                       1  VLESS + WebSocket + TLS (deprecated)

# Usage: hasProtocol <list> <id>
hasProtocol() {
    [[ "$1" == *",$2,"* ]]
}

# True when a selection needs a domain and TLS certificate; REALITY-only
# installs (3 and/or 12) do not.
selectionNeedsTLS() {
    local id
    for id in 0 1 6 14; do
        hasProtocol "$1" "${id}" && return 0
    done
    return 1
}

# "Recommended" install: Vision for direct use, XHTTP over 443/CDN, REALITY
# without a domain, Hysteria2 for games.
recommendedInstallSelection=",0,14,3,6,"

# XHTTP + TLS: nginx terminates TLS and forwards the path to this local
# inbound. nginx sets the trusted header, so Xray only believes the
# X-Forwarded-For it receives from nginx.
xhttpInboundPort=31305
xhttpTrustedHeader="X-Xray-Agent-Proxy"

# True for a decimal TCP/UDP port number 1-65535 (leading zeros rejected so
# the value can be used in file names and JSON as-is).
isValidPort() {
    [[ "$1" =~ ^[1-9][0-9]{0,4}$ ]] && (($1 <= 65535))
}

# Initialize global variables
initVar() {
    installType='apt -y install'
    upgrade="apt update"
    updateReleaseInfoChange='apt-get --allow-releaseinfo-change update'
    echoType='echo -e'

    # CPU architecture supported by the core
    xrayCoreCPUVendor=""
    warpRegCoreCPUVendor=""

    # Domain
    domain=
    # Total installation steps
    totalProgress=1

    # Xray-core installation status
    coreInstallType=

    # v2ctl Path
    ctlPath=
    # Installed protocol IDs: 0 Vision, 1 WebSocket, 3 Reality, 6 Hysteria2
    currentInstallProtocolType=

    # Front (fallback) type
    frontingType=

    # Selected custom installation mode
    selectCustomInstallType=

    # Xray-core config file path
    configPath=

    # xray-core Reality status
    realityStatus=

    # nginx subscription port
    subscribePort=

    subscribeType=

    # xray-core reality serverName publicKey
    xrayVLESSRealityServerName=
    xrayVLESSRealityPort=

    # Path in the config file
    currentPath=

    # Host in the config file
    currentHost=

    # Random path
    customPath=

    # UUID
    currentUUID=

    # clients
    currentClients=

    localIP=

    # Cron task name: RenewTLS - renew certificate, UpdateGeo - update geo files, UpdateRelay - update relay subscriptions
    cronName=$1

    # Number of retries after a failed TLS installation
    installTLSCount=

    # BT Panel domain
    btDomain=
    # nginx config file path
    nginxConfigPath=/etc/nginx/conf.d/
    nginxStaticPath=/usr/share/nginx/html/

    # SSL type
    sslType=
    # SSL email
    sslEmail=

    # Check interval in days
    sslRenewalDays=90

    # dns tls domain
    dnsTLSDomain=
    ipType=

    # Custom port
    customPort=

    # Hysteria port

    # Xray-core Hysteria2 UDP port
    hysteria2Port=
    hysteria2BbrProfile=
    hysteria2MasqueradeConfig=
    selectedHysteria2BbrProfile=

    # Reality
    realityPrivateKey=
    realityServerName=

    # wget show progress

    # warp
    reservedWarpReg=
    publicKeyWarpReg=
    addressWarpReg=
    secretKeyWarpReg=

    # Previous installation config status
    lastInstallationConfig=

    # Native ACME related
    nativeACMEEnabled=
    nativeCertPath=
    nativeKeyPath=

    # Existing certificates managed by acme.sh/acme_manage.sh
    acmeManagedCertSelected=
    acmeManagedHome=
    acmeManagedSourceDomain=
    acmeManagedEcc=

    # Auto-discovered wildcard acme.sh certificate path
    dnsTLSAcmeCertPath=

}
# Read TLS certificate details
readAcmeTLS() {
    local readAcmeDomain=
    installedDNSAPIStatus=
    dnsTLSAcmeCertPath=
    if [[ -n "${currentHost}" ]]; then
        readAcmeDomain="${currentHost}"
    fi

    if [[ -n "${domain}" ]]; then
        readAcmeDomain="${domain}"
    fi

    dnsTLSDomain=$(echo "${readAcmeDomain}" | awk -F "." '{$1="";print $0}' | sed 's/^[[:space:]]*//' | sed 's/ /./g')
    [[ -z "${dnsTLSDomain}" || ! -d "$HOME/.acme.sh" ]] && return 0

    local candidateDir candidateCert candidateKey
    while IFS= read -r candidateDir; do
        while IFS= read -r candidateCert; do
            # Directory naming differs between acme.sh versions; rely on the certificate SAN.
            if openssl x509 -in "${candidateCert}" -noout -text 2>/dev/null | grep -Fq "DNS:*.${dnsTLSDomain}"; then
                candidateKey="${candidateCert%.cer}.key"
                if [[ ! -f "${candidateKey}" ]]; then
                    candidateKey=$(find "${candidateDir}" -maxdepth 1 -type f -name '*.key' -print -quit 2>/dev/null)
                fi
                if [[ -f "${candidateKey}" ]]; then
                    installedDNSAPIStatus=true
                    dnsTLSAcmeCertPath="${candidateCert}"
                    return 0
                fi
            fi
        done < <(find "${candidateDir}" -maxdepth 1 -type f -name '*.cer' 2>/dev/null)
    done < <(find "$HOME/.acme.sh" -maxdepth 1 -type d -name "*.${dnsTLSDomain}_ecc" 2>/dev/null)
}

# Read the default custom port
readCustomPort() {
    if [[ -n "${configPath}" && -z "${realityStatus}" && "${coreInstallType}" == "1" ]]; then
        local port=
        port=$(jq -r .inbounds[0].port "${configPath}${frontingType}.json")
        if [[ "${port}" != "443" ]]; then
            customPort=${port}
        fi
    fi
}

# Read the nginx subscription port
readNginxSubscribe() {
    subscribeType="https"
    if [[ -f "${nginxConfigPath}subscribe.conf" ]]; then
        subscribePort=$(grep "listen" "${nginxConfigPath}subscribe.conf" | awk '{print $2}')
        subscribeDomain=$(grep "server_name" "${nginxConfigPath}subscribe.conf" | awk '{print $2}')
        subscribeDomain=${subscribeDomain//;/}
        if [[ -n "${currentHost}" && "${subscribeDomain}" != "${currentHost}" ]]; then
            subscribePort=
            subscribeType=
        else
            if ! grep "listen" "${nginxConfigPath}subscribe.conf" | grep -q "ssl"; then
                subscribeType="http"
            fi
        fi
    fi
}

# Detect the installation method
readInstallType() {
    coreInstallType=
    configPath=

    # 1. Check the installation directory
    if [[ -d "/opt/xray-agent" ]]; then
        if [[ -f "/opt/xray-agent/xray/xray" ]]; then
            # Detect xray-core
            if [[ -d "/opt/xray-agent/xray/conf" ]] && [[ -f "/opt/xray-agent/xray/conf/02_VLESS_TCP_inbounds.json" || -f "/opt/xray-agent/xray/conf/05_hysteria2_inbounds.json" || -f "/opt/xray-agent/xray/conf/07_VLESS_vision_reality_inbounds.json" ]]; then
                # xray-core
                configPath=/opt/xray-agent/xray/conf/
                ctlPath=/opt/xray-agent/xray/xray
                coreInstallType=1
                if [[ -f "${configPath}07_VLESS_vision_reality_inbounds.json" ]]; then
                    realityStatus=1
                fi
            fi
        fi
    fi
}

# Read the protocol types
readInstallProtocolType() {
    currentInstallProtocolType=
    frontingType=

    xrayVLESSRealityPort=
    xrayVLESSRealityServerName=

    hysteria2Port=
    xrayXhttpRealityPort=
    currentXhttpPath=

    currentRealityPrivateKey=
    currentRealityPublicKey=

    currentRealityMldsa65Seed=
    currentRealityMldsa65Verify=

    while read -r row; do
        if echo "${row}" | grep -q VLESS_TCP_inbounds; then
            currentInstallProtocolType="${currentInstallProtocolType}0,"
            frontingType=02_VLESS_TCP_inbounds
        fi
        if echo "${row}" | grep -q VLESS_WS_inbounds; then
            currentInstallProtocolType="${currentInstallProtocolType}1,"
            frontingType=03_VLESS_WS_inbounds
        fi
        if [[ "${row}" == */14_VLESS_XHTTP_TLS_inbounds ]]; then
            currentInstallProtocolType="${currentInstallProtocolType}14,"
            currentXhttpPath=$(jq -r '.inbounds[0].streamSettings.xhttpSettings.path // empty' "${row}.json")
        fi
        if [[ "${row}" == */12_VLESS_XHTTP_inbounds ]]; then
            currentInstallProtocolType="${currentInstallProtocolType}12,"
            xrayXhttpRealityPort=$(jq -r '.inbounds[0].port' "${row}.json")
            [[ -n "${currentXhttpPath}" ]] || currentXhttpPath=$(jq -r '.inbounds[0].streamSettings.xhttpSettings.path // empty' "${row}.json")
            # Both REALITY inbounds share one identity; read it from here when
            # Vision + REALITY (07_, read earlier) is not installed.
            if [[ -z "${currentRealityPublicKey}" ]]; then
                xrayVLESSRealityServerName=$(jq -r .inbounds[0].streamSettings.realitySettings.serverNames[0] "${row}.json")
                realityServerName=${xrayVLESSRealityServerName}
                realityDomainPort=$(jq -r '.inbounds[0].streamSettings.realitySettings.dest // .inbounds[0].streamSettings.realitySettings.target' "${row}.json" | awk -F '[:]' '{print $2}')
                currentRealityPublicKey=$(jq -r .inbounds[0].streamSettings.realitySettings.publicKey "${row}.json")
                currentRealityPrivateKey=$(jq -r .inbounds[0].streamSettings.realitySettings.privateKey "${row}.json")
                currentRealityMldsa65Seed=$(jq -r '.inbounds[0].streamSettings.realitySettings.mldsa65Seed // empty' "${row}.json")
                currentRealityMldsa65Verify=$(jq -r '.inbounds[0].streamSettings.realitySettings.mldsa65Verify // empty' "${row}.json")
            fi
        fi
        if echo "${row}" | grep -q hysteria2_inbounds; then
            currentInstallProtocolType="${currentInstallProtocolType}6,"
            hysteria2Port=$(jq -r .inbounds[0].port "${row}.json")
        fi
        if echo "${row}" | grep -q VLESS_vision_reality_inbounds; then
            currentInstallProtocolType="${currentInstallProtocolType}3,"
            xrayVLESSRealityServerName=$(jq -r .inbounds[0].streamSettings.realitySettings.serverNames[0] "${row}.json")
            realityServerName=${xrayVLESSRealityServerName}
            xrayVLESSRealityPort=$(jq -r .inbounds[0].port "${row}.json")

            realityDomainPort=$(jq -r .inbounds[0].streamSettings.realitySettings.dest "${row}.json" | awk -F '[:]' '{print $2}')

            currentRealityPublicKey=$(jq -r .inbounds[0].streamSettings.realitySettings.publicKey "${row}.json")
            currentRealityPrivateKey=$(jq -r .inbounds[0].streamSettings.realitySettings.privateKey "${row}.json")

            currentRealityMldsa65Seed=$(jq -r .inbounds[0].streamSettings.realitySettings.mldsa65Seed "${row}.json")
            currentRealityMldsa65Verify=$(jq -r .inbounds[0].streamSettings.realitySettings.mldsa65Verify "${row}.json")

        fi
    done < <(find ${configPath} -name "*inbounds.json" | sort | awk -F "[.]" '{print $1}')

    if [[ "${currentInstallProtocolType:0:1}" != "," ]]; then
        currentInstallProtocolType=",${currentInstallProtocolType}"
    fi
    repairRealityPublicKey
}
# Check whether BT Panel/aaPanel is installed. The panel process name is not stable across versions,
# so decide based on Nginx, the vhost directory and the panel process together.
isBTPanelEnvironment() {
    [[ -d "/www/server/panel/vhost/nginx" ]] || return 1
    [[ -x "/www/server/nginx/sbin/nginx" ]] || pgrep -f "BT-Panel|aaPanel" >/dev/null 2>&1
}

# Keep only panel sites that have a valid domain file name and a usable TLS certificate configured.
isBTPanelSiteConfig() {
    local confFile=$1
    local siteDomain=
    local certFile=
    local keyFile=

    siteDomain=$(basename "${confFile}" .conf)
    [[ "${siteDomain}" != 0.* ]] || return 1
    [[ "${siteDomain}" =~ ^([A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?\.)+[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] || return 1

    certFile=$(awk '$1 == "ssl_certificate" {gsub(/[;\"]/, "", $2); print $2; exit}' "${confFile}" 2>/dev/null)
    keyFile=$(awk '$1 == "ssl_certificate_key" {gsub(/[;\"]/, "", $2); print $2; exit}' "${confFile}" 2>/dev/null)
    certFile=${certFile:-/www/server/panel/vhost/cert/${siteDomain}/fullchain.pem}
    keyFile=${keyFile:-/www/server/panel/vhost/cert/${siteDomain}/privkey.pem}

    [[ -f "${certFile}" && -f "${keyFile}" ]]
}

checkBTPanel() {
    if isBTPanelEnvironment; then
        # Read the domain
        if [[ -d '/www/server/panel/vhost/nginx/' ]]; then
            local -a btDomains=()
            local panelConfFile=
            while IFS= read -r panelConfFile; do
                if isBTPanelSiteConfig "${panelConfFile}"; then
                    btDomains+=("$(basename "${panelConfFile}" .conf)")
                fi
            done < <(find /www/server/panel/vhost/nginx -maxdepth 1 -type f -name "*.conf" ! -name "xray-agent.conf" -print 2>/dev/null | sort)
            local btDomainCount=${#btDomains[@]}
            if ((btDomainCount == 0)); then
                echoContent yellow " ---> 未发现配置了有效TLS证书的宝塔/aaPanel网站"
                return
            fi
            local selectBTDomain=

            # If the user declines the previous config or currentHost is empty, prompt the user to choose
            if [[ "${forceSelectDomain}" == "true" ]] || [[ -z "${currentHost}" ]]; then
                echoContent skyBlue "\n读取宝塔/aaPanel配置\n"

                local displayIndex
                for ((displayIndex = 0; displayIndex < btDomainCount; displayIndex++)); do
                    local printIndex=$((displayIndex + 1))
                    echo "${printIndex}:${btDomains[displayIndex]}"
                done

                read -r -p "请输入编号选择:" selectBTDomain
                # Clear the flag once the selection is done
                forceSelectDomain=false
            else
                local displayIndex
                for ((displayIndex = 0; displayIndex < btDomainCount; displayIndex++)); do
                    if [[ "${btDomains[displayIndex]}" == "${currentHost}" ]]; then
                        selectBTDomain=$((displayIndex + 1))
                        break
                    fi
                done
                if [[ -z "${selectBTDomain}" ]]; then
                    echoContent yellow " ---> 上次域名 ${currentHost} 不在面板站点中，请重新选择"
                    for ((displayIndex = 0; displayIndex < btDomainCount; displayIndex++)); do
                        local printIndex=$((displayIndex + 1))
                        echo "${printIndex}:${btDomains[displayIndex]}"
                    done
                    read -r -p "请输入编号选择:" selectBTDomain
                fi
            fi

            if [[ -n "${selectBTDomain}" && "${selectBTDomain}" =~ ^[0-9]+$ ]]; then
                local selectedIndex=$((selectBTDomain - 1))
                if ((selectedIndex < 0 || selectedIndex >= btDomainCount)); then
                    echoContent red " ---> 选择错误，请重新选择"
                    checkBTPanel
                    return
                else
                    local selectedBTDomain=${btDomains[selectedIndex]}
                    local btConfFile="/www/server/panel/vhost/nginx/${selectedBTDomain}.conf"
                    local certFile=
                    local keyFile=
                    certFile=$(awk '$1 == "ssl_certificate" {gsub(/[;\"]/, "", $2); print $2; exit}' "${btConfFile}" 2>/dev/null)
                    keyFile=$(awk '$1 == "ssl_certificate_key" {gsub(/[;\"]/, "", $2); print $2; exit}' "${btConfFile}" 2>/dev/null)

                    if [[ -z "${certFile}" ]]; then
                        certFile="/www/server/panel/vhost/cert/${selectedBTDomain}/fullchain.pem"
                    fi
                    if [[ -z "${keyFile}" ]]; then
                        keyFile="/www/server/panel/vhost/cert/${selectedBTDomain}/privkey.pem"
                    fi

                    if [[ ! -f "${certFile}" || ! -f "${keyFile}" ]]; then
                        echoContent yellow " ---> 未找到 ${selectedBTDomain} 的面板证书，将使用普通TLS证书流程"
                        return
                    fi

                    btDomain=${selectedBTDomain}
                    domain=${btDomain}

                    mkdir -p /opt/xray-agent/tls
                    ln -sfn "${certFile}" "/opt/xray-agent/tls/${btDomain}.crt"
                    ln -sfn "${keyFile}" "/opt/xray-agent/tls/${btDomain}.key"

                    nginxStaticPath="/www/wwwroot/${btDomain}/html/"

                    mkdir -p "/www/wwwroot/${btDomain}/html/"

                    if [[ -f "/www/wwwroot/${btDomain}/.user.ini" ]]; then
                        chattr -i "/www/wwwroot/${btDomain}/.user.ini"
                    fi
                    nginxConfigPath="/www/server/panel/vhost/nginx/"
                fi
            else
                echoContent red " ---> 选择错误，请重新选择"
                checkBTPanel
                return
            fi
        fi
    fi
}
check1Panel() {
    if [[ -n $(pgrep -f "1panel") ]]; then
        # Read the domain
        if [[ -d '/opt/1panel/apps/openresty/openresty/www/sites/' && -n $(find /opt/1panel/apps/openresty/openresty/www/sites/*/ssl/fullchain.pem) ]]; then
            # If the user declines the previous config or currentHost is empty, prompt the user to choose
            if [[ "${forceSelectDomain}" == "true" ]] || [[ -z "${currentHost}" ]]; then
                echoContent skyBlue "\n读取1Panel配置\n"

                find /opt/1panel/apps/openresty/openresty/www/sites/*/ssl/fullchain.pem | awk -F "[/]" '{print $9}' | awk '{print NR""":"$0}'

                read -r -p "请输入编号选择:" selectBTDomain
                # Clear the flag once the selection is done
                forceSelectDomain=false
            else
                selectBTDomain=$(find /opt/1panel/apps/openresty/openresty/www/sites/*/ssl/fullchain.pem | awk -F "[/]" '{print $9}' | awk '{print NR""":"$0}' | grep "${currentHost}" | cut -d ":" -f 1)
            fi

            if [[ -n "${selectBTDomain}" ]]; then
                btDomain=$(find /opt/1panel/apps/openresty/openresty/www/sites/*/ssl/fullchain.pem | awk -F "[/]" '{print $9}' | awk '{print NR""":"$0}' | grep "${selectBTDomain}:" | cut -d ":" -f 2)

                if [[ -z "${btDomain}" ]]; then
                    echoContent red " ---> 选择错误，请重新选择"
                    check1Panel
                else
                    domain=${btDomain}
                    if [[ ! -f "/opt/xray-agent/tls/${btDomain}.crt" && ! -f "/opt/xray-agent/tls/${btDomain}.key" ]]; then
                        ln -s "/opt/1panel/apps/openresty/openresty/www/sites/${btDomain}/ssl/fullchain.pem" "/opt/xray-agent/tls/${btDomain}.crt"
                        ln -s "/opt/1panel/apps/openresty/openresty/www/sites/${btDomain}/ssl/privkey.pem" "/opt/xray-agent/tls/${btDomain}.key"
                    fi

                    nginxStaticPath="/opt/1panel/apps/openresty/openresty/www/sites/${btDomain}/index/"
                fi
            else
                echoContent red " ---> 选择错误，请重新选择"
                check1Panel
            fi
        fi
    fi
}
# Check the firewall
allowPort() {
    local type=$2
    if [[ -z "${type}" ]]; then
        type=tcp
    fi

    # Only let UFW handle it when it is actually enabled; if it is installed but inactive, keep checking other firewalls.
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
        if ! ufw status | grep -q "$1/${type}"; then
            ufw allow "$1/${type}"
            checkUFWAllowPort "$1"
        fi
        return
    fi

    # Check firewalld
    if systemctl status firewalld 2>/dev/null | grep -q "active (running)"; then
        local updateFirewalldStatus=
        if ! firewall-cmd --list-ports --permanent | grep -qw "$1/${type}"; then
            updateFirewalldStatus=true
            local firewallPort=$1
            if echo "${firewallPort}" | grep -q ":"; then
                firewallPort=$(echo "${firewallPort}" | awk -F ":" '{print $1"-"$2}')
            fi
            firewall-cmd --zone=public --add-port="${firewallPort}/${type}" --permanent
            checkFirewalldAllowPort "${firewallPort}"
        fi

        if echo "${updateFirewalldStatus}" | grep -q "true"; then
            firewall-cmd --reload
        fi
        return
    fi

    # Check iptables last (only when there is no other firewall)
    if dpkg -l 2>/dev/null | grep -q "^[[:space:]]*ii[[:space:]]\+netfilter-persistent"; then
        if systemctl status netfilter-persistent 2>/dev/null | grep -q "active (exited)"; then
            local updateNetfilterStatus=
            if ! iptables -C INPUT -p "${type}" --dport "$1" -j ACCEPT >/dev/null 2>&1; then
                updateNetfilterStatus=true
                iptables -I INPUT -p "${type}" --dport "$1" -m comment --comment "allow $1/${type}(z9)" -j ACCEPT
            fi

            if command -v ip6tables >/dev/null 2>&1 && ! ip6tables -C INPUT -p "${type}" --dport "$1" -j ACCEPT >/dev/null 2>&1; then
                updateNetfilterStatus=true
                ip6tables -I INPUT -p "${type}" --dport "$1" -m comment --comment "allow $1/${type}(z9)" -j ACCEPT
            fi

            if [[ "${updateNetfilterStatus}" == "true" ]]; then
                netfilter-persistent save
            fi
        fi
    fi
}
# Get the public IP
getPublicIP() {
    local type=4
    if [[ -n "$1" ]]; then
        type=$1
    fi
    if [[ -n "${currentHost}" && -z "$1" ]] && [[ "${xrayVLESSRealityServerName}" == "${currentHost}" ]]; then
        echo "${currentHost}"
    else
        local currentIP=
        currentIP=$(curl -s "-${type}" http://www.cloudflare.com/cdn-cgi/trace | grep "ip" | awk -F "[=]" '{print $2}')
        if [[ -z "${currentIP}" && -z "$1" ]]; then
            currentIP=$(curl -s "-6" http://www.cloudflare.com/cdn-cgi/trace | grep "ip" | awk -F "[=]" '{print $2}')
        fi
        echo "${currentIP}"
    fi

}

# Print the UFW port open status
checkUFWAllowPort() {
    if ufw status | grep -q "$1"; then
        echoContent green " ---> $1端口开放成功"
    else
        echoContent red " ---> $1端口开放失败"
        exit 0
    fi
}

# Print the firewall-cmd port open status
checkFirewalldAllowPort() {
    if firewall-cmd --list-ports --permanent | grep -q "$1"; then
        echoContent green " ---> $1端口开放成功"
    else
        echoContent red " ---> $1端口开放失败"
        exit 0
    fi
}
# Read the previous installation config
readLastInstallationConfig() {
    if [[ -n "${configPath}" ]]; then
        read -r -p "读取到上次安装的配置，是否使用 ？[y/n]:" lastInstallationConfigStatus
        if [[ "${lastInstallationConfigStatus}" == "y" ]]; then
            lastInstallationConfig=true
        else
            # The user declined the previous config; set the flag to force re-selection
            forceSelectDomain=true
            lastInstallationConfig=
            currentHost=
            currentPath=
            currentDefaultPort=
            btDomain=
        fi
    fi
}
# Check the file directories and the path
readConfigHostPathUUID() {
    currentPath=
    currentDefaultPort=
    currentUUID=
    currentClients=
    currentHost=
    currentPort=
    currentCDNAddress=

    if [[ "${coreInstallType}" == "1" ]]; then

        # Install
        if [[ -n "${frontingType}" ]]; then
            # Prefer reading the domain from the VLESS TCP config (it has the TLS certificate)
            if [[ -f "${configPath}02_VLESS_TCP_inbounds.json" ]]; then
                currentHost=$(jq -r .inbounds[0].streamSettings.tlsSettings.certificates[0].certificateFile ${configPath}02_VLESS_TCP_inbounds.json | awk -F '[t][l][s][/]' '{print $2}' | awk -F '[.][c][r][t]' '{print $1}')
            else
                currentHost=$(jq -r .inbounds[0].streamSettings.tlsSettings.certificates[0].certificateFile ${configPath}${frontingType}.json | awk -F '[t][l][s][/]' '{print $2}' | awk -F '[.][c][r][t]' '{print $1}')
            fi

            # Prefer reading the port from VLESS TCP (the external port)
            if [[ -f "${configPath}02_VLESS_TCP_inbounds.json" ]]; then
                currentPort=$(jq .inbounds[0].port ${configPath}02_VLESS_TCP_inbounds.json)
            else
                currentPort=$(jq .inbounds[0].port ${configPath}${frontingType}.json)
            fi

            local defaultPortFile=
            defaultPortFile=$(find ${configPath}* | grep "default")

            if [[ -n "${defaultPortFile}" ]]; then
                currentDefaultPort=$(echo "${defaultPortFile}" | awk -F [_] '{print $4}')
            elif [[ -f "${configPath}02_VLESS_TCP_inbounds.json" ]]; then
                # Prefer reading the external port from VLESS TCP
                currentDefaultPort=$(jq -r .inbounds[0].port ${configPath}02_VLESS_TCP_inbounds.json)
            else
                currentDefaultPort=$(jq -r .inbounds[0].port ${configPath}${frontingType}.json)
            fi
            currentUUID=$(jq -r .inbounds[0].settings.clients[0].id ${configPath}${frontingType}.json)
            currentClients=$(jq -r '.inbounds[0].settings.clients // []' ${configPath}${frontingType}.json)
        fi

        # reality
        if echo ${currentInstallProtocolType} | grep -q ",3,"; then

            currentClients=$(jq -r '.inbounds[0].settings.clients // []' ${configPath}07_VLESS_vision_reality_inbounds.json)
            currentUUID=$(jq -r .inbounds[0].settings.clients[0].id ${configPath}07_VLESS_vision_reality_inbounds.json)
            xrayVLESSRealityVisionPort=$(jq -r .inbounds[0].port ${configPath}07_VLESS_vision_reality_inbounds.json)
            if [[ "${currentPort}" == "${xrayVLESSRealityVisionPort}" ]]; then
                xrayVLESSRealityVisionPort="${currentDefaultPort}"
            fi
        fi

        # Hysteria2-only installations do not have a VLESS fronting config.
        if [[ -f "${configPath}05_hysteria2_inbounds.json" ]]; then
            hysteria2Port=$(jq -r '.inbounds[0].port' "${configPath}05_hysteria2_inbounds.json")
            hysteria2BbrProfile=$(jq -r '.inbounds[0].streamSettings.finalmask.quicParams.bbrProfile // "standard"' "${configPath}05_hysteria2_inbounds.json")
            if [[ -z "${currentHost}" || "${currentHost}" == "null" ]]; then
                currentHost=$(jq -r '.inbounds[0].streamSettings.tlsSettings.certificates[0].certificateFile' "${configPath}05_hysteria2_inbounds.json" | awk -F '[t][l][s][/]' '{print $2}' | awk -F '[.][c][r][t]' '{print $1}')
            fi
            if [[ -z "${currentClients}" || "${currentClients}" == "null" || "${currentClients}" == "[]" ]]; then
                currentClients=$(jq -c '[(.inbounds[0].settings.clients // .inbounds[0].settings.users // [])[] | {id: .auth, email: .email}]' "${configPath}05_hysteria2_inbounds.json")
                currentUUID=$(echo "${currentClients}" | jq -r '.[0].id // empty')
            fi
        fi
    fi

    # Read the path
    if [[ -n "${configPath}" && -n "${frontingType}" ]]; then
        if [[ "${coreInstallType}" == "1" ]]; then
            local fallback
            # Prefer reading the path from the VLESS TCP config (it has the fallbacks)
            if [[ -f "${configPath}02_VLESS_TCP_inbounds.json" ]]; then
                fallback=$(jq -r -c '.inbounds[0].settings.fallbacks[]?|select(.path)' ${configPath}02_VLESS_TCP_inbounds.json | head -1)
            else
                fallback=$(jq -r -c '.inbounds[0].settings.fallbacks[]?|select(.path)' ${configPath}${frontingType}.json | head -1)
            fi

            local path
            path=$(echo "${fallback}" | jq -r .path | awk -F "[/]" '{print $2}')

            if [[ $(echo "${fallback}" | jq -r .dest) == 31297 ]] || [[ $(echo "${fallback}" | jq -r .dest) == 31299 ]]; then
                # The path is already a bare path; no suffix to strip
                currentPath="${path}"
            fi

        fi
    fi
    # Without WebSocket, recover the shared path from an XHTTP inbound
    # ("/<path>xhttp").
    if [[ -z "${currentPath}" && -n "${currentXhttpPath}" ]]; then
        currentPath=${currentXhttpPath#/}
        currentPath=${currentPath%xhttp}
    fi
    if [[ -f "/opt/xray-agent/cdn" ]] && [[ -n "$(head -1 /opt/xray-agent/cdn)" ]]; then
        currentCDNAddress=$(head -1 /opt/xray-agent/cdn)
    else
        currentCDNAddress="${currentHost}"
    fi
}

# Status display
showInstallStatus() {
    if [[ -n "${coreInstallType}" ]]; then
        if [[ -n $(pgrep -f "xray/xray") ]]; then
            echoContent yellow "\n核心: Xray-core[运行中]"
        else
            echoContent yellow "\n核心: Xray-core[未运行]"
        fi
        # Read the protocol types
        readInstallProtocolType

        if [[ -n ${currentInstallProtocolType} ]]; then
            echoContent yellow "已安装协议: \c"
        fi
        if echo ${currentInstallProtocolType} | grep -q ",0,"; then
            echoContent yellow "VLESS+TCP[TLS_Vision] \c"
        fi

        if hasProtocol "${currentInstallProtocolType}" 1; then
            echoContent yellow "VLESS+WS[TLS,已弃用] \c"
        fi

        if hasProtocol "${currentInstallProtocolType}" 14; then
            echoContent yellow "VLESS+XHTTP[TLS] \c"
        fi
        if hasProtocol "${currentInstallProtocolType}" 6; then
            echoContent yellow "Hysteria2 \c"
        fi
        if hasProtocol "${currentInstallProtocolType}" 3; then
            echoContent yellow "VLESS+Reality+Vision \c"
        fi
        if hasProtocol "${currentInstallProtocolType}" 12; then
            echoContent yellow "VLESS+XHTTP+Reality \c"
        fi
    fi
}

# Detect native ACME clients
checkNativeACME() {
    local nativeACMEType=""

    # Detect certbot
    if command -v certbot &>/dev/null; then
        nativeACMEType="certbot"
        local certbotVersion certCount
        certbotVersion=$(certbot --version 2>&1 | head -1)
        echoContent skyBlue "\n检测到 Native ACME 客户端: ${nativeACMEType}"
        echoContent green "  版本: ${certbotVersion}"

        # Check for existing certificates
        if [[ -d "/etc/letsencrypt/live" ]]; then
            certCount=$(find /etc/letsencrypt/live -mindepth 1 -maxdepth 1 -type d | wc -l)
            if [[ ${certCount} -gt 0 ]]; then
                echoContent yellow "  已有证书数量: ${certCount}"
                echoContent skyBlue "\n可用证书域名:"
                find /etc/letsencrypt/live -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | nl
            fi
        fi
        return 0
    fi

    # Detect other ACME clients
    if command -v lego &>/dev/null; then
        nativeACMEType="lego"
        echoContent skyBlue "\n检测到 Native ACME 客户端: ${nativeACMEType}"
        return 0
    fi

    return 1
}

# Use native ACME certificates (check during initialization)
# Tell the user an existing ACME client was found. Certificate choice happens
# later, in the TLS step.
showNativeACMENotice() {
    if checkNativeACME; then
        echoContent skyBlue "\n=============================================================="
        echoContent yellow "检测到系统已安装 Native ACME 客户端"
        echoContent yellow "在安装过程中将提供使用现有证书的选项"
        echoContent red "==============================================================\n"
    fi
}

# Detect the Nginx environment and generate a report
# Detect Nginx containers in Docker
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
# Check the domain's IP via DNS
checkDNSIP() {
    local domain=$1
    local dnsIP=
    ipType=4
    dnsIP=$(dig @1.1.1.1 +time=2 +short "${domain}" | grep -E "^(([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])\.){3}([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])$")
    if [[ -z "${dnsIP}" ]]; then
        dnsIP=$(dig @8.8.8.8 +time=2 +short "${domain}" | grep -E "^(([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])\.){3}([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])$")
    fi
    if echo "${dnsIP}" | grep -q "timed out" || [[ -z "${dnsIP}" ]]; then
        echo
        echoContent red " ---> 无法通过DNS获取域名 IPv4 地址"
        echoContent green " ---> 尝试检查域名 IPv6 地址"
        dnsIP=$(dig @2606:4700:4700::1111 +time=2 aaaa +short "${domain}")
        ipType=6
        if echo "${dnsIP}" | grep -q "network unreachable" || [[ -z "${dnsIP}" ]]; then
            echoContent red " ---> 无法通过DNS获取域名IPv6地址，退出安装"
            exit 0
        fi
    fi
    local publicIP=

    publicIP=$(getPublicIP "${ipType}")
    if [[ "${publicIP}" != "${dnsIP}" ]]; then
        echoContent red " ---> 域名解析IP与当前服务器IP不一致\n"
        echoContent yellow " ---> 请检查域名解析是否生效以及正确"
        echoContent green " ---> 当前VPS IP：${publicIP}"
        echoContent green " ---> DNS解析 IP：${dnsIP}"
        exit 0
    else
        echoContent green " ---> 域名IP校验通过"
    fi
}
# Check the actual port open status
checkPortOpen() {
    local port=$1
    local domain=$2
    local checkPortOpenResult=
    local xrayWasRunning=false
    if pgrep -f "xray/xray" >/dev/null; then
        xrayWasRunning=true
        handleXray stop >/dev/null 2>&1 || return 1
    fi
    allowPort "${port}"

    if [[ -z "${btDomain}" ]]; then

        handleNginx stop
        # Initialize the nginx config
        touch ${nginxConfigPath}checkPortOpen.conf
        local listenIPv6PortConfig=

        if [[ -n $(curl -s -6 -m 4 http://www.cloudflare.com/cdn-cgi/trace | grep "ip" | cut -d "=" -f 2) ]]; then
            listenIPv6PortConfig="listen [::]:${port};"
        fi
        cat <<EOF >${nginxConfigPath}checkPortOpen.conf
server {
    listen ${port};
    ${listenIPv6PortConfig}
    server_name ${domain};
    location /checkPort {
        return 200 'fjkvymb6len';
    }
    location /ip {
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header REMOTE-HOST \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        default_type text/plain;
        return 200 \$proxy_add_x_forwarded_for;
    }
}
EOF
        handleNginx start
        # Check that the domain + port is reachable
        checkPortOpenResult=$(curl -s -m 10 "http://${domain}:${port}/checkPort")
        localIP=$(curl -s -m 10 "http://${domain}:${port}/ip")
        rm "${nginxConfigPath}checkPortOpen.conf"

        handleNginx stop
        if [[ "${checkPortOpenResult}" == "fjkvymb6len" ]]; then
            echoContent green " ---> 检测到${port}端口已开放"
        else
            echoContent green " ---> 未检测到${port}端口开放，退出安装"
            if echo "${checkPortOpenResult}" | grep -q "cloudflare"; then
                echoContent yellow " ---> 请关闭云朵后等待三分钟重新尝试"
            else
                if [[ -z "${checkPortOpenResult}" ]]; then
                    echoContent red " ---> 请检查云服务商是否启用了网页防火墙"
                    echoContent red " ---> 检查是否自己安装过nginx并且有配置冲突，可以尝试DD纯净系统后重新尝试"
                else
                    echoContent red " ---> 错误日志：${checkPortOpenResult}，请将此错误日志通过issues提交反馈"
                fi
            fi
            if [[ "${xrayWasRunning}" == "true" ]]; then
                restartXray || exit 1
            fi
            exit 0
        fi
        if [[ "${xrayWasRunning}" == "true" ]]; then
            restartXray || return 1
        fi
        checkIP "${localIP}"
    fi
}

# Initialize the Nginx config used for certificate issuance
initTLSNginxConfig() {
    handleNginx stop
    echoContent skyBlue "\n进度  $1/${totalProgress} : 初始化Nginx申请证书配置"
    if [[ -n "${currentHost}" && -z "${lastInstallationConfig}" ]]; then
        echo
        read -r -p "读取到上次安装记录，是否使用上次安装时的域名 ？[y/n]:" historyDomainStatus
        if [[ "${historyDomainStatus}" == "y" ]]; then
            domain=${currentHost}
            echoContent yellow "\n ---> 域名: ${domain}"
        else
            if ! selectLocalAcmeCertificate; then
                echo
                echoContent yellow "请输入要配置的域名 例: example.com --->"
                read -r -p "域名:" domain
            fi
        fi
    elif [[ -n "${currentHost}" && -n "${lastInstallationConfig}" ]]; then
        domain=${currentHost}
    else
        if ! selectLocalAcmeCertificate; then
            echo
            echoContent yellow "请输入要配置的域名 例: example.com --->"
            read -r -p "域名:" domain
        fi
    fi

    if [[ -z ${domain} ]]; then
        echoContent red "  域名不可为空--->"
        initTLSNginxConfig 3
    else
        # Check whether the domain is already configured in Nginx
        if grep -r "server_name.*${domain}" "${nginxConfigPath}" /etc/nginx/sites-enabled/ 2>/dev/null | grep -v "xray-agent.conf" | grep -q "${domain}"; then
            echoContent red "\n=============================================================="
            echoContent yellow "警告：检测到域名 ${domain} 已在 Nginx 中配置"
            echoContent yellow "这可能会导致配置冲突！"
            echoContent red "==============================================================\n"
            read -r -p "是否继续使用此域名（可能影响现有业务）？[y/n]:" domainConflictStatus
            if [[ "${domainConflictStatus}" != "y" ]]; then
                echoContent yellow "请使用不同的域名"
                initTLSNginxConfig 3
                return
            fi
        fi

        dnsTLSDomain=$(echo "${domain}" | awk -F "." '{$1="";print $0}' | sed 's/^[[:space:]]*//' | sed 's/ /./g')
        customPortFunction
        # Modify the config
        handleNginx stop
    fi
}

# Remove the default nginx config
removeNginxDefaultConf() {
    if [[ -f ${nginxConfigPath}default.conf ]]; then
        if [[ "$(grep -c "server_name" <${nginxConfigPath}default.conf)" == "1" ]] && [[ "$(grep -c "server_name  localhost;" <${nginxConfigPath}default.conf)" == "1" ]]; then
            echoContent green " ---> 删除Nginx默认配置"
            rm -rf ${nginxConfigPath}default.conf >/dev/null 2>&1
        fi
    fi
}
# Modify the nginx redirect config
updateRedirectNginxConf() {
    local nginxConfFile="${nginxConfigPath}xray-agent.conf"
    local nginxConfTmp="${nginxConfFile}.tmp.$$"

    if [[ ! -d "${nginxConfigPath}" ]]; then
        echoContent red " ---> Nginx配置目录不存在: ${nginxConfigPath}"
        return 1
    fi

    # Back up the existing config
    if [[ -f "${nginxConfFile}" ]]; then
        local backupFile
        backupFile="${nginxConfFile}.bak_$(date +%Y%m%d_%H%M%S)"
        cp "${nginxConfFile}" "${backupFile}"
        echoContent skyBlue " ---> 已备份原配置: ${backupFile}"
    fi

    local redirectDomain=
    redirectDomain=${domain}:${port}

    local nginxH2Conf=
    nginxH2Conf="listen 127.0.0.1:31302 http2 so_keepalive=on proxy_protocol;"
    local nginxBin="nginx"
    if [[ -f "/www/server/nginx/sbin/nginx" ]]; then
        nginxBin="/www/server/nginx/sbin/nginx"
    fi
    nginxVersion=$("${nginxBin}" -v 2>&1)

    if echo "${nginxVersion}" | grep -q "1.25" && [[ $(echo "${nginxVersion}" | awk -F "[.]" '{print $3}') -gt 0 ]] || [[ $(echo "${nginxVersion}" | awk -F "[.]" '{print $2}') -gt 25 ]]; then
        nginxH2Conf="listen 127.0.0.1:31302 so_keepalive=on proxy_protocol;http2 on;"
    fi

    local fallbackLocationConfig=
    if [[ -n "${btDomain}" ]]; then
        fallbackLocationConfig=$(printf '%s\n' \
            '        proxy_pass https://127.0.0.1:443;' \
            '        proxy_http_version 1.1;' \
            "        proxy_set_header Host ${btDomain};" \
            '        proxy_set_header X-Real-IP $remote_addr;' \
            '        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;' \
            '        proxy_set_header X-Forwarded-Proto https;' \
            '        proxy_ssl_server_name on;' \
            "        proxy_ssl_name ${btDomain};" \
            '        proxy_ssl_verify off;')
        echoContent green " ---> Vision普通HTTPS回落将反向代理到面板站点: https://${btDomain}/"
    fi

    local xhttpLocationConfig=
    if xhttpTlsEnabled; then
        xhttpLocationConfig=$(xhttpNginxLocation "$(xhttpPublicPath)" "	")
    fi

    if ! cat <<EOF >"${nginxConfTmp}"; then
    server {
    		listen 127.0.0.1:31300;
    		server_name _;
    		return 403;
    }
server {
	${nginxH2Conf}

	set_real_ip_from 127.0.0.1;
    real_ip_header proxy_protocol;

	server_name ${domain};
	root ${nginxStaticPath};

${xhttpLocationConfig}
	location / {
	${fallbackLocationConfig}
	}
}
server {
	listen 127.0.0.1:31300 proxy_protocol;
	server_name ${domain};

	set_real_ip_from 127.0.0.1;
	real_ip_header proxy_protocol;

	root ${nginxStaticPath};
${xhttpLocationConfig}
	location / {
	${fallbackLocationConfig}
	}
}
EOF
        rm -f "${nginxConfTmp}"
        echoContent red " ---> 写入Nginx配置失败: ${nginxConfFile}"
        return 1
    fi

    if ! mv "${nginxConfTmp}" "${nginxConfFile}"; then
        rm -f "${nginxConfTmp}"
        echoContent red " ---> 保存Nginx配置失败: ${nginxConfFile}"
        return 1
    fi

    echoContent green " ---> Nginx配置已写入: ${nginxConfFile}"
}
# Check the IP

# ==================== XHTTP over nginx ====================

# True when VLESS + XHTTP + TLS is being installed, or is installed and the
# current operation does not select protocols.
xhttpTlsEnabled() {
    if [[ -n "${selectCustomInstallType}" ]]; then
        hasProtocol "${selectCustomInstallType}" 14
    else
        hasProtocol "${currentInstallProtocolType}" 14
    fi
}

xhttpPublicPath() {
    echo "/${customPath:-${currentPath}}xhttp"
}

# nginx location that hands the XHTTP path to the local XHTTP inbound.
# grpc_pass speaks h2c to Xray and also serves HTTP/1.1 clients (CDNs often
# reach the origin over HTTP/1.1). "^~" keeps regex locations in panel site
# configs from taking these requests.
# Usage: xhttpNginxLocation <path> [indent]
xhttpNginxLocation() {
    local path=$1 indent=${2:-    }
    printf '%s\n' \
        "${indent}location ^~ ${path}/ {" \
        "${indent}    client_max_body_size 0;" \
        "${indent}    client_body_timeout 5m;" \
        "${indent}    grpc_read_timeout 315;" \
        "${indent}    grpc_send_timeout 5m;" \
        "${indent}    grpc_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;" \
        "${indent}    grpc_set_header ${xhttpTrustedHeader} 1;" \
        "${indent}    grpc_pass grpc://127.0.0.1:${xhttpInboundPort};" \
        "${indent}}"
}

# aaPanel/BT vhost directory (overridable for tests).
panelVhostRoot=/www/server/panel/vhost
xhttpPanelMarkerBegin="# >>> xray-agent XHTTP (managed by xray-agent, do not edit) >>>"
xhttpPanelMarkerEnd="# <<< xray-agent XHTTP <<<"
xhttpStateFile=/opt/xray-agent/xhttp_public_port

# Find a file that the panel site config already includes inside its server
# block, so our location survives the panel rewriting the site config.
# Prints "<file> own" (the whole file is ours) or "<file> block" (a marked
# block inside a user-editable file).
findPanelXhttpTarget() {
    local siteConf="${panelVhostRoot}/nginx/${btDomain}.conf"
    if [[ -f "${siteConf}" ]]; then
        if grep -qF "${panelVhostRoot}/nginx/extension/${btDomain}/*.conf" "${siteConf}"; then
            echo "${panelVhostRoot}/nginx/extension/${btDomain}/xray-agent-xhttp.conf own"
            return 0
        fi
        if grep -qF "${panelVhostRoot}/rewrite/${btDomain}.conf" "${siteConf}"; then
            echo "${panelVhostRoot}/rewrite/${btDomain}.conf block"
            return 0
        fi
    fi
    return 1
}

panelNginxTest() {
    if [[ -x /www/server/nginx/sbin/nginx ]]; then
        /www/server/nginx/sbin/nginx -t -c /www/server/nginx/conf/nginx.conf
    else
        nginx -t
    fi
}

panelNginxReload() {
    if [[ -x /www/server/nginx/sbin/nginx ]]; then
        /www/server/nginx/sbin/nginx -s reload -c /www/server/nginx/conf/nginx.conf
    elif command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet nginx; then
        systemctl reload nginx
    else
        nginx -s reload
    fi
}

# Print a file without our marked XHTTP block.
stripXhttpPanelBlock() {
    awk -v begin="${xhttpPanelMarkerBegin}" -v end="${xhttpPanelMarkerEnd}" '
        $0 == begin {skip = 1; next}
        $0 == end {skip = 0; next}
        !skip {print}
    ' "$1"
}

# Add or remove the XHTTP location in the panel site that serves 443, then
# test and reload nginx. A failed test restores the previous file.
# Usage: syncPanelXhttpLocation install|remove
syncPanelXhttpLocation() {
    local action=$1 target file mode backup
    [[ -n "${btDomain}" ]] || return 0
    if ! target=$(findPanelXhttpTarget); then
        if [[ "${action}" == "install" ]]; then
            echoContent yellow " ---> 未找到 ${btDomain} 站点配置中可安全写入的位置（面板会覆盖直接修改）"
            echoContent yellow " ---> 请在面板中把以下配置加入 ${btDomain} 的 443 server 块后重载 Nginx:"
            xhttpNginxLocation "$(xhttpPublicPath)"
        fi
        return 0
    fi
    file=${target% *}
    mode=${target##* }
    backup=$(mktemp) || return 1
    [[ -f "${file}" ]] && cp -p "${file}" "${backup}"

    if [[ "${mode}" == "own" ]]; then
        rm -f "${file}"
    elif [[ -f "${file}" ]]; then
        stripXhttpPanelBlock "${backup}" >"${file}"
    fi
    if [[ "${action}" == "install" ]]; then
        mkdir -p "$(dirname "${file}")"
        {
            echo "${xhttpPanelMarkerBegin}"
            xhttpNginxLocation "$(xhttpPublicPath)"
            echo "${xhttpPanelMarkerEnd}"
        } >>"${file}"
    fi

    local output
    if ! output=$(panelNginxTest 2>&1); then
        if [[ -s "${backup}" ]]; then cp -p "${backup}" "${file}"; else rm -f "${file}"; fi
        rm -f "${backup}"
        echoContent red " ---> 面板 Nginx 配置测试失败，已恢复: ${file}"
        echoContent yellow "$(echo "${output}" | tail -3)"
        return 1
    fi
    rm -f "${backup}"
    panelNginxReload >/dev/null 2>&1
    if [[ "${action}" == "install" ]]; then
        echoContent green " ---> XHTTP 已接入面板站点 https://${btDomain}$(xhttpPublicPath)/ (${file})"
    fi
}

# Remove our XHTTP location from every panel site (used by uninstall).
removeAllPanelXhttpLocations() {
    local file changed=false
    for file in "${panelVhostRoot}"/nginx/extension/*/xray-agent-xhttp.conf; do
        [[ -f "${file}" ]] && rm -f "${file}" && changed=true
    done
    for file in "${panelVhostRoot}"/rewrite/*.conf; do
        if [[ -f "${file}" ]] && grep -qF "${xhttpPanelMarkerBegin}" "${file}"; then
            stripXhttpPanelBlock "${file}" >"${file}.tmp.$$" && mv "${file}.tmp.$$" "${file}" && changed=true
        fi
    done
    if [[ "${changed}" == "true" ]] && panelNginxTest >/dev/null 2>&1; then
        panelNginxReload >/dev/null 2>&1
    fi
    rm -f "${xhttpStateFile}"
}
checkIP() {
    echoContent skyBlue "\n ---> 检查域名ip中"
    local localIP=$1

    if [[ -z ${localIP} ]] || ! echo "${localIP}" | sed '1{s/[^(]*(//;s/).*//;q}' | grep -q '\.' && ! echo "${localIP}" | sed '1{s/[^(]*(//;s/).*//;q}' | grep -q ':'; then
        echoContent red "\n ---> 未检测到当前域名的ip"
        echoContent skyBlue " ---> 请依次进行下列检查"
        echoContent yellow " --->  1.检查域名是否书写正确"
        echoContent yellow " --->  2.检查域名dns解析是否正确"
        echoContent yellow " --->  3.如解析正确，请等待dns生效，预计三分钟内生效"
        echoContent yellow " --->  4.如报Nginx启动问题，请手动启动nginx查看错误，如自己无法处理请提issues"
        echo
        echoContent skyBlue " ---> 如以上设置都正确，请重新安装纯净系统后再次尝试"

        if [[ -n ${localIP} ]]; then
            echoContent yellow " ---> 检测返回值异常，建议手动卸载nginx后重新执行脚本"
            echoContent red " ---> 异常结果：${localIP}"
        fi
        exit 0
    else
        if echo "${localIP}" | awk -F "[,]" '{print $2}' | grep -q "." || echo "${localIP}" | awk -F "[,]" '{print $2}' | grep -q ":"; then
            echoContent red "\n ---> 检测到多个ip，请确认是否关闭cloudflare的云朵"
            echoContent yellow " ---> 关闭云朵后等待三分钟后重试"
            echoContent yellow " ---> 检测到的ip如下:[${localIP}]"
            exit 0
        fi
        echoContent green " ---> 检查当前域名IP正确"
    fi
}
# Custom email
customSSLEmail() {
    if echo "$1" | grep -q "validate email"; then
        read -r -p "是否重新输入邮箱地址[y/n]:" sslEmailStatus
        if [[ "${sslEmailStatus}" == "y" ]]; then
            sed '/ACCOUNT_EMAIL/d' /root/.acme.sh/account.conf >/root/.acme.sh/account.conf_tmp && mv /root/.acme.sh/account.conf_tmp /root/.acme.sh/account.conf
        else
            exit 0
        fi
    fi

    if [[ -d "/root/.acme.sh" && -f "/root/.acme.sh/account.conf" ]]; then
        if ! grep -q "ACCOUNT_EMAIL" <"/root/.acme.sh/account.conf" && ! echo "${sslType}" | grep -q "letsencrypt"; then
            read -r -p "请输入邮箱地址:" sslEmail
            if echo "${sslEmail}" | grep -q "@"; then
                echo "ACCOUNT_EMAIL='${sslEmail}'" >>/root/.acme.sh/account.conf
                echoContent green " ---> 添加完毕"
            else
                echoContent yellow "请重新输入正确的邮箱格式[例: username@example.com]"
                customSSLEmail
            fi
        fi
    fi

}

# Locate the acme.sh installed by default by acme_manage.sh; ACME_HOME and PATH are also supported.
detectLocalAcmeHome() {
    local candidate=
    local -a candidates=("${ACME_HOME:-}" "$HOME/.acme.sh" "/root/.acme.sh")
    for candidate in "${candidates[@]}"; do
        if [[ -n "${candidate}" && -x "${candidate}/acme.sh" ]]; then
            echo "${candidate}"
            return 0
        fi
    done

    if command -v acme.sh >/dev/null 2>&1; then
        candidate=$(dirname "$(readlink -f "$(command -v acme.sh)")")
        if [[ -x "${candidate}/acme.sh" ]]; then
            echo "${candidate}"
            return 0
        fi
    fi
    return 1
}

# Select an RSA/ECC certificate from the acme.sh certificate config directory.
selectLocalAcmeCertificate() {
    local acmeHome=
    acmeHome=$(detectLocalAcmeHome) || return 1

    local -a certDomains=()
    local -a certDirs=()
    local -a certEcc=()
    local conf certDir certDomain eccLabel
    while read -r conf; do
        certDir=$(dirname "${conf}")
        certDomain=$(basename "${conf}" .conf)
        [[ -f "${certDir}/fullchain.cer" && -f "${certDir}/${certDomain}.key" ]] || continue

        if [[ "$(basename "${certDir}")" == *_ecc ]]; then
            certEcc+=(true)
        else
            certEcc+=(false)
        fi
        certDomains+=("${certDomain}")
        certDirs+=("${certDir}")
    done < <(find "${acmeHome}" -mindepth 2 -maxdepth 2 -type f -name '*.conf' 2>/dev/null | sort)

    if ((${#certDomains[@]} == 0)); then
        return 1
    fi

    echoContent skyBlue "\n---------- acme.sh 已签发证书 ----------"
    local i
    for i in "${!certDomains[@]}"; do
        eccLabel=RSA
        [[ "${certEcc[$i]}" == "true" ]] && eccLabel=ECC
        echoContent yellow "$((i + 1)). ${certDomains[$i]} [${eccLabel}]"
    done
    echoContent skyBlue "----------------------------------------"
    read -r -p "是否使用以上 acme.sh 证书？[y/n]:" useAcmeManagedCert
    [[ "${useAcmeManagedCert}" == "y" ]] || return 1

    local selectedIndex=
    read -r -p "请选择证书编号:" selectedIndex
    if [[ ! "${selectedIndex}" =~ ^[0-9]+$ ]] || ((selectedIndex < 1 || selectedIndex > ${#certDomains[@]})); then
        echoContent red " ---> 证书编号无效"
        return 1
    fi
    selectedIndex=$((selectedIndex - 1))

    acmeManagedHome=${acmeHome}
    acmeManagedSourceDomain=${certDomains[$selectedIndex]}
    acmeManagedEcc=${certEcc[$selectedIndex]}

    local serviceDomain=
    read -r -p "请输入 Xray 使用的域名[默认:${acmeManagedSourceDomain}，通配符证书可填子域名]:" serviceDomain
    serviceDomain=${serviceDomain:-${acmeManagedSourceDomain}}

    while ! openssl x509 -in "${certDirs[$selectedIndex]}/fullchain.cer" -noout -checkhost "${serviceDomain}" >/dev/null 2>&1; do
        echoContent red " ---> 所选证书不包含域名 ${serviceDomain}"
        read -r -p "请重新输入证书覆盖的域名，输入 q 取消:" serviceDomain
        [[ "${serviceDomain}" == "q" ]] && return 1
    done

    acmeManagedCertSelected=true
    domain=${serviceDomain}
    echoContent green " ---> 已选择 ${acmeManagedSourceDomain} 证书，Xray域名: ${domain}"
    return 0
}

# Copy the certificate using the official acme.sh deploy interface, so later renewals update the Xray files automatically.
deployLocalAcmeCertificate() {
    local certFile="/opt/xray-agent/tls/${domain}.crt"
    local keyFile="/opt/xray-agent/tls/${domain}.key"
    local -a installArgs=(
        "${acmeManagedHome}/acme.sh" --install-cert
        -d "${acmeManagedSourceDomain}"
        --fullchain-file "${certFile}"
        --key-file "${keyFile}"
        --reloadcmd "if systemctl is-active --quiet xray.service; then systemctl restart xray.service >/dev/null 2>&1 || systemctl start xray.service >/dev/null 2>&1; fi"
    )
    [[ "${acmeManagedEcc}" == "true" ]] && installArgs+=(--ecc)

    mkdir -p /opt/xray-agent/tls
    if ! "${installArgs[@]}"; then
        echoContent red " ---> 从 acme.sh 部署证书失败"
        return 1
    fi
    chmod 600 "${keyFile}"

    if [[ ! -s "${certFile}" || ! -s "${keyFile}" ]] || ! openssl x509 -in "${certFile}" -noout -checkhost "${domain}" >/dev/null 2>&1; then
        echoContent red " ---> 部署后的证书无效或不包含 ${domain}"
        return 1
    fi

    cat <<EOF >/opt/xray-agent/tls/acme_managed.conf
ACME_HOME=${acmeManagedHome}
SOURCE_DOMAIN=${acmeManagedSourceDomain}
SERVICE_DOMAIN=${domain}
ECC=${acmeManagedEcc}
EOF
    echoContent green " ---> 已从 acme.sh 部署证书到 ${certFile}"
    echoContent green " ---> acme.sh 续期后会自动更新证书并重载 Xray"
}

# Kept for backward compatibility: list the acme.sh certificates available on this host.
listLocalAcmeCertificates() {
    local acmeHome=
    acmeHome=$(detectLocalAcmeHome) || return 1
    echoContent skyBlue "\n---------- 本地 acme.sh 证书 ----------"
    find "${acmeHome}" -mindepth 2 -maxdepth 2 -type f -name '*.conf' 2>/dev/null | while read -r conf; do
        local certDir certName certType
        certDir=$(dirname "${conf}")
        certName=$(basename "${conf}" .conf)
        [[ -f "${certDir}/fullchain.cer" && -f "${certDir}/${certName}.key" ]] || continue
        certType=RSA
        [[ "$(basename "${certDir}")" == *_ecc ]] && certType=ECC
        echoContent yellow " - ${certName} [${certType}]"
    done
    echoContent skyBlue "--------------------------------------"
}

# Choose the SSL installation type
switchSSLType() {
    if [[ -z "${sslType}" ]]; then
        echoContent red "\n=============================================================="
        echoContent skyBlue "请选择 SSL 证书提供商"
        echoContent red "=============================================================="
        echoContent yellow "1. Let's Encrypt [推荐，默认]"
        echoContent green "   - 免费、稳定、广泛使用"
        echoContent yellow "2. Google Trust Services (GTS)"
        echoContent green "   - 需要 EAB 凭证 (External Account Binding)"
        echoContent red "=============================================================="
        read -r -p "请选择 [1-2，回车默认使用 Let's Encrypt]:" selectSSLType
        case ${selectSSLType} in
            2)
                sslType="google"
                echoContent green "\n ---> 已选择: Google Trust Services (GTS)"
                echoContent red "\n=============================================================="
                echoContent skyBlue "⚠️  GTS 需要 External Account Binding (EAB) 凭证"
                echoContent red "=============================================================="
                read -r -p "请输入 EAB Key ID (KID): " googleEabKid
                read -r -p "请输入 EAB HMAC Key: " googleEabHmac
                if [[ -z "${googleEabKid}" || -z "${googleEabHmac}" ]]; then
                    echoContent red "\n ---> EAB 凭证不能为空，退出安装"
                    echoContent yellow " ---> 建议使用 Let's Encrypt (无需额外注册)"
                    exit 0
                fi
                echo "${googleEabKid}" >/opt/xray-agent/tls/google_eab_kid
                echo "${googleEabHmac}" >/opt/xray-agent/tls/google_eab_hmac
                echoContent green "\n ---> EAB 凭证已保存"
                ;;
            *)
                sslType="letsencrypt"
                echoContent green "\n ---> 已选择: Let's Encrypt (默认)"
                ;;
        esac
        echo "${sslType}" >/opt/xray-agent/tls/ssl_type
    fi
}

# Choose how ACME issues the certificate
selectAcmeInstallSSL() {
    if [[ "${ipType}" == "6" ]]; then
        sslIPv6="--listen-v6"
    fi

    acmeInstallSSL

    readAcmeTLS
}

# Install the SSL certificate
acmeInstallSSL() {
    # Google GTS requires registering an EAB account first
    if [[ "${sslType}" == "google" ]]; then
        local googleEabKid=""
        local googleEabHmac=""

        # Read the saved EAB credentials
        if [[ -f /opt/xray-agent/tls/google_eab_kid ]]; then
            googleEabKid=$(cat /opt/xray-agent/tls/google_eab_kid)
            googleEabHmac=$(cat /opt/xray-agent/tls/google_eab_hmac)
        fi

        if [[ -n "${googleEabKid}" && -n "${googleEabHmac}" ]]; then
            echoContent skyBlue " ---> 检测到 Google EAB 凭证，正在注册账号..."

            # Register a Google GTS account
            if ! "$HOME/.acme.sh/acme.sh" --register-account \
                --server google \
                --eab-kid "${googleEabKid}" \
                --eab-hmac-key "${googleEabHmac}" 2>&1 | tee -a /opt/xray-agent/tls/acme.log; then

                echoContent red "\n ---> Google GTS 账号注册失败"
                echoContent yellow " ---> 请检查 EAB 凭证是否正确"
                echoContent yellow " ---> 或选择其他证书提供商 (Let's Encrypt)"
                exit 0
            fi

            echoContent green " ---> Google GTS 账号注册成功"
        fi
    fi

    echoContent green " ---> 生成证书中"

    # Standalone mode needs Nginx stopped to free port 80
    handleNginx stop

    sudo "$HOME/.acme.sh/acme.sh" --issue -d "${tlsDomain}" --standalone -k ec-256 --server "${sslType}" ${sslIPv6} 2>&1 | tee -a /opt/xray-agent/tls/acme.log >/dev/null

    # Restart Nginx after the certificate is issued
    handleNginx start
}
# Custom port
customPortFunction() {
    local historyCustomPortStatus=
    if [[ -n "${customPort}" || -n "${currentPort}" ]]; then
        echo
        # Always ask whether to reuse the previous port, regardless of lastInstallationConfig
        read -r -p "读取到上次安装时的端口，是否使用上次安装时的端口？[y/n]:" historyCustomPortStatus
        if [[ "${historyCustomPortStatus}" == "y" ]]; then
            port=${currentPort}
            echoContent yellow "\n ---> 端口: ${port}"
        fi
    fi
    if [[ -z "${currentPort}" ]] || [[ "${historyCustomPortStatus}" == "n" ]]; then
        echo

        if [[ -n "${btDomain}" ]]; then
            echoContent yellow "请输入端口[不可与宝塔/aaPanel/1Panel 或其 Nginx 的端口相同，回车随机]"
            read -r -p "端口:" port
            if [[ -z "${port}" ]]; then
                port=$((RANDOM % 20001 + 10000))
            fi
        else
            echo
            echoContent yellow "请输入端口[默认: 443]，可自定义端口[回车使用默认]"
            read -r -p "端口:" port
            if [[ -z "${port}" ]]; then
                port=443
            fi
        fi

        if [[ -n "${port}" ]]; then
            if ((port >= 1 && port <= 65535)); then
                allowPort "${port}"
                echoContent yellow "\n ---> 端口: ${port}"
                if [[ -z "${btDomain}" ]]; then
                    checkDNSIP "${domain}"
                    removeNginxDefaultConf
                    checkPortOpen "${port}" "${domain}"
                fi
            else
                echoContent red " ---> 端口输入错误"
                exit 0
            fi
        else
            echoContent red " ---> 端口不可为空"
            exit 0
        fi
    fi
}

# Initialize the Xray-core Hysteria2 UDP listen port.
# TCP/443 and UDP/443 can be listened on simultaneously, so the main TLS port is reused by default.
initHysteria2Port() {
    local defaultPort=${port:-443}
    local selectedPort=

    if [[ -n "${hysteria2Port}" && "${hysteria2Port}" != "null" ]]; then
        read -r -p "读取到上次 Hysteria2 UDP 端口 ${hysteria2Port}，是否继续使用？[y/n]:" historyHysteria2PortStatus
        if [[ "${historyHysteria2PortStatus}" == "y" ]]; then
            selectedPort=${hysteria2Port}
        fi
    fi

    if [[ -z "${selectedPort}" ]]; then
        read -r -p "请输入 Hysteria2 UDP 端口[默认:${defaultPort}]:" selectedPort
        selectedPort=${selectedPort:-${defaultPort}}
    fi

    if [[ ! "${selectedPort}" =~ ^[0-9]+$ ]] || ((selectedPort < 1 || selectedPort > 65535)); then
        echoContent red " ---> Hysteria2 UDP端口输入错误"
        exit 1
    fi

    hysteria2Port=${selectedPort}
    allowPort "${hysteria2Port}" udp
    echoContent yellow "\n ---> Hysteria2 UDP端口: ${hysteria2Port}"
    initHysteria2PortHopping
}

# Choose the Xray QUIC BBR behavior profile; the result is written to selectedHysteria2BbrProfile.
selectHysteria2BbrProfile() {
    local defaultProfile=${1:-standard}
    local contextLabel=${2:-Hysteria2}
    local defaultChoice=2
    local profileChoice=

    case ${defaultProfile} in
        conservative) defaultChoice=1 ;;
        aggressive) defaultChoice=3 ;;
        *) defaultProfile=standard ;;
    esac

    echoContent skyBlue "\n---------- ${contextLabel} QUIC BBR Profile ----------"
    echoContent yellow "1.conservative [低抖动/保守]"
    echoContent yellow "2.standard [均衡/推荐]"
    echoContent yellow "3.aggressive [吞吐优先]"
    echoContent skyBlue "------------------------------------------------------"
    read -r -p "请选择[默认:${defaultChoice}]：" profileChoice
    profileChoice=${profileChoice:-${defaultChoice}}

    case ${profileChoice} in
        1) selectedHysteria2BbrProfile=conservative ;;
        2) selectedHysteria2BbrProfile=standard ;;
        3) selectedHysteria2BbrProfile=aggressive ;;
        *)
            echoContent red " ---> 请选择 1-3"
            selectHysteria2BbrProfile "${defaultProfile}" "${contextLabel}"
            return
            ;;
    esac
    echoContent green " ---> ${contextLabel} QUIC拥塞控制: BBR/${selectedHysteria2BbrProfile}"
}

# The BBR profile is not asked during installation. New installs use
# "standard"; a reinstall keeps the profile chosen earlier in Hysteria2
# management (hysteria2BbrProfile is read from the existing config).
initHysteria2BbrProfile() {
    [[ "${hysteria2BbrProfile}" =~ ^(conservative|standard|aggressive)$ ]] || hysteria2BbrProfile=standard
    echoContent green " ---> Hysteria2 QUIC拥塞控制: BBR/${hysteria2BbrProfile}（可在「协议设置 → Hysteria2管理」中修改）"
}

# Expand a bare domain into an HTTPS URL, rejecting non-HTTP(S) schemes and whitespace.
normalizeHTTPURL() {
    local inputURL=$1

    [[ -n "${inputURL}" && "${inputURL}" != *[[:space:]]* ]] || return 1
    case "${inputURL}" in
        http://* | https://*) ;;
        *://*) return 1 ;;
        *) inputURL="https://${inputURL}" ;;
    esac

    [[ "${inputURL}" =~ ^https?://[^/[:space:]]+(/[^[:space:]]*)?$ ]] || return 1
    if [[ "${inputURL#*://}" != */* ]]; then
        inputURL="${inputURL}/"
    fi
    printf '%s\n' "${inputURL}"
}

# Choose the masquerade method for unauthenticated Hysteria2 HTTP/3 requests.
# Sets hysteria2MasqueradeConfig to a JSON object, or to "null" when
# masquerading is turned off (the inbound then has no masquerade at all).
initHysteria2Masquerade() {
    # The panel site already serves a full website with valid TLS, so use it directly as the Hysteria2 masquerade target.
    # Hysteria2 uses a UDP inbound while the target site uses TCP/443, so there is no port conflict.
    if [[ -n "${btDomain:-}" ]]; then
        local panelProxyURL=
        if panelProxyURL=$(normalizeHTTPURL "${btDomain}"); then
            hysteria2MasqueradeConfig=$(jq -nc --arg url "${panelProxyURL}" '{type:"proxy",url:$url,rewriteHost:true,insecure:false}')
            echoContent skyBlue "\n---------- Hysteria2 HTTP/3伪装 ----------"
            echoContent green " ---> 检测到宝塔/aaPanel站点，自动反向代理到: ${panelProxyURL}"
            return
        fi
        echoContent yellow " ---> 面板站点域名无效，改为手动选择Hysteria2伪装"
    fi

    echoContent skyBlue "\n---------- Hysteria2 HTTP/3伪装 ----------"
    echoContent yellow "1.本地静态网站[默认]"
    echoContent yellow "2.301跳转"
    echoContent yellow "3.反向代理现有网站"
    echoContent yellow "4.不启用伪装"
    echoContent skyBlue "------------------------------------------"

    local masqueradeType=
    read -r -p "请选择[默认:1]:" masqueradeType
    masqueradeType=${masqueradeType:-1}

    case ${masqueradeType} in
        1)
            hysteria2MasqueradeConfig=$(jq -nc --arg dir "${nginxStaticPath}" '{type:"file",dir:$dir}')
            echoContent green " ---> 使用本地静态网站: ${nginxStaticPath}"
            ;;
        4)
            hysteria2MasqueradeConfig=null
            echoContent yellow " ---> 不启用HTTP/3伪装"
            ;;
        2)
            local redirectURL=
            read -r -p "请输入跳转域名[例:v.domain.com]:" redirectURL
            if ! redirectURL=$(normalizeHTTPURL "${redirectURL}"); then
                echoContent red " ---> 跳转域名格式错误"
                initHysteria2Masquerade
                return
            fi
            hysteria2MasqueradeConfig=$(jq -nc --arg url "${redirectURL}" '{type:"string",content:"",headers:{Location:$url},statusCode:301}')
            echoContent green " ---> HTTP/3未认证访问将301跳转到: ${redirectURL}"
            ;;
        3)
            local proxyURL=
            local defaultProxyURL=
            read -r -p "请输入反向代理地址${defaultProxyURL:+[默认:${defaultProxyURL}]}:" proxyURL
            proxyURL=${proxyURL:-${defaultProxyURL}}
            if ! proxyURL=$(normalizeHTTPURL "${proxyURL}"); then
                echoContent red " ---> 反向代理地址格式错误，请输入域名或完整的 http(s) URL"
                initHysteria2Masquerade
                return
            fi
            hysteria2MasqueradeConfig=$(jq -nc --arg url "${proxyURL}" '{type:"proxy",url:$url,rewriteHost:true,insecure:false}')
            echoContent green " ---> HTTP/3未认证访问将反向代理到: ${proxyURL}"
            ;;
        *)
            echoContent red " ---> 选择错误"
            initHysteria2Masquerade
            return
            ;;
    esac
}

# Check whether the port is in use
checkPort() {
    if [[ -n "$1" ]] && lsof -i "tcp:$1" | grep -q LISTEN; then
        echoContent red "\n=============================================================="
        echoContent yellow "端口 $1 已被占用"
        echoContent skyBlue "\n占用进程信息："
        lsof -i "tcp:$1" | grep LISTEN

        # Check whether Nginx is the one using it
        if lsof -i "tcp:$1" | grep -q nginx; then
            echoContent yellow "\n检测到端口被 Nginx 占用，这可能是现有业务"
            echoContent red "警告：强制使用此端口可能影响现有服务！"
        fi
        echoContent red "==============================================================\n"

        read -r -p "是否继续（可能导致冲突）？[y/n]:" continueWithConflict
        if [[ "${continueWithConflict}" != "y" ]]; then
            echoContent yellow "请更换端口或关闭占用进程后重试"
            exit 0
        fi
    fi
}

# Install TLS
installTLS() {
    echoContent skyBlue "\n进度  $1/${totalProgress} : 申请TLS证书\n"

    # Check whether a Native ACME certificate is used
    if [[ "${nativeACMEEnabled}" == "true" ]]; then
        echoContent green " ---> 使用 Native ACME 证书"
        echoContent green " ---> 证书路径: ${nativeCertPath}"
        echoContent green " ---> 密钥路径: ${nativeKeyPath}"

        # Verify that the certificate files exist
        if [[ -f "/opt/xray-agent/tls/${domain}.crt" && -f "/opt/xray-agent/tls/${domain}.key" ]]; then
            echoContent green " ---> Native ACME 证书已就绪"
            return 0
        else
            echoContent red " ---> Native ACME 证书软链接创建失败"
            exit 0
        fi
    fi

    readAcmeTLS
    local tlsDomain=${domain}

    if [[ "${acmeManagedCertSelected}" == "true" ]]; then
        echoContent green " ---> 使用 acme_manage.sh / acme.sh 已签发证书"
        if ! deployLocalAcmeCertificate; then
            exit 1
        fi
        return 0
    fi

    if [[ -d "$HOME/.acme.sh" ]]; then
        listLocalAcmeCertificates
    fi

    # Install TLS
    if [[ -f "/opt/xray-agent/tls/${tlsDomain}.crt" && -f "/opt/xray-agent/tls/${tlsDomain}.key" && -n $(cat "/opt/xray-agent/tls/${tlsDomain}.crt") ]] || [[ -d "$HOME/.acme.sh/${tlsDomain}_ecc" && -f "$HOME/.acme.sh/${tlsDomain}_ecc/${tlsDomain}.key" && -f "$HOME/.acme.sh/${tlsDomain}_ecc/${tlsDomain}.cer" ]] || [[ "${installedDNSAPIStatus}" == "true" ]]; then
        echoContent green " ---> 检测到证书"
        renewalTLS

        if [[ -z $(find /opt/xray-agent/tls/ -name "${tlsDomain}.crt") ]] || [[ -z $(find /opt/xray-agent/tls/ -name "${tlsDomain}.key") ]] || [[ -z $(cat "/opt/xray-agent/tls/${tlsDomain}.crt") ]]; then
            if [[ "${installedDNSAPIStatus}" == "true" ]]; then
                sudo "$HOME/.acme.sh/acme.sh" --installcert -d "*.${dnsTLSDomain}" --fullchain-file "/opt/xray-agent/tls/${tlsDomain}.crt" --key-file "/opt/xray-agent/tls/${tlsDomain}.key" --ecc >/dev/null
            else
                sudo "$HOME/.acme.sh/acme.sh" --installcert -d "${tlsDomain}" --fullchain-file "/opt/xray-agent/tls/${tlsDomain}.crt" --key-file "/opt/xray-agent/tls/${tlsDomain}.key" --ecc >/dev/null
            fi

        else
            if [[ -d "$HOME/.acme.sh/${tlsDomain}_ecc" && -f "$HOME/.acme.sh/${tlsDomain}_ecc/${tlsDomain}.key" && -f "$HOME/.acme.sh/${tlsDomain}_ecc/${tlsDomain}.cer" ]] || [[ "${installedDNSAPIStatus}" == "true" ]]; then
                if [[ -z "${lastInstallationConfig}" ]]; then
                    echoContent yellow " ---> 如未过期或者自定义证书请选择[n]\n"
                    read -r -p "是否重新安装？[y/n]:" reInstallStatus
                    if [[ "${reInstallStatus}" == "y" ]]; then
                        rm -rf /opt/xray-agent/tls/*
                        installTLS "$1"
                    fi
                fi
            fi
        fi

    elif [[ -d "$HOME/.acme.sh" ]] && [[ ! -f "$HOME/.acme.sh/${tlsDomain}_ecc/${tlsDomain}.cer" || ! -f "$HOME/.acme.sh/${tlsDomain}_ecc/${tlsDomain}.key" ]]; then
        local -a localAcmeDirs=()
        mapfile -t localAcmeDirs < <(find "$HOME/.acme.sh" -maxdepth 1 -type d -name "*_ecc" 2>/dev/null)
        if ((${#localAcmeDirs[@]} > 0)); then
            echoContent red " ---> 未检测到 ${tlsDomain} 或 *.${dnsTLSDomain} 证书，脚本不会代为申请"
            echoContent yellow " ---> 请使用本地 acme.sh 或面板自行申请后再次运行"
            exit 0
        fi

        echoContent green " ---> 本地 acme.sh 尚无证书，开始申请"
        echoContent green " ---> 申请过程需要开放 80 端口"
        allowPort 80

        switchSSLType
        customSSLEmail
        selectAcmeInstallSSL

        sudo "$HOME/.acme.sh/acme.sh" --installcert -d "${tlsDomain}" --fullchainpath "/opt/xray-agent/tls/${tlsDomain}.crt" --keypath "/opt/xray-agent/tls/${tlsDomain}.key" --ecc >/dev/null

        if [[ ! -f "/opt/xray-agent/tls/${tlsDomain}.crt" || ! -f "/opt/xray-agent/tls/${tlsDomain}.key" ]] || [[ -z $(cat "/opt/xray-agent/tls/${tlsDomain}.key") || -z $(cat "/opt/xray-agent/tls/${tlsDomain}.crt") ]]; then
            tail -n 10 /opt/xray-agent/tls/acme.log
            if [[ ${installTLSCount} == "1" ]]; then
                echoContent red " ---> TLS安装失败，请检查acme日志"
                exit 0
            fi

            echo

            if tail -n 10 /opt/xray-agent/tls/acme.log | grep -q "Could not validate email address as valid"; then
                echoContent red " ---> 邮箱无法通过SSL厂商验证，请重新输入"
                echo
                customSSLEmail "validate email"
                installTLSCount=1
                installTLS "$1"
            else
                installTLSCount=1
                installTLS "$1"
            fi
        fi

        echoContent green " ---> TLS生成成功"
    else
        echoContent yellow " ---> 未安装acme.sh"
        exit 0
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
normalizeXrayEmail() {
    local value=$1 suffix
    for suffix in VLESS_TCP/TLS_Vision VLESS_WS VLESS_XHTTP_Reality VLESS_XHTTP vless_reality_vision Hysteria2; do
        if [[ "${value}" == *-"${suffix}" ]]; then
            printf '%s\n' "${value%-${suffix}}"
            return 0
        fi
    done
    printf '%s\n' "${value}"
}

validateXrayUserTag() {
    [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$ ]]
}

initXrayClients() {
    local clientType=$1
    local newUUID=$2
    local newEmail=$3
    case "${clientType}" in
        0 | 1 | 3 | 12 | 14) ;;
        *)
            echoContent red "不支持的 Xray 客户端类型: ${clientType}" >&2
            return 1
            ;;
    esac

    # Check whether currentClients is empty or null to avoid jq errors
    if [[ -z "${currentClients}" ]] || [[ "${currentClients}" == "null" ]] || ! jq -e 'type == "array"' >/dev/null 2>&1 <<<"${currentClients}"; then
        currentClients="[]"
    fi

    local users='[]'
    local existingUUID existingEmail currentUser
    while read -r user; do
        existingUUID=$(jq -r '.id // .uuid // empty' <<<"${user}")
        existingEmail=$(normalizeXrayEmail "$(jq -r '.email // .name // "user"' <<<"${user}")")
        [[ -z "${existingUUID}" ]] && continue
        currentUser=$(buildXrayClient "${clientType}" "${existingUUID}" "${existingEmail}") || return 1
        users=$(jq --argjson user "${currentUser}" '. + [$user]' <<<"${users}")
    done < <(echo "${currentClients}" | jq -c '.[]')

    if [[ -n "${newUUID}" ]]; then
        currentUser=$(buildXrayClient "${clientType}" "${newUUID}" "${newEmail}") || return 1
        users=$(jq --argjson user "${currentUser}" '. + [$user]' <<<"${users}")
    fi
    echo "${users}"
}

buildXrayClient() {
    local clientType=$1 userUUID=$2 userEmail=$3
    case "${clientType}" in
        0) jq -nc --arg id "${userUUID}" --arg email "${userEmail}-VLESS_TCP/TLS_Vision" '{id:$id,flow:"xtls-rprx-vision",email:$email}' ;;
        1) jq -nc --arg id "${userUUID}" --arg email "${userEmail}-VLESS_WS" '{id:$id,email:$email}' ;;
        3) jq -nc --arg id "${userUUID}" --arg email "${userEmail}-vless_reality_vision" '{id:$id,email:$email,flow:"xtls-rprx-vision"}' ;;
        # XHTTP has no XTLS splice; the Vision flow only works there together
        # with VLESS Encryption, so these users carry no flow.
        12) jq -nc --arg id "${userUUID}" --arg email "${userEmail}-VLESS_XHTTP_Reality" '{id:$id,email:$email}' ;;
        14) jq -nc --arg id "${userUUID}" --arg email "${userEmail}-VLESS_XHTTP" '{id:$id,email:$email}' ;;
        *) return 1 ;;
    esac
}

# Convert the script's existing UUID users into Xray-core Hysteria2 auth clients.
# The UUID is used as auth so that all installed protocols share one set of accounts.
initXrayHysteria2Clients() {
    local users='[]'
    local user userId userEmail

    while read -r user; do
        userId=$(echo "${user}" | jq -r '.id // .uuid // .auth // empty')
        userEmail=$(normalizeXrayEmail "$(echo "${user}" | jq -r '.email // .name // "user"')")
        if [[ -n "${userId}" ]]; then
            users=$(echo "${users}" | jq -c --arg auth "${userId}" --arg email "${userEmail}-Hysteria2" '. += [{auth: $auth, level: 0, email: $email}]')
        fi
    done < <(echo "${currentClients:-[]}" | jq -c '.[]')

    echo "${users}"
}
# Add an Xray-core outbound
addXrayOutbound() {
    local tag=$1
    local domainStrategy=

    if echo "${tag}" | grep -q "IPv4"; then
        domainStrategy="ForceIPv4"
    elif echo "${tag}" | grep -q "IPv6"; then
        domainStrategy="ForceIPv6"
    fi

    # "UseIP" for the plain direct outbound.
    if [[ -z "${domainStrategy}" ]] && echo "${tag}" | grep -q "direct"; then
        domainStrategy="UseIP"
    fi
    if [[ -n "${domainStrategy}" ]]; then
        # freedom.settings.domainStrategy is deprecated since v26.9; the
        # sockopt form works on current stable and pre-releases alike.
        jq -n --arg tag "${tag}" --arg strategy "${domainStrategy}" '{outbounds:[{
            protocol:"freedom", tag:$tag,
            streamSettings:{sockopt:{domainStrategy:$strategy}}
        }]}' >"/opt/xray-agent/xray/conf/${tag}.json"
    fi
    # blackhole
    if echo "${tag}" | grep -q "blackhole"; then
        cat <<EOF >"/opt/xray-agent/xray/conf/${tag}.json"
{
    "outbounds":[
        {
            "protocol":"blackhole",
            "tag":"${tag}"
        }
    ]
}
EOF
    fi
    if echo "${tag}" | grep -q "wireguard_out_IPv4"; then
        cat <<EOF >"/opt/xray-agent/xray/conf/${tag}.json"
{
  "outbounds": [
    {
      "protocol": "wireguard",
      "settings": {
        "secretKey": "${secretKeyWarpReg}",
        "address": [
          "${address}"
        ],
        "peers": [
          {
            "publicKey": "${publicKeyWarpReg}",
            "allowedIPs": [
              "0.0.0.0/0",
              "::/0"
            ],
            "endpoint": "162.159.192.1:2408"
          }
        ],
        "reserved": ${reservedWarpReg},
        "mtu": 1280
      },
      "tag": "${tag}"
    }
  ]
}
EOF
    fi
    if echo "${tag}" | grep -q "wireguard_out_IPv6"; then
        cat <<EOF >"/opt/xray-agent/xray/conf/${tag}.json"
{
  "outbounds": [
    {
      "protocol": "wireguard",
      "settings": {
        "secretKey": "${secretKeyWarpReg}",
        "address": [
          "${address}"
        ],
        "peers": [
          {
            "publicKey": "${publicKeyWarpReg}",
            "allowedIPs": [
              "0.0.0.0/0",
              "::/0"
            ],
            "endpoint": "162.159.192.1:2408"
          }
        ],
        "reserved": ${reservedWarpReg},
        "mtu": 1280
      },
      "tag": "${tag}"
    }
  ]
}
EOF
    fi
}

# Remove an Xray-core outbound
removeXrayOutbound() {
    local tag=$1
    if [[ -f "/opt/xray-agent/xray/conf/${tag}.json" ]]; then
        rm "/opt/xray-agent/xray/conf/${tag}.json" >/dev/null 2>&1
    fi
}
# Initialize the Xray config file

initXrayConfig() {
    echoContent skyBlue "\n进度 $2/${totalProgress} : 初始化Xray配置"
    if [[ "$1" == "all" ]]; then
        selectCustomInstallType=${recommendedInstallSelection}
    fi
    # Regenerating only some inbounds (e.g. REALITY management) skips the
    # path prompt; keep the installed path.
    customPath=${customPath:-${currentPath}}
    echo
    # Keep only Vision, WebSocket, Reality Vision and Hysteria2.
    # On reinstall/upgrade, remove leftover inbounds of other protocols from older versions so Xray does not keep loading them.
    find /opt/xray-agent/xray/conf -maxdepth 1 -type f \( \
        -name '*trojan*inbounds.json' -o \
        -name '*VLESS_gRPC_inbounds.json' -o \
        -name '*VLESS_vision_gRPC_inbounds.json' -o \
        -name '*tuic_inbounds.json' -o \
        -name '*naive_inbounds.json' -o \
        -name '*VMess_HTTPUpgrade_inbounds.json' -o \
        -name '*anytls_inbounds.json' \
        \) -delete 2>/dev/null

    local uuid=
    local addClientsStatus=
    # Always ask whether to reuse the previous user config, regardless of lastInstallationConfig
    if [[ -n "${currentUUID}" ]]; then
        read -r -p "读取到上次用户配置，是否使用上次安装的配置 ？[y/n]:" historyUUIDStatus
        if [[ "${historyUUIDStatus}" == "y" ]]; then
            addClientsStatus=true
            echoContent green "\n ---> 使用成功"
        fi
    fi

    if [[ -z "${addClientsStatus}" ]]; then
        echoContent yellow "请输入自定义UUID[需合法]，[回车]随机UUID"
        read -r -p 'UUID:' customUUID

        if [[ -n ${customUUID} ]]; then
            uuid=${customUUID}
        else
            uuid=$(/opt/xray-agent/xray/xray uuid)
        fi

        echoContent yellow "\n请输入账号标签(tag)，例如 jp_vision，[回车]使用 UUID 前缀"
        read -r -p '账号标签:' customEmail
        if [[ -z ${customEmail} ]]; then
            customEmail="$(echo "${uuid}" | cut -d "-" -f 1)"
        elif ! validateXrayUserTag "${customEmail}"; then
            echoContent red " ---> 标签仅支持字母、数字、点、下划线和连字符，且最长 64 位"
            return 1
        fi
    fi

    if [[ -z "${addClientsStatus}" && -z "${uuid}" ]]; then
        addClientsStatus=
        echoContent red "\n ---> uuid读取错误，随机生成"
        uuid=$(/opt/xray-agent/xray/xray uuid)
    fi

    if [[ -n "${uuid}" ]]; then
        currentClients='[{"id":"'${uuid}'","add":"'${add}'","flow":"xtls-rprx-vision","email":"'${customEmail}'"}]'
        echoContent green "\n ${customEmail}:${uuid}"
        echo
    fi

    # log
    if [[ ! -f "/opt/xray-agent/xray/conf/00_log.json" ]]; then

        cat <<EOF >/opt/xray-agent/xray/conf/00_log.json
{
  "log": {
    "error": "/opt/xray-agent/xray/error.log",
    "loglevel": "warning",
    "dnsLog": false
  }
}
EOF
    fi

    if [[ ! -f "/opt/xray-agent/xray/conf/12_policy.json" ]]; then

        cat <<EOF >/opt/xray-agent/xray/conf/12_policy.json
{
  "policy": {
      "levels": {
          "0": {
              "handshake": $((1 + RANDOM % 4)),
              "connIdle": $((250 + RANDOM % 51))
          }
      }
  }
}
EOF
    fi

    addXrayOutbound "z_direct_outbound"
    # dns
    if [[ ! -f "/opt/xray-agent/xray/conf/11_dns.json" ]]; then
        cat <<EOF >/opt/xray-agent/xray/conf/11_dns.json
{
    "dns": {
        "servers": [
          "localhost"
        ]
  }
}
EOF
    fi
    # routing
    cat <<EOF >/opt/xray-agent/xray/conf/09_routing.json
{
  "routing": {
    "rules": [
      {
        "type": "field",
        "domain": [
          "domain:gstatic.com",
          "domain:googleapis.com",
	  "domain:googleapis.cn"
        ],
        "outboundTag": "z_direct_outbound"
      }
    ]
  }
}
EOF
    # VLESS_TCP_TLS_Vision
    # Fall back to nginx
    local fallbacksList='{"dest":31300,"xver":1},{"alpn":"h2","dest":31302,"xver":1}'

    # VLESS_WS_TLS
    if hasProtocol "${selectCustomInstallType}" 1; then
        fallbacksList=${fallbacksList}',{"path":"/'${customPath}'","dest":31297,"xver":1}'
        cat <<EOF >/opt/xray-agent/xray/conf/03_VLESS_WS_inbounds.json
{
"inbounds":[
    {
      "port": 31297,
      "listen": "127.0.0.1",
      "protocol": "vless",
      "tag":"VLESSWS",
      "settings": {
        "clients": $(initXrayClients 1),
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "security": "none",
        "wsSettings": {
          "acceptProxyProtocol": true,
          "path": "/${customPath}"
        }
      }
    }
]
}
EOF
    elif [[ -z "$3" ]]; then
        rm /opt/xray-agent/xray/conf/03_VLESS_WS_inbounds.json >/dev/null 2>&1
    fi

    # Hysteria2 over QUIC/UDP, implemented directly by Xray-core.
    if hasProtocol "${selectCustomInstallType}" 6; then
        echoContent skyBlue "\n===================== 配置Hysteria2+TLS =====================\n"
        initHysteria2Port
        initHysteria2BbrProfile
        initHysteria2Masquerade
        # "clients" works on every supported core. v26.5.9+ also accepts
        # "users", but stable v26.3.27 silently ignores it (no accounts, every
        # auth fails), which would break a rollback from a pre-release.
        local hysteria2UserField="clients"
        cat <<EOF >/opt/xray-agent/xray/conf/05_hysteria2_inbounds.json
{
  "inbounds": [
    {
      "port": ${hysteria2Port},
      "listen": "0.0.0.0",
      "protocol": "hysteria",
      "tag": "Hysteria2",
      "settings": {
        "version": 2,
        "${hysteria2UserField}": $(initXrayHysteria2Clients)
      },
      "streamSettings": {
        "network": "hysteria",
        "security": "tls",
        "tlsSettings": {
          "rejectUnknownSni": true,
          "minVersion": "1.3",
          "alpn": ["h3"],
          "certificates": [
            {
              "certificateFile": "/opt/xray-agent/tls/${domain}.crt",
              "keyFile": "/opt/xray-agent/tls/${domain}.key",
              "ocspStapling": 3600
            }
          ]
        },
        "hysteriaSettings": {
          "version": 2,
          "udpIdleTimeout": 60,
          "masquerade": ${hysteria2MasqueradeConfig}
        },
        "finalmask": {
          "quicParams": {
            "congestion": "bbr",
            "bbrProfile": "${hysteria2BbrProfile}"
          }
        }
      }
    }
  ]
}
EOF
        # Masquerading turned off: drop the key instead of keeping "null".
        if [[ "${hysteria2MasqueradeConfig}" == "null" ]]; then
            local withoutMasquerade
            withoutMasquerade=$(jq 'del(.inbounds[0].streamSettings.hysteriaSettings.masquerade)' \
                /opt/xray-agent/xray/conf/05_hysteria2_inbounds.json) \
                && echo "${withoutMasquerade}" >/opt/xray-agent/xray/conf/05_hysteria2_inbounds.json
        fi
    elif [[ -z "$3" ]]; then
        rm /opt/xray-agent/xray/conf/05_hysteria2_inbounds.json >/dev/null 2>&1
    fi
    # VLESS Vision
    if hasProtocol "${selectCustomInstallType}" 0; then

        cat <<EOF >/opt/xray-agent/xray/conf/02_VLESS_TCP_inbounds.json
{
    "inbounds":[
        {
          "port": ${port},
          "protocol": "vless",
          "tag":"VLESSTCP",
          "settings": {
            "clients":$(initXrayClients 0),
            "decryption": "none",
            "fallbacks": [
                ${fallbacksList}
            ]
          },
          "add": "${add}",
          "streamSettings": {
            "network": "tcp",
            "security": "tls",
            "tlsSettings": {
              "rejectUnknownSni": true,
              "minVersion": "1.2",
              "certificates": [
                {
                  "certificateFile": "/opt/xray-agent/tls/${domain}.crt",
                  "keyFile": "/opt/xray-agent/tls/${domain}.key",
                  "ocspStapling": 3600
                }
              ]
            }
          }
        }
    ]
}
EOF
    elif [[ -z "$3" ]]; then
        rm /opt/xray-agent/xray/conf/02_VLESS_TCP_inbounds.json >/dev/null 2>&1
    fi

    # REALITY: one identity (target, keys) shared by both REALITY inbounds.
    if hasProtocol "${selectCustomInstallType}" 3 || hasProtocol "${selectCustomInstallType}" 12; then
        echoContent skyBlue "\n===================== 配置 REALITY =====================\n"
        initRealityClientServersName
        initRealityKey
        initRealityMldsa65
    fi

    # VLESS_TCP/reality
    if hasProtocol "${selectCustomInstallType}" 3; then
        initXrayRealityPort

        cat <<EOF >/opt/xray-agent/xray/conf/07_VLESS_vision_reality_inbounds.json
{
  "inbounds": [
    {
      "port": ${realityPort},
      "protocol": "vless",
      "tag": "VLESSReality",
      "settings": {
        "clients": $(initXrayClients 3),
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
            "show": false,
            "dest": "${realityServerName}:${realityDomainPort}",
            "xver": 0,
            "serverNames": [
                "${realityServerName}"
            ],
            "privateKey": "${realityPrivateKey}",
            "publicKey": "${realityPublicKey}",
            "mldsa65Seed": "${realityMldsa65Seed}",
            "mldsa65Verify": "${realityMldsa65Verify}",
            "maxTimeDiff": 70000,
            "shortIds": [
                "",
                "6ba85179e30d4fc2"
            ]
        }
      }
    }
  ]
}
EOF
    elif [[ -z "$3" ]]; then
        rm /opt/xray-agent/xray/conf/07_VLESS_vision_reality_inbounds.json >/dev/null 2>&1
    fi

    # VLESS + XHTTP + REALITY: direct, no domain needed, its own port.
    if hasProtocol "${selectCustomInstallType}" 12; then
        initXrayXhttpRealityPort
        jq -n --argjson port "${xhttpRealityPort}" --arg path "/${customPath}xhttp" \
            --argjson clients "$(initXrayClients 12)" --arg sni "${realityServerName}" \
            --arg dest "${realityServerName}:${realityDomainPort}" --arg privateKey "${realityPrivateKey}" \
            --arg publicKey "${realityPublicKey}" --arg seed "${realityMldsa65Seed}" --arg verify "${realityMldsa65Verify}" '
            {inbounds:[{
                port:$port, protocol:"vless", tag:"VLESSRealityXHTTP",
                settings:{clients:$clients, decryption:"none"},
                streamSettings:{
                    network:"xhttp", security:"reality", xhttpSettings:{path:$path},
                    realitySettings:({show:false, dest:$dest, xver:0, serverNames:[$sni],
                        privateKey:$privateKey, publicKey:$publicKey, maxTimeDiff:70000,
                        shortIds:["", "6ba85179e30d4fc2"]}
                        + (if $seed != "" then {mldsa65Seed:$seed, mldsa65Verify:$verify} else {} end))
                }
            }]}' >/opt/xray-agent/xray/conf/12_VLESS_XHTTP_inbounds.json || return 1
    elif [[ -z "$3" ]]; then
        rm -f /opt/xray-agent/xray/conf/12_VLESS_XHTTP_inbounds.json
    fi

    # VLESS + XHTTP + TLS: nginx (the Vision fallback, or a panel site on
    # 443) terminates TLS and grpc_passes the path to this local inbound.
    if hasProtocol "${selectCustomInstallType}" 14; then
        jq -n --argjson port "${xhttpInboundPort}" --arg path "/${customPath}xhttp" \
            --arg trusted "${xhttpTrustedHeader}" --argjson clients "$(initXrayClients 14)" '
            {inbounds:[{
                listen:"127.0.0.1", port:$port, protocol:"vless", tag:"VLESSXHTTP",
                settings:{clients:$clients, decryption:"none"},
                streamSettings:{network:"xhttp", xhttpSettings:{path:$path},
                    sockopt:{trustedXForwardedFor:[$trusted]}}
            }]}' >/opt/xray-agent/xray/conf/14_VLESS_XHTTP_TLS_inbounds.json || return 1
    elif [[ -z "$3" ]]; then
        rm -f /opt/xray-agent/xray/conf/14_VLESS_XHTTP_TLS_inbounds.json
    fi
    installSniffing
    if [[ -z "$3" ]]; then
        removeXrayOutbound wireguard_out_IPv4_route
        removeXrayOutbound wireguard_out_IPv6_route
        removeXrayOutbound wireguard_outbound
        removeXrayOutbound IPv4_out
        removeXrayOutbound IPv6_out
        removeXrayOutbound socks5_outbound
        removeXrayOutbound blackhole_out
        removeXrayOutbound wireguard_out_IPv6
        removeXrayOutbound wireguard_out_IPv4
        addXrayOutbound z_direct_outbound
    fi
}
# Accounts
showAccounts() {
    readInstallType
    readInstallProtocolType
    readConfigHostPathUUID

    echo
    echoContent skyBlue "\n进度 $1/${totalProgress} : 账号"

    initSubscribeLocalConfig
    # VLESS TCP
    if echo ${currentInstallProtocolType} | grep -q ",0,"; then

        echoContent skyBlue "============================= VLESS TCP TLS_Vision [推荐] ==============================\n"
        jq -c '.inbounds[0].settings.clients//.inbounds[0].users//[] | .[]' ${configPath}02_VLESS_TCP_inbounds.json | while read -r user; do
            local email=
            email=$(echo "${user}" | jq -r .email//.name)

            echoContent skyBlue "\n ---> 账号:${email}"
            echo
            defaultBase64Code vlesstcp "${currentDefaultPort}" "${email}" "$(echo "${user}" | jq -r .id//.uuid)"
        done
    fi

    # VLESS WS
    if echo ${currentInstallProtocolType} | grep -q ",1,"; then
        echoContent skyBlue "\n================================ VLESS WS TLS [仅CDN推荐] ================================\n"

        jq -c '.inbounds[0].settings.clients//.inbounds[0].users//[] | .[]' ${configPath}03_VLESS_WS_inbounds.json | while read -r user; do
            local email=
            email=$(echo "${user}" | jq -r .email//.name)

            local vlessWSPort=${currentDefaultPort}
            echo
            local path="/${currentPath}"

            local count=
            while read -r line; do
                echoContent skyBlue "\n ---> 账号:${email}${count}"
                if [[ -n "${line}" ]]; then
                    defaultBase64Code vlessws "${vlessWSPort}" "${email}${count}" "$(echo "${user}" | jq -r .id//.uuid)" "${line}" "${path}"
                    count=$((count + 1))
                    echo
                fi
            done < <(echo "${currentCDNAddress}" | tr ',' '\n')
        done
    fi

    # VLESS XHTTP TLS (nginx: Vision fallback or the panel site on 443)
    if hasProtocol "${currentInstallProtocolType}" 14; then
        echoContent skyBlue "\n============================= VLESS XHTTP TLS [443/CDN推荐] =============================\n"
        local xhttpPort
        xhttpPort=$(cat "${xhttpStateFile}" 2>/dev/null)
        xhttpPort=${xhttpPort:-${currentDefaultPort}}
        jq -c '.inbounds[0].settings.clients//.inbounds[0].users//[] | .[]' "${configPath}14_VLESS_XHTTP_TLS_inbounds.json" | while read -r user; do
            local email count=
            email=$(echo "${user}" | jq -r .email//.name)
            while read -r line; do
                [[ -n "${line}" ]] || continue
                echoContent skyBlue "\n ---> 账号:${email}${count}"
                defaultBase64Code vlessXhttp "${xhttpPort}" "${email}${count}" "$(echo "${user}" | jq -r .id//.uuid)" "${line}" "${currentXhttpPath}"
                count=$((count + 1))
            done < <(echo "${currentCDNAddress}" | tr ',' '\n')
        done
    fi

    # Hysteria2
    if echo ${currentInstallProtocolType} | grep -q ",6,"; then
        echoContent skyBlue "\n================================ Hysteria2 TLS/QUIC [游戏推荐] ================================\n"
        jq -c '(.inbounds[0].settings.clients // .inbounds[0].settings.users // [])[]' "${configPath}05_hysteria2_inbounds.json" | while read -r user; do
            local email=
            email=$(echo "${user}" | jq -r '.email')
            echoContent skyBlue "\n ---> 账号:${email}"
            echo
            defaultBase64Code hysteria "${hysteria2Port}" "${email}" "$(echo "${user}" | jq -r '.auth')"
        done
    fi
    # VLESS reality vision
    if echo ${currentInstallProtocolType} | grep -q ",3,"; then
        echoContent skyBlue "============================= VLESS reality_vision [推荐]  ==============================\n"
        jq -c '.inbounds[0].settings.clients//.inbounds[0].users//[] | .[]' ${configPath}07_VLESS_vision_reality_inbounds.json | while read -r user; do
            local email=
            email=$(echo "${user}" | jq -r .email//.name)

            echoContent skyBlue "\n ---> 账号:${email}"
            echo
            defaultBase64Code vlessReality "${xrayVLESSRealityVisionPort}" "${email}" "$(echo "${user}" | jq -r .id//.uuid)"
        done
    fi

    # VLESS XHTTP REALITY
    if hasProtocol "${currentInstallProtocolType}" 12; then
        echoContent skyBlue "\n============================ VLESS XHTTP Reality [无需域名] ============================\n"
        jq -c '.inbounds[0].settings.clients//.inbounds[0].users//[] | .[]' "${configPath}12_VLESS_XHTTP_inbounds.json" | while read -r user; do
            local email=
            email=$(echo "${user}" | jq -r .email//.name)
            echoContent skyBlue "\n ---> 账号:${email}"
            echo
            defaultBase64Code vlessXhttpReality "${xrayXhttpRealityPort}" "${email}" "$(echo "${user}" | jq -r .id//.uuid)" "" "${currentXhttpPath}"
        done
    fi
}

# Percent-encode a string for URLs (share links, QR codes).
urlEncode() {
    jq -rn --arg value "$1" '$value | @uri'
}
initSubscribeLocalConfig() {
    rm -rf /opt/xray-agent/subscribe_local/sing-box/*
}
# Common
defaultBase64Code() {
    local type=$1
    local port=$2
    local email=$3
    local id=$4
    local add=$5
    local path=$6
    case "${type}" in
        vlesstcp | vlessws | vlessReality | hysteria | vlessXhttp | vlessXhttpReality) ;;
        *)
            echoContent red " ---> 当前脚本不再支持该协议: ${type}"
            return 1
            ;;
    esac
    local user=
    user=$(normalizeXrayEmail "${email}")
    if [[ ! -f "/opt/xray-agent/subscribe_local/sing-box/${user}" ]]; then
        echo [] >"/opt/xray-agent/subscribe_local/sing-box/${user}"
    fi
    local singBoxSubscribeLocalConfig=
    if [[ "${type}" == "vlesstcp" ]]; then

        echoContent yellow " ---> 通用格式(VLESS+TCP+TLS_Vision)"
        echoContent green "    vless://${id}@${currentHost}:${port}?encryption=none&security=tls&fp=chrome&type=tcp&host=${currentHost}&headerType=none&sni=${currentHost}&flow=xtls-rprx-vision#${email}\n"

        echoContent yellow " ---> 格式化明文(VLESS+TCP+TLS_Vision)"
        echoContent green "协议类型:VLESS，地址:${currentHost}，端口:${port}，用户ID:${id}，安全:tls，client-fingerprint: chrome，传输方式:tcp，flow:xtls-rprx-vision，账户名:${email}\n"
        cat <<EOF >>"/opt/xray-agent/subscribe_local/default/${user}"
vless://${id}@${currentHost}:${port}?encryption=none&security=tls&type=tcp&host=${currentHost}&fp=chrome&headerType=none&sni=${currentHost}&flow=xtls-rprx-vision#${email}
EOF
        cat <<EOF >>"/opt/xray-agent/subscribe_local/clashMeta/${user}"
  - name: "${email}"
    type: vless
    server: ${currentHost}
    port: ${port}
    uuid: ${id}
    network: tcp
    tls: true
    udp: true
    flow: xtls-rprx-vision
    client-fingerprint: chrome
EOF
        singBoxSubscribeLocalConfig=$(jq -r --arg email "${email}" --arg host "${currentHost}" --arg id "${id}" --argjson port "${port}" '. += [{tag:$email,type:"vless",server:$host,server_port:$port,uuid:$id,flow:"xtls-rprx-vision",tls:{enabled:true,server_name:$host,utls:{enabled:true,fingerprint:"chrome"}},packet_encoding:"xudp"}]' "/opt/xray-agent/subscribe_local/sing-box/${user}")
        echo "${singBoxSubscribeLocalConfig}" | jq . >"/opt/xray-agent/subscribe_local/sing-box/${user}"

        echoContent yellow " ---> 二维码 VLESS(VLESS+TCP+TLS_Vision)"
        echoContent green "    https://api-qr-server.zwen.cc/v1/create-qr-code/?size=400x400&data=vless%3A%2F%2F${id}%40${currentHost}%3A${port}%3Fencryption%3Dnone%26fp%3Dchrome%26security%3Dtls%26type%3Dtcp%26${currentHost}%3D${currentHost}%26headerType%3Dnone%26sni%3D${currentHost}%26flow%3Dxtls-rprx-vision%23${email}\n"

    elif [[ "${type}" == "vlessws" ]]; then

        echoContent yellow " ---> 通用格式(VLESS+WS+TLS)"
        echoContent green "    vless://${id}@${add}:${port}?encryption=none&security=tls&type=ws&host=${currentHost}&sni=${currentHost}&fp=chrome&path=${path}#${email}\n"

        echoContent yellow " ---> 格式化明文(VLESS+WS+TLS)"
        echoContent green "    协议类型:VLESS，地址:${add}，伪装域名/SNI:${currentHost}，端口:${port}，client-fingerprint: chrome,用户ID:${id}，安全:tls，传输方式:ws，路径:${path}，账户名:${email}\n"

        cat <<EOF >>"/opt/xray-agent/subscribe_local/default/${user}"
vless://${id}@${add}:${port}?encryption=none&security=tls&type=ws&host=${currentHost}&sni=${currentHost}&fp=chrome&path=${path}#${email}
EOF
        cat <<EOF >>"/opt/xray-agent/subscribe_local/clashMeta/${user}"
  - name: "${email}"
    type: vless
    server: ${add}
    port: ${port}
    uuid: ${id}
    udp: true
    tls: true
    network: ws
    client-fingerprint: chrome
    servername: ${currentHost}
    ws-opts:
      path: ${path}
      headers:
        Host: ${currentHost}
EOF

        singBoxSubscribeLocalConfig=$(jq -r --arg email "${email}" --arg server "${add}" --arg host "${currentHost}" --arg id "${id}" --arg path "${path}" --argjson port "${port}" '. += [{tag:$email,type:"vless",server:$server,server_port:$port,uuid:$id,tls:{enabled:true,server_name:$host,utls:{enabled:true,fingerprint:"chrome"}},multiplex:{enabled:false,protocol:"smux",max_streams:32},packet_encoding:"xudp",transport:{type:"ws",path:$path,headers:{Host:$host}}}]' "/opt/xray-agent/subscribe_local/sing-box/${user}")
        echo "${singBoxSubscribeLocalConfig}" | jq . >"/opt/xray-agent/subscribe_local/sing-box/${user}"

        echoContent yellow " ---> 二维码 VLESS(VLESS+WS+TLS)"
        echoContent green "    https://api-qr-server.zwen.cc/v1/create-qr-code/?size=400x400&data=vless%3A%2F%2F${id}%40${add}%3A${port}%3Fencryption%3Dnone%26security%3Dtls%26type%3Dws%26host%3D${currentHost}%26fp%3Dchrome%26sni%3D${currentHost}%26path%3D${path}%23${email}"

    elif [[ "${type}" == "vlessXhttp" ]]; then
        # Xray-first: sing-box has no XHTTP, so no sing-box entry is written.
        local link
        link="vless://${id}@${add}:${port}?encryption=none&security=tls&type=xhttp&sni=${currentHost}&host=${currentHost}&fp=chrome&alpn=h2&path=$(urlEncode "${path}")&mode=auto#${email}"
        echoContent yellow " ---> 通用格式(VLESS+XHTTP+TLS)"
        echoContent green "    ${link}\n"
        echoContent yellow " ---> 格式化明文(VLESS+XHTTP+TLS)"
        echoContent green "    协议类型:VLESS，地址:${add}，SNI/Host:${currentHost}，端口:${port}，用户ID:${id}，安全:tls，传输方式:xhttp，路径:${path}，mode:auto，账户名:${email}\n"
        echo "${link}" >>"/opt/xray-agent/subscribe_local/default/${user}"
        cat <<EOF >>"/opt/xray-agent/subscribe_local/clashMeta/${user}"
  - name: "${email}"
    type: vless
    server: ${add}
    port: ${port}
    uuid: ${id}
    udp: true
    tls: true
    network: xhttp
    packet-encoding: xudp
    client-fingerprint: chrome
    alpn: [h2]
    servername: ${currentHost}
    xhttp-opts:
      path: ${path}
      host: ${currentHost}
      mode: auto
EOF
        echoContent yellow " ---> 二维码 VLESS(VLESS+XHTTP+TLS)"
        echoContent green "    https://api-qr-server.zwen.cc/v1/create-qr-code/?size=400x400&data=$(urlEncode "${link}")\n"

    elif [[ "${type}" == "vlessXhttpReality" ]]; then
        local link pqvParam=
        [[ -n "${currentRealityMldsa65Verify}" && "${currentRealityMldsa65Verify}" != "null" ]] && pqvParam="&pqv=${currentRealityMldsa65Verify}"
        link="vless://${id}@$(getPublicIP):${port}?encryption=none&security=reality&type=xhttp&sni=${xrayVLESSRealityServerName}&fp=chrome&pbk=${currentRealityPublicKey}&sid=6ba85179e30d4fc2${pqvParam}&path=$(urlEncode "${path}")&mode=auto#${email}"
        echoContent yellow " ---> 通用格式(VLESS+XHTTP+Reality)"
        echoContent green "    ${link}\n"
        echoContent yellow " ---> 格式化明文(VLESS+XHTTP+Reality)"
        echoContent green "    协议类型:VLESS reality，地址:$(getPublicIP)，端口:${port}，publicKey:${currentRealityPublicKey}，shortId:6ba85179e30d4fc2，serverName:${xrayVLESSRealityServerName}，传输方式:xhttp，路径:${path}，用户ID:${id}，账户名:${email}\n"
        echo "${link}" >>"/opt/xray-agent/subscribe_local/default/${user}"
        cat <<EOF >>"/opt/xray-agent/subscribe_local/clashMeta/${user}"
  - name: "${email}"
    type: vless
    server: $(getPublicIP)
    port: ${port}
    uuid: ${id}
    udp: true
    tls: true
    network: xhttp
    client-fingerprint: chrome
    servername: ${xrayVLESSRealityServerName}
    xhttp-opts:
      path: ${path}
      mode: auto
    reality-opts:
      public-key: ${currentRealityPublicKey}
      short-id: 6ba85179e30d4fc2
EOF
        echoContent yellow " ---> 二维码 VLESS(VLESS+XHTTP+Reality)"
        echoContent green "    https://api-qr-server.zwen.cc/v1/create-qr-code/?size=400x400&data=$(urlEncode "${link}")\n"

    elif [[ "${type}" == "hysteria" ]]; then
        # Port hopping, in each client's own format: v2rayN/v2rayNG read the
        # "mport" query parameter (they cannot parse the official
        # "host:20000-50000" form), Clash Meta uses "ports", sing-box uses
        # "server_ports" with a colon range.
        local link portHop
        portHop=$(currentPortHopRange || true)
        link="hysteria2://${id}@${currentHost}:${port}/?sni=${currentHost}&alpn=h3&insecure=0${portHop:+&mport=${portHop}}#${email}"
        echoContent yellow " ---> 通用格式(Hysteria2+TLS+QUIC)"
        echoContent green "    ${link}\n"
        if [[ -n "${portHop}" ]]; then
            echoContent yellow "    端口跳跃: UDP ${portHop}，间隔 ${hysteria2PortHopInterval}s\n"
        fi
        echo "${link}" >>"/opt/xray-agent/subscribe_local/default/${user}"

        {
            echo "  - name: \"${email}\""
            echo "    type: hysteria2"
            echo "    server: ${currentHost}"
            echo "    port: ${port}"
            if [[ -n "${portHop}" ]]; then
                echo "    ports: ${portHop}"
                echo "    hop-interval: ${hysteria2PortHopInterval}"
            fi
            echo "    password: ${id}"
            echo "    sni: ${currentHost}"
            echo "    alpn:"
            echo "      - h3"
            echo "    skip-cert-verify: false"
        } >>"/opt/xray-agent/subscribe_local/clashMeta/${user}"

        singBoxSubscribeLocalConfig=$(jq --arg tag "${email}" --arg server "${currentHost}" --argjson port "${port}" --arg password "${id}" \
            --arg portHop "${portHop}" --arg interval "${hysteria2PortHopInterval}s" '
            . += [{tag:$tag,type:"hysteria2",server:$server,server_port:$port,password:$password,
                   tls:{enabled:true,server_name:$server,alpn:["h3"],insecure:false}}
                  + (if $portHop == "" then {} else {server_ports:[$portHop | sub("-"; ":")], hop_interval:$interval} end)]' \
            "/opt/xray-agent/subscribe_local/sing-box/${user}")
        echo "${singBoxSubscribeLocalConfig}" | jq . >"/opt/xray-agent/subscribe_local/sing-box/${user}"

        echoContent yellow " ---> 二维码 Hysteria2(TLS)"
        echoContent green "    https://api-qr-server.zwen.cc/v1/create-qr-code/?size=400x400&data=$(urlEncode "${link}")\n"

    elif [[ "${type}" == "vlessReality" ]]; then
        local realityServerName=${xrayVLESSRealityServerName}
        local publicKey=${currentRealityPublicKey}
        local realityMldsa65Verify=${currentRealityMldsa65Verify}

        echoContent yellow " ---> 通用格式(VLESS+reality+uTLS+Vision)"
        echoContent green "    vless://${id}@$(getPublicIP):${port}?encryption=none&security=reality&pqv=${realityMldsa65Verify}&type=tcp&sni=${realityServerName}&fp=chrome&pbk=${publicKey}&sid=6ba85179e30d4fc2&flow=xtls-rprx-vision#${email}\n"

        echoContent yellow " ---> 格式化明文(VLESS+reality+uTLS+Vision)"
        echoContent green "协议类型:VLESS reality，地址:$(getPublicIP)，publicKey:${publicKey}，shortId: 6ba85179e30d4fc2，pqv=${realityMldsa65Verify}，serverNames：${realityServerName}，端口:${port}，用户ID:${id}，传输方式:tcp，账户名:${email}\n"
        cat <<EOF >>"/opt/xray-agent/subscribe_local/default/${user}"
vless://${id}@$(getPublicIP):${port}?encryption=none&security=reality&pqv=${realityMldsa65Verify}&type=tcp&sni=${realityServerName}&fp=chrome&pbk=${publicKey}&sid=6ba85179e30d4fc2&flow=xtls-rprx-vision#${email}
EOF
        cat <<EOF >>"/opt/xray-agent/subscribe_local/clashMeta/${user}"
  - name: "${email}"
    type: vless
    server: $(getPublicIP)
    port: ${port}
    uuid: ${id}
    network: tcp
    tls: true
    udp: true
    flow: xtls-rprx-vision
    servername: ${realityServerName}
    reality-opts:
      public-key: ${publicKey}
      short-id: 6ba85179e30d4fc2
    client-fingerprint: chrome
EOF

        singBoxSubscribeLocalConfig=$(jq --arg tag "${email}" --arg server "$(getPublicIP)" --argjson port "${port}" --arg uuid "${id}" \
            --arg serverName "${realityServerName}" --arg publicKey "${publicKey}" \
            '. += [{tag:$tag,type:"vless",server:$server,server_port:$port,uuid:$uuid,flow:"xtls-rprx-vision",
                    tls:{enabled:true,server_name:$serverName,utls:{enabled:true,fingerprint:"chrome"},
                         reality:{enabled:true,public_key:$publicKey,short_id:"6ba85179e30d4fc2"}},
                    packet_encoding:"xudp"}]' \
            "/opt/xray-agent/subscribe_local/sing-box/${user}")
        echo "${singBoxSubscribeLocalConfig}" | jq . >"/opt/xray-agent/subscribe_local/sing-box/${user}"

        echoContent yellow " ---> 二维码 VLESS(VLESS+reality+uTLS+Vision)"
        echoContent green "    https://api-qr-server.zwen.cc/v1/create-qr-code/?size=400x400&data=vless%3A%2F%2F${id}%40$(getPublicIP)%3A${port}%3Fencryption%3Dnone%26security%3Dreality%26type%3Dtcp%26sni%3D${realityServerName}%26fp%3Dchrome%26pbk%3D${publicKey}%26sid%3D6ba85179e30d4fc2%26flow%3Dxtls-rprx-vision%23${email}\n"

    fi

}

# Remove the nginx 302 config
removeNginx302() {
    # Check that the config file exists
    if [[ ! -f "${nginxConfigPath}xray-agent.conf" ]]; then
        echoContent red " ---> 配置文件不存在: ${nginxConfigPath}xray-agent.conf"
        echoContent yellow " ---> 请先完成 Xray 安装后再使用此功能"
        return 1
    fi

    # Use a temp file to avoid modifying the original file inside the loop
    local tmpFile="${nginxConfigPath}xray-agent.conf.tmp"
    cp "${nginxConfigPath}xray-agent.conf" "${tmpFile}"

    # Delete all return 302/301 lines (excluding those containing request_uri)
    sed -i '/return 30[12]/!b; /request_uri/b; d' "${tmpFile}"

    # Replace the original file
    mv "${tmpFile}" "${nginxConfigPath}xray-agent.conf"
}

# Check whether the 302 redirect succeeded
checkNginx302() {
    local testHost="${currentHost}"
    local testPort="${currentPort}"

    if [[ -z "${testHost}" || "${testHost}" == "null" ]]; then
        testHost=$(getPublicIP)
    fi
    if [[ -z "${testHost}" ]]; then
        testHost="127.0.0.1"
    fi

    if [[ -z "${testPort}" || "${testPort}" == "null" ]]; then
        if [[ -n "${currentDefaultPort}" ]]; then
            testPort="${currentDefaultPort}"
        else
            testPort=443
        fi
    fi

    local scheme="https"
    if [[ "${testPort}" == "80" ]]; then
        scheme="http"
    fi

    local targetUrl="${scheme}://${testHost}:${testPort}"
    local httpCode=
    httpCode=$(curl -I -k --connect-timeout 5 -s -o /dev/null -w "%{http_code}" "${targetUrl}")

    if [[ "${httpCode}" == "302" ]]; then
        echoContent green " ---> 重定向设置完毕 (HTTP ${httpCode})"
        exit 0
    fi

    echoContent red " ---> 重定向设置失败，HTTP状态码: ${httpCode}"
    echoContent yellow " ---> 检测 URL: ${targetUrl}"
    echoContent yellow "请检查配置是否正确"
    backupNginxConfig restoreBackup
    handleNginx stop >/dev/null 2>&1
    handleNginx start >/dev/null 2>&1
}

# Back up/restore the nginx file
backupNginxConfig() {
    if [[ "$1" == "backup" ]]; then
        if [[ ! -f "${nginxConfigPath}xray-agent.conf" ]]; then
            echoContent red " ---> 配置文件不存在: ${nginxConfigPath}xray-agent.conf"
            echoContent yellow " ---> 请先完成 Xray 安装后再使用此功能"
            return 1
        fi
        cp ${nginxConfigPath}xray-agent.conf /opt/xray-agent/xray-agent_backup.conf
        echoContent green " ---> nginx配置文件备份成功"
    fi

    if [[ "$1" == "restoreBackup" ]] && [[ -f "/opt/xray-agent/xray-agent_backup.conf" ]]; then
        cp /opt/xray-agent/xray-agent_backup.conf ${nginxConfigPath}xray-agent.conf
        echoContent green " ---> nginx配置文件恢复备份成功"
        rm /opt/xray-agent/xray-agent_backup.conf
    fi

}
# Add the 302 config
addNginx302() {
    local redirectUrl="$1"
    local redirectCode="302" # Always use 302

    # Check that the config file exists
    if [[ ! -f "${nginxConfigPath}xray-agent.conf" ]]; then
        echoContent red " ---> 配置文件不存在: ${nginxConfigPath}xray-agent.conf"
        echoContent yellow " ---> 请先完成 Xray 安装后再使用此功能"
        backupNginxConfig restoreBackup
        return 1
    fi

    # Validate the URL format
    if [[ ! "${redirectUrl}" =~ ^https?:// ]]; then
        echoContent red " ---> URL 格式错误，必须以 http:// 或 https:// 开头"
        backupNginxConfig restoreBackup
        return 1
    fi

    # Escape special characters (single quotes)
    redirectUrl="${redirectUrl//\'/\'\\\'\'}"

    # Read the line numbers of all `location / {` into an array
    local lineNumbers=()
    while IFS= read -r line; do
        lineNumbers+=("$(echo "${line}" | awk -F ":" '{print $1}')")
    done < <(grep -n "location / {" "${nginxConfigPath}xray-agent.conf")

    # Insert from back to front so line numbers do not shift
    local count=${#lineNumbers[@]}
    for ((i = count - 1; i >= 0; i--)); do
        local insertIndex=$((lineNumbers[i] + 1))
        sed -i "${insertIndex}i\\        return ${redirectCode} '${redirectUrl}';" "${nginxConfigPath}xray-agent.conf"
    done

    if [[ ${count} -eq 0 ]]; then
        echoContent red " ---> 重定向添加失败：未找到 location / { 配置"
        backupNginxConfig restoreBackup
        return 1
    fi

    echoContent green " ---> 已在 ${count} 处添加 ${redirectCode} 重定向"
}

# Update the masquerade site
updateNginxBlog() {
    echoContent skyBlue "\n进度 $1/${totalProgress} : 更换伪装站点"

    if ! echo "${currentInstallProtocolType}" | grep -q ",0," || [[ -z "${coreInstallType}" ]]; then
        echoContent red "\n ---> 由于环境依赖，请先安装Xray-core的VLESS_TCP_TLS_Vision"
        exit 0
    fi
    echoContent red "=============================================================="
    echoContent yellow "# 如需自定义，请手动复制模版文件到 ${nginxStaticPath} \n"
    echoContent yellow "1.新手引导"
    echoContent yellow "2.游戏网站"
    echoContent yellow "3.个人博客01"
    echoContent yellow "4.企业站"
    echoContent yellow "5.解锁加密的音乐文件模版[https://github.com/ix64/unlock-music]"
    echoContent yellow "6.mikutap[https://github.com/HFIProgramming/mikutap]"
    echoContent yellow "7.企业站02"
    echoContent yellow "8.个人博客02"
    echoContent yellow "9.404自动跳转baidu"
    echoContent yellow "10.重定向网站（不使用伪装站）"
    echoContent red "=============================================================="
    read -r -p "请选择:" selectInstallNginxBlogType

    if [[ "${selectInstallNginxBlogType}" == "10" ]]; then
        echoContent red "\n=============================================================="
        echoContent skyBlue "📌 重定向配置说明："
        echoContent yellow "• 重定向会替代伪装站点，根路由 / 将直接跳转"
        echoContent yellow "• 代理路径（如 /your-path）不受影响，正常使用"
        echoContent yellow "1.添加重定向"
        echoContent yellow "2.删除重定向"
        echoContent red "=============================================================="
        read -r -p "请选择:" redirectStatus

        if [[ "${redirectStatus}" == "1" ]]; then
            backupNginxConfig backup
            echoContent yellow "\n使用 302 临时重定向，便于随时调整目标 URL。"

            read -r -p "请输入要重定向的完整URL:" redirectDomain

            if [[ -z "${redirectDomain}" ]]; then
                echoContent red " ---> 重定向URL不能为空"
                backupNginxConfig restoreBackup
                exit 0
            fi

            removeNginx302
            addNginx302 "${redirectDomain}"
            handleNginx stop
            handleNginx start
            if [[ -z $(pgrep -f "nginx") ]]; then
                backupNginxConfig restoreBackup
                handleNginx start
                exit 0
            fi
            checkNginx302
            exit 0
        fi
        if [[ "${redirectStatus}" == "2" ]]; then
            removeNginx302
            echoContent green " ---> 移除302重定向成功"
            exit 0
        fi
    fi
    if [[ "${selectInstallNginxBlogType}" =~ ^[1-9]$ ]]; then
        deployNginxTemplate "${selectInstallNginxBlogType}" || return 1
        echoContent green " ---> 更换伪站成功"
    else
        echoContent red " ---> 选择错误，请重新选择"
        updateNginxBlog
    fi
}

# Extra ports are dokodemo-door inbounds that forward to the main TLS port.
# Files: 02_dokodemodoor_inbounds_<port>[_default].json, plus
# 02_dokodemodoor_inbounds_hysteria_<port>.json when Hysteria2 is installed.
# The _default marker selects the port used in shared links/subscriptions.

# Print "<port> <file>" for every extra TCP port, sorted by port.
listCorePorts() {
    local file name port
    for file in "${configPath}"02_dokodemodoor_inbounds_*.json; do
        [[ -f "${file}" ]] || continue
        name=${file##*/}
        [[ "${name}" =~ ^02_dokodemodoor_inbounds_([0-9]+)(_default)?\.json$ ]] || continue
        port=${BASH_REMATCH[1]}
        echo "${port} ${file}"
    done | sort -n
}

# Remove exactly the files that belong to one extra port.
removeCorePortFiles() {
    local port=$1
    rm -f "${configPath}02_dokodemodoor_inbounds_${port}.json" \
        "${configPath}02_dokodemodoor_inbounds_${port}_default.json" \
        "${configPath}02_dokodemodoor_inbounds_hysteria_${port}.json"
}

writeCorePortFiles() {
    local port=$1 isDefault=$2 settingsPort=${customPort:-443} fileName
    fileName="${configPath}02_dokodemodoor_inbounds_${port}.json"
    [[ "${isDefault}" == "true" ]] && fileName="${configPath}02_dokodemodoor_inbounds_${port}_default.json"

    jq -n --argjson port "${port}" --argjson target "${settingsPort}" '{inbounds:[{
        listen:"0.0.0.0", port:$port, protocol:"dokodemo-door",
        settings:{address:"127.0.0.1", port:$target, network:"tcp", followRedirect:false},
        tag:("dokodemo-door-newPort-" + ($port | tostring))
    }]}' >"${fileName}" || return 1

    if [[ -n "${hysteria2Port}" ]]; then
        jq -n --argjson port "${port}" --argjson target "${hysteria2Port}" '{inbounds:[{
            listen:"0.0.0.0", port:$port, protocol:"dokodemo-door",
            settings:{address:"127.0.0.1", port:$target, network:"udp", followRedirect:false},
            tag:("dokodemo-door-newPort-hysteria-" + ($port | tostring))
        }]}' >"${configPath}02_dokodemodoor_inbounds_hysteria_${port}.json" || return 1
    fi
}

# Add the given ports; with a default port, move the _default marker to it.
applyCorePorts() {
    local defaultPort=$1 port existing file
    shift
    if [[ -n "${defaultPort}" ]]; then
        # Demote the previous default port instead of deleting it.
        for file in "${configPath}"02_dokodemodoor_inbounds_*_default.json; do
            [[ -f "${file}" ]] && mv "${file}" "${file%_default.json}.json"
        done
    fi
    for port in "$@"; do
        removeCorePortFiles "${port}"
        writeCorePortFiles "${port}" "$([[ "${port}" == "${defaultPort}" ]] && echo true || echo false)" || return 1
    done
}

# Parse "2053,2083 ,2087" into a validated, de-duplicated list in corePortList.
# Empty items (e.g. a trailing comma) are ignored; any invalid item fails.
parseCorePortList() {
    local input=${1//，/,} item
    local -a items=()
    corePortList=()
    IFS=',' read -r -a items <<<"${input}"
    for item in "${items[@]}"; do
        item=${item//[[:space:]]/}
        [[ -z "${item}" ]] && continue
        if ! isValidPort "${item}"; then
            echoContent red " ---> 端口无效: ${item}（需为 1-65535 的数字）"
            return 1
        fi
        [[ " ${corePortList[*]:-} " == *" ${item} "* ]] || corePortList+=("${item}")
    done
    ((${#corePortList[@]} > 0)) || {
        echoContent red " ---> 未输入任何端口"
        return 1
    }
}

# Add a new port
addCorePort() {
    echoContent skyBlue "\n功能 1/${totalProgress} : 添加新端口"
    echoContent red "\n=============================================================="
    echoContent yellow "# 注意事项\n"
    echoContent yellow "支持批量添加"
    echoContent yellow "不影响默认端口的使用"
    echoContent yellow "查看账号时，只会展示默认端口的账号"
    echoContent yellow "不允许有特殊字符，注意逗号的格式"
    echoContent yellow "如已安装Hysteria2，会同时添加Hysteria2的UDP转发端口"
    echoContent yellow "录入示例:2053,2083,2087\n"

    echoContent yellow "1.查看已添加端口"
    echoContent yellow "2.添加端口"
    echoContent yellow "3.删除端口"
    echoContent red "=============================================================="
    local selectNewPortType newPort defaultPort portIndex selected port
    read -r -p "请选择:" selectNewPortType
    case "${selectNewPortType}" in
        1)
            listCorePorts | awk '{print NR ":" $1}'
            ;;
        2)
            read -r -p "请输入端口号:" newPort
            parseCorePortList "${newPort}" || return 1
            read -r -p "请输入默认的端口号，同时会更改订阅端口以及节点端口，[回车]默认443:" defaultPort
            defaultPort=${defaultPort//[[:space:]]/}
            if [[ -n "${defaultPort}" && " ${corePortList[*]} " != *" ${defaultPort} "* ]]; then
                echoContent red " ---> 默认端口必须是本次输入的端口之一"
                return 1
            fi

            for port in "${corePortList[@]}"; do
                allowPort "${port}"
                allowPort "${port}" "udp"
            done
            applyXrayConfigChange "添加端口" applyCorePorts "${defaultPort}" "${corePortList[@]}" || return 1
            echoContent green " ---> 添加完毕"
            restartXray || return 1
            ;;
        3)
            listCorePorts | awk '{print NR ":" $1}'
            read -r -p "请输入要删除的端口编号:" portIndex
            if [[ "${portIndex}" =~ ^[1-9][0-9]*$ ]]; then
                selected=$(listCorePorts | awk -v n="${portIndex}" 'NR == n {print $1}')
            fi
            if [[ -z "${selected}" ]]; then
                echoContent yellow "\n ---> 编号输入错误，请重新选择"
                return 1
            fi
            applyXrayConfigChange "删除端口" removeCorePortFiles "${selected}" || return 1
            echoContent green " ---> 端口 ${selected} 已删除"
            restartXray || return 1
            ;;
        *)
            echoContent red " ---> 选择错误"
            ;;
    esac
}

# Uninstall the script
unInstall() {
    read -r -p "是否确认卸载安装内容？[y/n]:" unInstallStatus
    if [[ "${unInstallStatus}" != "y" ]]; then
        echoContent green " ---> 放弃卸载"
        menu
        exit 0
    fi
    checkBTPanel
    echoContent yellow " ---> 脚本不会删除acme相关配置，删除请手动执行 [rm -rf /root/.acme.sh]"
    handleNginx stop
    if [[ -z $(pgrep -f "nginx") ]]; then
        echoContent green " ---> 停止Nginx成功"
    fi
    if [[ "${coreInstallType}" == "1" ]]; then
        handleXray stop
        rm -rf /etc/systemd/system/xray.service
        echoContent green " ---> 删除Xray开机自启完成"
    fi

    removeAllPanelXhttpLocations
    disablePortHopping
    rm -rf /opt/xray-agent
    rm -rf ${nginxConfigPath}xray-agent.conf
    rm -rf ${nginxConfigPath}checkPortOpen.conf >/dev/null 2>&1
    rm -rf "${nginxConfigPath}sing_box_VMess_HTTPUpgrade.conf" >/dev/null 2>&1
    rm -rf ${nginxConfigPath}checkPortOpen.conf >/dev/null 2>&1

    unInstallSubscribe

    if [[ -d "${nginxStaticPath}" && -f "${nginxStaticPath}/check" ]]; then
        rm -rf "${nginxStaticPath}"
        echoContent green " ---> 删除伪装网站完成"
    fi

    rm -rf /usr/bin/xraya
    rm -rf /usr/sbin/xraya
    echoContent green " ---> 卸载快捷方式完成"
    echoContent green " ---> 卸载脚本完成"
}

# Custom UUID
customUUID() {
    read -r -p "请输入合法的UUID，[回车]随机UUID:" currentCustomUUID
    echo
    if [[ -z "${currentCustomUUID}" ]]; then
        currentCustomUUID=$(${ctlPath} uuid)

        echoContent yellow "uuid：${currentCustomUUID}\n"

    else
        local checkUUID=
        local userConfigFile=
        while IFS= read -r userConfigFile; do
            if jq -e --arg currentUUID "${currentCustomUUID}" '
                any(.inbounds[]?.settings.clients[]?; (.auth // .id // .uuid // "") == $currentUUID) or
                any(.inbounds[]?.settings.users[]?; (.auth // .id // .uuid // "") == $currentUUID)
            ' "${userConfigFile}" >/dev/null 2>&1; then
                checkUUID=true
                break
            fi
        done < <(find "${configPath}" -maxdepth 1 -type f -name '*inbounds.json' 2>/dev/null)

        if [[ -n "${checkUUID}" ]]; then
            echoContent red " ---> UUID不可重复"
            return 1
        fi
    fi
}

# Custom account tag. Xray appends an email suffix per protocol internally, and subscriptions also use it to identify nodes.
customUserEmail() {
    read -r -p "请输入账号标签(tag)，例如 vision_jp_us，[回车]使用 UUID 前缀:" currentCustomEmail
    echo
    if [[ -z "${currentCustomEmail}" ]]; then
        currentCustomEmail=$(echo "${currentCustomUUID}" | cut -d "-" -f 1)
        echoContent yellow "账号标签: ${currentCustomEmail}\n"
    else
        if ! validateXrayUserTag "${currentCustomEmail}"; then
            echoContent red " ---> 标签仅支持字母、数字、点、下划线和连字符，且最长 64 位"
            return 1
        fi
        local checkEmail=
        local userConfigFile=
        while IFS= read -r userConfigFile; do
            if jq -e --arg currentEmail "${currentCustomEmail}" '
                any(
                    (.inbounds[]?.settings.clients[]?, .inbounds[]?.settings.users[]?);
                    ((.email // .name // .username // "") == $currentEmail) or
                    ((.email // .name // .username // "") | startswith($currentEmail + "-"))
                )
            ' "${userConfigFile}" >/dev/null 2>&1; then
                checkEmail=true
                break
            fi
        done < <(find "${configPath}" -maxdepth 1 -type f -name '*inbounds.json' 2>/dev/null)

        if [[ -n "${checkEmail}" ]]; then
            echoContent red " ---> 账号标签不可重复"
            return 1
        fi
    fi
}

# Scan the actual inbound config and return only the protocols that are installed and support account writes.
# Protocols are identified from the JSON content; clientType is only an adapter for each protocol's account structure.
discoverAccountProtocols() {
    accountProtocolFiles=()
    accountProtocolKinds=()
    accountProtocolClientTypes=()
    accountProtocolLabels=()

    local inboundConfig protocol network security version inboundTag port
    local kind clientType label
    while IFS= read -r inboundConfig; do
        protocol=$(jq -r '.inbounds[0].protocol // empty' "${inboundConfig}" 2>/dev/null)
        network=$(jq -r '.inbounds[0].streamSettings.network // empty' "${inboundConfig}" 2>/dev/null)
        security=$(jq -r '.inbounds[0].streamSettings.security // empty' "${inboundConfig}" 2>/dev/null)
        version=$(jq -r '.inbounds[0].settings.version // empty' "${inboundConfig}" 2>/dev/null)
        inboundTag=$(jq -r '.inbounds[0].tag // "untagged"' "${inboundConfig}" 2>/dev/null)
        port=$(jq -r '.inbounds[0].port // "unknown"' "${inboundConfig}" 2>/dev/null)
        kind=
        clientType=
        label=

        case "${protocol}:${network}:${security}" in
            vless:tcp:tls)
                kind=vless
                clientType=0
                label="VLESS + TCP + TLS Vision"
                ;;
            vless:ws:*)
                kind=vless
                clientType=1
                label="VLESS + WebSocket + TLS"
                ;;
            vless:tcp:reality)
                kind=vless
                clientType=3
                label="VLESS + Reality + Vision"
                ;;
            vless:xhttp:reality)
                kind=vless
                clientType=12
                label="VLESS + XHTTP + Reality"
                ;;
            vless:xhttp:*)
                kind=vless
                clientType=14
                label="VLESS + XHTTP + TLS"
                ;;
            hysteria:hysteria:tls)
                [[ "${version}" == "2" ]] || continue
                kind=hysteria2
                clientType=-
                label="Hysteria2"
                ;;
            *) continue ;;
        esac

        accountProtocolFiles+=("${inboundConfig}")
        accountProtocolKinds+=("${kind}")
        accountProtocolClientTypes+=("${clientType}")
        accountProtocolLabels+=("${label} [${inboundTag}, port ${port}]")
    done < <(find "${configPath}" -maxdepth 1 -type f -name '*inbounds.json' -print 2>/dev/null | sort)
}

# Choose which installed protocols the new UUID is added to; press Enter to add it to all of them.
selectUserProtocols() {
    discoverAccountProtocols
    if ((${#accountProtocolFiles[@]} == 0)); then
        echoContent red " ---> 未检测到可添加账号的协议"
        return 1
    fi

    echoContent skyBlue "\n请选择新 UUID 要加入的协议"
    local index
    for ((index = 0; index < ${#accountProtocolFiles[@]}; index++)); do
        echoContent yellow "$((index + 1)).${accountProtocolLabels[index]}"
    done
    local selection
    read -r -p "请选择[可多选，例:1,3；回车=全部]:" selection
    selection=${selection//，/,}

    userSelectedProtocolIndexes=()
    if [[ -z "${selection}" ]]; then
        userSelectedProtocolIndexes=("${!accountProtocolFiles[@]}")
        return 0
    fi

    local -a choices=()
    local choice selectedIndex existing
    IFS=',' read -r -a choices <<<"${selection}"
    for choice in "${choices[@]}"; do
        choice=${choice//[[:space:]]/}
        if [[ ! "${choice}" =~ ^[0-9]+$ ]] || ((choice < 1 || choice > ${#accountProtocolFiles[@]})); then
            echoContent red " ---> 协议选项无效: ${choice}"
            return 1
        fi
        selectedIndex=$((choice - 1))
        existing=false
        for index in "${userSelectedProtocolIndexes[@]}"; do
            [[ "${index}" == "${selectedIndex}" ]] && existing=true
        done
        [[ "${existing}" == "false" ]] && userSelectedProtocolIndexes+=("${selectedIndex}")
    done
}

appendVlessUser() {
    local inboundConfig=$1 clientType=$2 userUUID=$3 userTag=$4
    local client temporaryConfig
    client=$(buildXrayClient "${clientType}" "${userUUID}" "${userTag}") || return 1
    temporaryConfig=$(mktemp "${inboundConfig}.tmp.XXXXXX") || return 1
    if jq --argjson client "${client}" '
        .inbounds[0].settings.clients = ((.inbounds[0].settings.clients // []) + [$client])
    ' "${inboundConfig}" >"${temporaryConfig}"; then
        chmod --reference="${inboundConfig}" "${temporaryConfig}" 2>/dev/null || chmod 600 "${temporaryConfig}"
        mv -f "${temporaryConfig}" "${inboundConfig}"
    else
        rm -f "${temporaryConfig}"
        return 1
    fi
}

appendHysteria2User() {
    local inboundConfig=$1 userUUID=$2 userTag=$3
    local temporaryConfig
    temporaryConfig=$(mktemp "${inboundConfig}.tmp.XXXXXX") || return 1
    # Always write "clients" (see normalizeHysteria2UserField).
    if jq --arg auth "${userUUID}" --arg email "${userTag}-Hysteria2" '
        .inbounds[0].settings |= (
            .clients = ((.clients // .users // []) + [{auth: $auth, level: 0, email: $email}]) | del(.users)
        )
    ' "${inboundConfig}" >"${temporaryConfig}"; then
        chmod --reference="${inboundConfig}" "${temporaryConfig}" 2>/dev/null || chmod 600 "${temporaryConfig}"
        mv -f "${temporaryConfig}" "${inboundConfig}"
    else
        rm -f "${temporaryConfig}"
        return 1
    fi
}

collectAccounts() {
    discoverAccountProtocols
    discoveredAccounts='[]'
    local index protocol inboundConfig user userId userEmail userTag

    for index in "${!accountProtocolFiles[@]}"; do
        protocol=${accountProtocolLabels[index]}
        inboundConfig=${accountProtocolFiles[index]}
        while read -r user; do
            userId=$(jq -r '.id // .uuid // .auth // .password // empty' <<<"${user}")
            userEmail=$(jq -r '.email // .name // .username // empty' <<<"${user}")
            [[ -z "${userId}" ]] && continue
            userTag=$(normalizeXrayEmail "${userEmail}")
            [[ -z "${userTag}" ]] && userTag="${userId}"
            discoveredAccounts=$(jq -c --arg id "${userId}" --arg tag "${userTag}" --arg protocol "${protocol}" '
                if any(.[]; .uuid == $id) then
                    map(if .uuid == $id then
                        .protocols = (if (.protocols | index($protocol)) == null then .protocols + [$protocol] else .protocols end)
                    else . end)
                else
                    . + [{uuid:$id,tag:$tag,protocols:[$protocol]}]
                end
            ' <<<"${discoveredAccounts}")
        done < <(jq -c '(.inbounds[0].settings.clients // .inbounds[0].settings.users // .inbounds[0].users // [])[]' "${inboundConfig}")
    done
}

listAccounts() {
    collectAccounts
    if [[ $(jq 'length' <<<"${discoveredAccounts}") -eq 0 ]]; then
        echoContent yellow " ---> 当前没有账号"
        return
    fi
    echoContent skyBlue "\n当前账号"
    jq -r 'to_entries[] |
        "\(.key + 1). tag: \(.value.tag)\n   UUID/auth: \(.value.uuid)\n   协议: \(.value.protocols | join(", "))"
    ' <<<"${discoveredAccounts}"
}

# Add a user
addUser() {
    read -r -p "请输入要添加的账号数量:" userNum
    echo
    if [[ ! "${userNum}" =~ ^[0-9]+$ ]] || ((userNum <= 0)); then
        echoContent red " ---> 输入有误，请重新输入"
        return 1
    fi
    selectUserProtocols || return 1

    while [[ ${userNum} -gt 0 ]]; do
        readConfigHostPathUUID
        ((userNum--)) || true

        customUUID || return 1
        customUserEmail || return 1

        uuid=${currentCustomUUID}
        email=${currentCustomEmail}

        local selectedIndex
        for selectedIndex in "${userSelectedProtocolIndexes[@]}"; do
            case "${accountProtocolKinds[selectedIndex]}" in
                vless)
                    appendVlessUser "${accountProtocolFiles[selectedIndex]}" "${accountProtocolClientTypes[selectedIndex]}" "${uuid}" "${email}" || return 1
                    ;;
                hysteria2)
                    appendHysteria2User "${accountProtocolFiles[selectedIndex]}" "${uuid}" "${email}" || return 1
                    ;;
            esac
        done

        echoContent green " ---> 已添加 ${email}: ${uuid}"
    done
    restartXray || return 1
    echoContent green " ---> 添加完成"
    echoContent yellow " ---> 如需更新客户端订阅，请前往独立的订阅管理"
}
# Remove a user
removeUser() {
    local candidateConfig userCount delUserIndex userId temporaryConfig index email
    local -a removedEmails=()
    collectAccounts
    userCount=$(jq 'length' <<<"${discoveredAccounts}")
    if ((userCount == 0)); then
        echoContent red " ---> 未找到可删除的用户"
        return 1
    fi

    jq -r 'to_entries[] |
        "\(.key + 1):\(.value.tag) [UUID/auth: \(.value.uuid)]\n   协议: \(.value.protocols | join(", "))"
    ' <<<"${discoveredAccounts}"
    read -r -p "请选择要删除的账号编号[将从所属全部协议删除]:" delUserIndex
    if [[ ! "${delUserIndex}" =~ ^[0-9]+$ || ${delUserIndex} -lt 1 || ${delUserIndex} -gt ${userCount} ]]; then
        echoContent red " ---> 选择错误"
        return 1
    fi

    userId=$(jq -r --argjson index "$((delUserIndex - 1))" '.[$index].uuid // empty' <<<"${discoveredAccounts}")
    if [[ -z "${userId}" ]]; then
        echoContent red " ---> 无法识别该用户的 UUID/auth，未修改配置"
        return 1
    fi

    for index in "${!accountProtocolFiles[@]}"; do
        candidateConfig=${accountProtocolFiles[index]}
        if ! jq -e --arg userId "${userId}" '
            any((.inbounds[]?.settings.clients[]?, .inbounds[]?.settings.users[]?, .inbounds[]?.users[]?);
                (.id // .uuid // .auth // .password // "") == $userId)
        ' "${candidateConfig}" >/dev/null 2>&1; then
            continue
        fi

        while IFS= read -r email; do
            [[ -n "${email}" ]] && removedEmails+=("${email}")
        done < <(jq -r --arg userId "${userId}" '
            (.inbounds[]?.settings.clients[]?, .inbounds[]?.settings.users[]?, .inbounds[]?.users[]?) |
            select((.id // .uuid // .auth // .password // "") == $userId) | .email // empty
        ' "${candidateConfig}")

        temporaryConfig=$(mktemp "${candidateConfig}.tmp.XXXXXX") || return 1
        if jq --arg userId "${userId}" '
            (.inbounds[]? | select(.settings.clients? != null).settings.clients) |= map(select((.id // .uuid // .auth // .password // "") != $userId)) |
            (.inbounds[]? | select(.settings.users? != null).settings.users) |= map(select((.id // .uuid // .auth // .password // "") != $userId)) |
            (.inbounds[]? | select(.users? != null).users) |= map(select((.id // .uuid // .auth // .password // "") != $userId))
        ' "${candidateConfig}" >"${temporaryConfig}"; then
            chmod --reference="${candidateConfig}" "${temporaryConfig}" 2>/dev/null || chmod 600 "${temporaryConfig}"
            mv -f "${temporaryConfig}" "${candidateConfig}"
        else
            rm -f "${temporaryConfig}"
            echoContent red " ---> 更新配置失败: ${candidateConfig}"
            return 1
        fi
    done

    # Drop relay bindings for the deleted account, so a future account with
    # the same tag does not silently inherit them.
    if ((${#removedEmails[@]} > 0)); then
        withRelayLock removeRelayUsers "${removedEmails[@]}" || return 1
    fi
    restartXray || return 1
    echoContent green " ---> 删除完成"
    echoContent yellow " ---> 如需更新客户端订阅，请前往独立的订阅管理"
}
# Update the script
updateXrayAgent() {
    echoContent skyBlue "\n进度  $1/${totalProgress} : 更新脚本"
    local scriptUrl="https://raw.githubusercontent.com/z9wen/personal-infra-toolkit/main/networking/xray-install.sh"
    local targetScript="/opt/xray-agent/install.sh"
    local temporaryScript

    mkdir -p "$(dirname "${targetScript}")"
    temporaryScript=$(mktemp "${targetScript}.update.XXXXXX") || {
        echoContent red " ---> 无法创建更新临时文件"
        return 1
    }

    echoContent yellow " ---> 正在从 GitHub 获取最新脚本..."
    if ! downloadFile "${scriptUrl}" "${temporaryScript}" --https-only; then
        rm -f "${temporaryScript}"
        echoContent red " ---> 下载失败，当前脚本未变更"
        return 1
    fi

    if ! bash -n "${temporaryScript}" || ! grep -q '^updateXrayAgent() {' "${temporaryScript}" || ! grep -q '^menu() {' "${temporaryScript}"; then
        rm -f "${temporaryScript}"
        echoContent red " ---> 下载内容校验失败，当前脚本未变更"
        return 1
    fi

    if [[ -f "${targetScript}" ]] && cmp -s "${targetScript}" "${temporaryScript}"; then
        rm -f "${temporaryScript}"
        echoContent green " ---> 当前已经是最新脚本"
        return 0
    fi

    chmod 755 "${temporaryScript}"
    if ! mv -f "${temporaryScript}" "${targetScript}"; then
        rm -f "${temporaryScript}"
        echoContent red " ---> 替换脚本失败，当前脚本未变更"
        return 1
    fi

    echoContent green " ---> 脚本更新成功，正在重新启动..."
    exec /bin/bash "${targetScript}"
}

# View and check logs
checkLog() {
    if [[ -z "${configPath}" && -z "${realityStatus}" ]]; then
        echoContent red " ---> 没有检测到安装目录，请执行脚本安装内容"
        exit 0
    fi
    local realityLogShow=
    local logStatus=false
    if grep -q "access" ${configPath}00_log.json; then
        logStatus=true
    fi

    echoContent skyBlue "\n功能 $1/${totalProgress} : 查看日志"
    echoContent red "\n=============================================================="
    echoContent yellow "# 建议仅调试时打开access日志\n"

    if [[ "${logStatus}" == "false" ]]; then
        echoContent yellow "1.打开access日志"
    else
        echoContent yellow "1.关闭access日志"
    fi

    echoContent yellow "2.监听access日志"
    echoContent yellow "3.监听error日志"
    echoContent yellow "4.查看证书定时任务日志"
    echoContent yellow "5.查看证书安装日志"
    echoContent yellow "6.清空日志"
    echoContent red "=============================================================="

    read -r -p "请选择:" selectAccessLogType
    local configPathLog=${configPath//conf\//}

    case ${selectAccessLogType} in
        1)
            if [[ "${logStatus}" == "false" ]]; then
                realityLogShow=true
                cat <<EOF >${configPath}00_log.json
{
  "log": {
  	"access":"${configPathLog}access.log",
    "error": "${configPathLog}error.log",
    "loglevel": "debug"
  }
}
EOF
            elif [[ "${logStatus}" == "true" ]]; then
                realityLogShow=false
                cat <<EOF >${configPath}00_log.json
{
  "log": {
    "error": "${configPathLog}error.log",
    "loglevel": "warning"
  }
}
EOF
            fi

            if [[ -n ${realityStatus} ]]; then
                local vlessVisionRealityInbounds
                vlessVisionRealityInbounds=$(jq -r ".inbounds[0].streamSettings.realitySettings.show=${realityLogShow}" ${configPath}07_VLESS_vision_reality_inbounds.json)
                echo "${vlessVisionRealityInbounds}" | jq . >${configPath}07_VLESS_vision_reality_inbounds.json
            fi
            restartXray || return 1
            checkLog 1
            ;;
        2)
            tail -f ${configPathLog}access.log
            ;;
        3)
            tail -f ${configPathLog}error.log
            ;;
        4)
            if [[ ! -f "/opt/xray-agent/crontab_tls.log" ]]; then
                touch /opt/xray-agent/crontab_tls.log
            fi
            tail -n 100 /opt/xray-agent/crontab_tls.log
            ;;
        5)
            tail -n 100 /opt/xray-agent/tls/acme.log
            ;;
        6)
            echo >${configPathLog}access.log
            echo >${configPathLog}error.log
            ;;
    esac
}

# Script shortcut
aliasInstall() {
    # Get the actual path of the current script
    local currentScript
    currentScript="$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")"

    # Make sure the target directory exists
    if [[ ! -d "/opt/xray-agent" ]]; then
        mkdir -p /opt/xray-agent
    fi

    # Copy only on first install or when the file does not exist
    local targetScript="/opt/xray-agent/install.sh"
    local needCopy=false

    if [[ ! -f "$targetScript" ]]; then
        needCopy=true
    elif [[ "$currentScript" != "$targetScript" ]]; then
        # If the current script is not at the target location, copy it (update scenario)
        needCopy=true
    fi

    if [[ "$needCopy" == "true" && -f "$currentScript" ]]; then
        cp "$currentScript" "$targetScript"
        chmod +x "$targetScript"
        echoContent green " ---> 脚本已复制到 /opt/xray-agent/install.sh"
    elif [[ ! -f "$currentScript" ]]; then
        echoContent red " ---> 无法找到当前脚本: $currentScript"
        return 1
    fi

    # Check for and create the symlink
    local xrayaType=false
    local symlinkPath=""

    if [[ -d "/usr/bin/" ]]; then
        symlinkPath="/usr/bin/xraya"
    elif [[ -d "/usr/sbin" ]]; then
        symlinkPath="/usr/sbin/xraya"
    fi

    if [[ -n "$symlinkPath" ]]; then
        # Check whether the symlink already exists and is correct
        if [[ -L "$symlinkPath" ]] && [[ "$(readlink "$symlinkPath")" == "$targetScript" ]]; then
            # The symlink already exists and is correct; no need to recreate it
            xrayaType=true
        else
            # Remove the old symlink or file
            rm -f "$symlinkPath"

            # Create a new symlink
            ln -s "$targetScript" "$symlinkPath"
            chmod 755 "$symlinkPath"
            xrayaType=true
            echoContent green " ---> 快捷方式创建成功，可执行[xraya]重新打开脚本"
        fi
    fi

    if [[ "${xrayaType}" == "false" ]]; then
        echoContent red " ---> 快捷方式创建失败"
    fi
}
# Check IPv6 and IPv4
checkIPv6() {
    currentIPv6IP=$(curl -s -6 -m 4 http://www.cloudflare.com/cdn-cgi/trace | grep "ip" | cut -d "=" -f 2)

    if [[ -z "${currentIPv6IP}" ]]; then
        echoContent red " ---> 不支持ipv6"
        exit 0
    fi
}

# IPv6 split routing
ipv6Routing() {
    if [[ -z "${configPath}" ]]; then
        echoContent red " ---> 未安装，请使用脚本安装"
        menu
        exit 0
    fi

    checkIPv6
    echoContent skyBlue "\n功能 1/${totalProgress} : IPv6分流"
    echoContent red "\n=============================================================="
    echoContent yellow "1.查看已分流域名"
    echoContent yellow "2.添加域名"
    echoContent yellow "3.设置IPv6全局"
    echoContent yellow "4.卸载IPv6分流"
    echoContent red "=============================================================="
    read -r -p "请选择:" ipv6Status
    if [[ "${ipv6Status}" == "1" ]]; then
        showIPv6Routing
        exit 0
    elif [[ "${ipv6Status}" == "2" ]]; then
        echoContent red "=============================================================="
        echoContent yellow "# 注意事项\n"

        read -r -p "请按照上面示例录入域名:" domainList
        if [[ "${coreInstallType}" == "1" ]]; then
            addInstallRouting IPv6_out outboundTag "${domainList}"
            addXrayOutbound IPv6_out
        fi

        echoContent green " ---> 添加完毕"

    elif [[ "${ipv6Status}" == "3" ]]; then

        echoContent red "=============================================================="
        echoContent yellow "# 注意事项\n"
        echoContent yellow "1.会删除所有设置的分流规则"
        echoContent yellow "2.会删除IPv6之外的所有出站规则\n"
        read -r -p "是否确认设置？[y/n]:" IPv6OutStatus

        if [[ "${IPv6OutStatus}" == "y" ]]; then
            if [[ "${coreInstallType}" == "1" ]]; then
                addXrayOutbound IPv6_out
                removeXrayOutbound IPv4_out
                removeXrayOutbound z_direct_outbound
                removeXrayOutbound blackhole_out
                removeXrayOutbound wireguard_out_IPv4
                removeXrayOutbound wireguard_out_IPv6
                removeXrayOutbound socks5_outbound

                rm -f "${configPath}09_routing.json"
                # Global outbound mode drops the shared routing rules; relay
                # bindings are kept and re-applied on top of it.
                syncRelayRouting
            fi

            echoContent green " ---> IPv6全局出站设置完毕"
        else

            echoContent green " ---> 放弃设置"
            exit 0
        fi

    elif [[ "${ipv6Status}" == "4" ]]; then
        if [[ "${coreInstallType}" == "1" ]]; then
            unInstallRouting IPv6_out outboundTag

            removeXrayOutbound IPv6_out
            addXrayOutbound "z_direct_outbound"
        fi

        echoContent green " ---> IPv6分流卸载成功"
    else
        echoContent red " ---> 选择错误"
        exit 0
    fi

    restartXray || return 1
}

# Show IPv6 split routing rules
showIPv6Routing() {
    if [[ "${coreInstallType}" == "1" ]]; then
        if [[ -f "${configPath}09_routing.json" ]]; then
            echoContent yellow "Xray-core："
            jq -r -c '.routing.rules[]|select (.outboundTag=="IPv6_out")|.domain' ${configPath}09_routing.json | jq -r
        elif [[ ! -f "${configPath}09_routing.json" && -f "${configPath}IPv6_out.json" ]]; then
            echoContent yellow "Xray-core"
            echoContent green " ---> 已设置IPv6全局分流"
        else
            echoContent yellow " ---> 未安装IPv6分流"
        fi

    fi
}
# Domain blocklist

# Add the routing config
addInstallRouting() {

    local tag=$1    # warp-socks
    local type=$2   # outboundTag/inboundTag
    local domain=$3 # Domain

    if [[ -z "${tag}" || -z "${type}" || -z "${domain}" ]]; then
        echoContent red " ---> 参数错误"
        exit 0
    fi

    local routingRule=
    if [[ ! -f "${configPath}09_routing.json" ]]; then
        cat <<EOF >${configPath}09_routing.json
{
    "routing":{
        "type": "field",
        "rules": [
            {
                "type": "field",
                "domain": [
                ],
            "outboundTag": "${tag}"
          }
        ]
  }
}
EOF
    fi
    local routingRule=
    routingRule=$(jq -r ".routing.rules[]|select(.outboundTag==\"${tag}\" and (.protocol == null))" ${configPath}09_routing.json)

    if [[ -z "${routingRule}" ]]; then
        routingRule="{\"type\": \"field\",\"domain\": [],\"outboundTag\": \"${tag}\"}"
    fi

    while read -r line; do
        if echo "${routingRule}" | grep -q "${line}"; then
            echoContent yellow " ---> ${line}已存在，跳过"
        else
            local geositeStatus
            geositeStatus=$(curl -s "https://api.github.com/repos/v2fly/domain-list-community/contents/data/${line}" | jq .message)

            if [[ "${geositeStatus}" == "null" ]]; then
                routingRule=$(echo "${routingRule}" | jq -r '.domain += ["geosite:'"${line}"'"]')
            else
                routingRule=$(echo "${routingRule}" | jq -r '.domain += ["domain:'"${line}"'"]')
            fi
        fi
    done < <(echo "${domain}" | tr ',' '\n')

    unInstallRouting "${tag}" "${type}"
    if ! grep -q "gstatic.com" ${configPath}09_routing.json && [[ "${tag}" == "blackhole_out" ]]; then
        local routing=
        routing=$(jq -r ".routing.rules += [{\"type\": \"field\",\"domain\": [\"gstatic.com\"],\"outboundTag\": \"direct\"}]" ${configPath}09_routing.json)
        echo "${routing}" | jq . >${configPath}09_routing.json
    fi

    routing=$(jq -r ".routing.rules += [${routingRule}]" ${configPath}09_routing.json)
    echo "${routing}" | jq . >${configPath}09_routing.json
}
# Remove Routing by tag
unInstallRouting() {
    local tag=$1
    local type=$2
    local protocol=$3

    if [[ -f "${configPath}09_routing.json" ]]; then
        local routing=
        if [[ -n "${protocol}" ]]; then
            routing=$(jq -r "del(.routing.rules[] | select(.${type} == \"${tag}\" and (.protocol | index(\"${protocol}\"))))" ${configPath}09_routing.json)
            echo "${routing}" | jq . >${configPath}09_routing.json
        else
            routing=$(jq -r "del(.routing.rules[] | select(.${type} == \"${tag}\" and (.protocol == null )))" ${configPath}09_routing.json)
            echo "${routing}" | jq . >${configPath}09_routing.json
        fi
    fi
}

# Install sniffing
installSniffing() {
    readInstallType
    if [[ "${coreInstallType}" == "1" ]]; then
        if [[ -f "${configPath}02_VLESS_TCP_inbounds.json" ]]; then
            if ! grep -q "destOverride" <"${configPath}02_VLESS_TCP_inbounds.json"; then
                sniffing=$(jq -r '.inbounds[0].sniffing = {"enabled":true,"destOverride":["http","tls","quic"]}' "${configPath}02_VLESS_TCP_inbounds.json")
                echo "${sniffing}" | jq . >"${configPath}02_VLESS_TCP_inbounds.json"
            fi
        fi
    fi
}

# Read the third-party WARP config
readConfigWarpReg() {
    if [[ ! -f "/opt/xray-agent/warp/config" ]]; then
        /opt/xray-agent/warp/warp-reg >/opt/xray-agent/warp/config
    fi

    secretKeyWarpReg=$(grep <"/opt/xray-agent/warp/config" private_key | awk '{print $2}')

    addressWarpReg=$(grep <"/opt/xray-agent/warp/config" v6 | awk '{print $2}')

    publicKeyWarpReg=$(grep <"/opt/xray-agent/warp/config" public_key | awk '{print $2}')

    reservedWarpReg=$(grep <"/opt/xray-agent/warp/config" reserved | awk -F "[:]" '{print $2}')

}
# Install the warp-reg tool
installWarpReg() {
    if [[ ! -f "/opt/xray-agent/warp/warp-reg" ]]; then
        echo
        echoContent yellow "# 注意事项"
        echoContent yellow "# 依赖第三方程序，请熟知其中风险"
        echoContent yellow "# 项目地址：https://github.com/badafans/warp-reg \n"

        read -r -p "warp-reg未安装，是否安装 ？[y/n]:" installWarpRegStatus

        if [[ "${installWarpRegStatus}" == "y" ]]; then

            if ! downloadFile "https://github.com/badafans/warp-reg/releases/download/v1.0/${warpRegCoreCPUVendor}" "/opt/xray-agent/warp/warp-reg"; then
                echoContent red " ---> warp-reg 下载失败"
                return 1
            fi
            chmod 755 /opt/xray-agent/warp/warp-reg

        else
            echoContent yellow " ---> 放弃安装"
            exit 0
        fi
    fi
}

# Show WARP split-routing domains
showWireGuardDomain() {
    local type=$1
    # xray
    if [[ "${coreInstallType}" == "1" ]]; then
        if [[ -f "${configPath}09_routing.json" ]]; then
            echoContent yellow "Xray-core"
            jq -r -c '.routing.rules[]|select (.outboundTag=="wireguard_out_'"${type}"'")|.domain' ${configPath}09_routing.json | jq -r
        elif [[ ! -f "${configPath}09_routing.json" && -f "${configPath}wireguard_out_${type}.json" ]]; then
            echoContent yellow "Xray-core"
            echoContent green " ---> 已设置warp ${type}全局分流"
        else
            echoContent yellow " ---> 未安装warp ${type}分流"
        fi
    fi

}

# Add WireGuard split routing
addWireGuardRoute() {
    local type=$1
    local tag=$2
    local domainList=$3
    # xray
    if [[ "${coreInstallType}" == "1" ]]; then

        addInstallRouting "wireguard_out_${type}" "${tag}" "${domainList}"
        addXrayOutbound "wireguard_out_${type}"
    fi
}

# WARP split routing - third-party IPv4
warpRoutingReg() {
    local type=$2
    echoContent skyBlue "\n进度  $1/${totalProgress} : WARP分流[第三方]"
    echoContent red "=============================================================="

    echoContent yellow "1.查看已分流域名"
    echoContent yellow "2.添加域名"
    echoContent yellow "3.设置WARP全局"
    echoContent yellow "4.卸载WARP分流"
    echoContent red "=============================================================="
    read -r -p "请选择:" warpStatus
    installWarpReg
    readConfigWarpReg
    local address=
    if [[ ${type} == "IPv4" ]]; then
        address="172.16.0.2/32"
    elif [[ ${type} == "IPv6" ]]; then
        address="${addressWarpReg}/128"
    else
        echoContent red " ---> IP获取失败，退出安装"
    fi

    if [[ "${warpStatus}" == "1" ]]; then
        showWireGuardDomain "${type}"
        exit 0
    elif [[ "${warpStatus}" == "2" ]]; then
        echoContent yellow "# 注意事项"

        read -r -p "请按照上面示例录入域名:" domainList
        addWireGuardRoute "${type}" outboundTag "${domainList}"
        echoContent green " ---> 添加完毕"

    elif [[ "${warpStatus}" == "3" ]]; then

        echoContent red "=============================================================="
        echoContent yellow "# 注意事项\n"
        echoContent yellow "1.会删除所有设置的分流规则"
        echoContent yellow "2.会删除除WARP[第三方]之外的所有出站规则\n"
        read -r -p "是否确认设置？[y/n]:" warpOutStatus

        if [[ "${warpOutStatus}" == "y" ]]; then
            readConfigWarpReg
            if [[ "${coreInstallType}" == "1" ]]; then
                addXrayOutbound "wireguard_out_${type}"
                if [[ "${type}" == "IPv4" ]]; then
                    removeXrayOutbound "wireguard_out_IPv6"
                elif [[ "${type}" == "IPv6" ]]; then
                    removeXrayOutbound "wireguard_out_IPv4"
                fi

                removeXrayOutbound IPv4_out
                removeXrayOutbound IPv6_out
                removeXrayOutbound z_direct_outbound
                removeXrayOutbound blackhole_out
                removeXrayOutbound socks5_outbound

                rm -f "${configPath}09_routing.json"
                # Global outbound mode drops the shared routing rules; relay
                # bindings are kept and re-applied on top of it.
                syncRelayRouting
            fi

            echoContent green " ---> WARP全局出站设置完毕"
        else
            echoContent green " ---> 放弃设置"
            exit 0
        fi

    elif [[ "${warpStatus}" == "4" ]]; then
        if [[ "${coreInstallType}" == "1" ]]; then
            unInstallRouting "wireguard_out_${type}" outboundTag

            removeXrayOutbound "wireguard_out_${type}"
            addXrayOutbound "z_direct_outbound"
        fi

        echoContent green " ---> 卸载WARP ${type}分流完毕"
    else

        echoContent red " ---> 选择错误"
        exit 0
    fi
    restartXray || return 1
}
# ==================== Relay management ====================
#
# Relay state (relayStateFile) is the single source of truth: a list of
# upstream profiles, each with the selectors routed through it. A selector is
# {inboundTags: [...], users: [...]}; an empty users list means the whole
# inbound. 09_routing.json is regenerated from that state, never edited by
# hand, and every change goes through commitRelayChange so it is validated by
# Xray and rolled back on failure.

relayStateFile=/opt/xray-agent/relay_config.json
relayLockFile=/opt/xray-agent/update-relay.lock

# jq definitions shared by every selector query.
relaySelectorJqDefs='
    def overlap($left; $right):
        any($left[]?; . as $item | $right | index($item) != null);
    # Does $current already claim traffic that $selected wants?
    def conflicts($current; $selected):
        overlap($current.inboundTags; $selected.inboundTags) and
        (
            (($selected.users // []) | length) == 0 or
            (
                ((($current.users // []) | length) > 0) and
                overlap(($current.users // []); ($selected.users // []))
            )
        );
    # Remove from $current whatever $selected takes over; empty results vanish.
    def subtractSelector($current; $selected):
        if (($selected.users // []) | length) == 0 then
            $current | .inboundTags -= $selected.inboundTags | select((.inboundTags | length) > 0)
        elif ((($current.users // []) | length) > 0 and overlap($current.inboundTags; $selected.inboundTags)) then
            $current | .users -= $selected.users | select((.users | length) > 0)
        else $current end;
    # Account tag without the protocol suffix added to Xray emails.
    def displayUser:
        sub("-(VLESS_TCP/TLS_Vision|VLESS_WS|VLESS_XHTTP_Reality|VLESS_XHTTP|vless_reality_vision|Hysteria2)$"; "");
'

# Return the protocols installed on this host that can serve as relay entries.
detectRelayInbounds() {
    relayInboundTags=()
    relayInboundLabels=()
    [[ -f "${configPath}02_VLESS_TCP_inbounds.json" ]] && relayInboundTags+=("VLESSTCP") && relayInboundLabels+=("VLESS + TCP + TLS Vision")
    [[ -f "${configPath}03_VLESS_WS_inbounds.json" ]] && relayInboundTags+=("VLESSWS") && relayInboundLabels+=("VLESS + WebSocket + TLS")
    [[ -f "${configPath}07_VLESS_vision_reality_inbounds.json" ]] && relayInboundTags+=("VLESSReality") && relayInboundLabels+=("VLESS + Reality + Vision")
    [[ -f "${configPath}14_VLESS_XHTTP_TLS_inbounds.json" ]] && relayInboundTags+=("VLESSXHTTP") && relayInboundLabels+=("VLESS + XHTTP + TLS")
    [[ -f "${configPath}12_VLESS_XHTTP_inbounds.json" ]] && relayInboundTags+=("VLESSRealityXHTTP") && relayInboundLabels+=("VLESS + XHTTP + Reality")
    [[ -f "${configPath}05_hysteria2_inbounds.json" ]] && relayInboundTags+=("Hysteria2") && relayInboundLabels+=("Hysteria2 + TLS + QUIC")
}

# Generate selectable "inbound + account" targets. Each inbound can be selected as a whole, or narrowed to a specific UUID/auth that has an email.
buildRelayTargetChoices() {
    detectRelayInbounds
    relayTargetChoices='[]'
    if ((${#relayInboundTags[@]} == 0)); then
        echoContent red " ---> 未检测到可用的入站协议"
        return 1
    fi

    local index inboundTag inboundLabel inboundConfig clients
    for ((index = 0; index < ${#relayInboundTags[@]}; index++)); do
        inboundTag=${relayInboundTags[index]}
        inboundLabel=${relayInboundLabels[index]}
        case "${inboundTag}" in
            VLESSTCP) inboundConfig="${configPath}02_VLESS_TCP_inbounds.json" ;;
            VLESSWS) inboundConfig="${configPath}03_VLESS_WS_inbounds.json" ;;
            VLESSReality) inboundConfig="${configPath}07_VLESS_vision_reality_inbounds.json" ;;
            VLESSXHTTP) inboundConfig="${configPath}14_VLESS_XHTTP_TLS_inbounds.json" ;;
            VLESSRealityXHTTP) inboundConfig="${configPath}12_VLESS_XHTTP_inbounds.json" ;;
            Hysteria2) inboundConfig="${configPath}05_hysteria2_inbounds.json" ;;
            *) continue ;;
        esac
        relayTargetChoices=$(jq -c --arg tag "${inboundTag}" --arg label "${inboundLabel}" '
            . + [{selector:{inboundTags:[$tag],users:[]},label:($label + " / 整个入站（全部 UUID/auth）")}]
        ' <<<"${relayTargetChoices}")
        clients=$(jq -c '
            (.inbounds[0].settings.clients // .inbounds[0].settings.users // .inbounds[0].users // [])
            | map(select((.email // "") != ""))
        ' "${inboundConfig}") || return 1
        relayTargetChoices=$(jq -c --arg tag "${inboundTag}" --arg label "${inboundLabel}" --argjson clients "${clients}" "${relaySelectorJqDefs}"'
            reduce $clients[] as $client (.;
                ($client.email | displayUser) as $accountTag |
                ($client.id // $client.uuid // $client.auth // $client.password // "unknown") as $credential |
                . + [{selector:{inboundTags:[$tag],users:[$client.email]},
                    label:($label + " / tag: " + $accountTag + " / UUID/auth: " + $credential)}]
            )
        ' <<<"${relayTargetChoices}")
    done
}

# Multiple exact targets can be selected at once, e.g. a Vision UUID plus a Hysteria2 auth.
selectRelayTargets() {
    buildRelayTargetChoices || return 1
    local targetCount selection
    targetCount=$(jq 'length' <<<"${relayTargetChoices}")
    ((targetCount > 0)) || return 1
    echoContent skyBlue "\n请选择需要链式转发的精确目标"
    jq -r 'to_entries[] | "\(.key + 1).\(.value.label)"' <<<"${relayTargetChoices}"

    read -r -p "请选择[可多选，例:3,6]:" selection
    selection=${selection//，/,}
    if [[ -z "${selection}" ]]; then
        echoContent red " ---> 至少选择一个目标"
        return 1
    fi

    relaySelectedSelectors='[]'
    local -a choices=()
    local choice selector
    IFS=',' read -r -a choices <<<"${selection}"
    for choice in "${choices[@]}"; do
        choice=${choice//[[:space:]]/}
        if [[ ! "${choice}" =~ ^[0-9]+$ ]] || ((choice < 1 || choice > targetCount)); then
            echoContent red " ---> 目标选项无效: ${choice}"
            return 1
        fi
        selector=$(jq -c --argjson index "$((choice - 1))" '.[$index].selector' <<<"${relayTargetChoices}")
        relaySelectedSelectors=$(jq -c --argjson selector "${selector}" '
            ($selector.inboundTags[0]) as $tag |
            if (($selector.users | length) == 0) then
                [ .[] | select(.inboundTags[0] != $tag) ] + [$selector]
            elif any(.[]; .inboundTags[0] == $tag and ((.users // []) | length) == 0) then .
            elif index($selector) == null then . + [$selector]
            else . end
        ' <<<"${relaySelectedSelectors}")
    done
    echoContent green " ---> 已选择 $(jq 'length' <<<"${relaySelectedSelectors}") 个独立入口规则"
}

# Return the nodes in a sing-box JSON subscription that can be converted to Xray outbounds.
# For now Reality only accepts VLESS + Reality (RAW/TCP) with no extra transport configured.
getRelayNodesFromSingBoxSubscription() {
    local subscriptionFile=$1
    jq -c '[
        .outbounds[]? |
        select((.tag | type) == "string" and (.tag | length) > 0) |
        # Xray has no SIP003 plugin support; such nodes would pass
        # `xray -test` but never connect.
        if .type == "shadowsocks" and ((.plugin // "") == "") then
            . + {_relayType:"shadowsocks"}
        elif (
            .type == "vless" and
            .tls.enabled == true and
            .tls.reality.enabled == true and
            (((.transport // {}) | type) == "object") and
            (((.transport // {}) | length) == 0)
        ) then
            . + {_relayType:"vless-reality"}
        else empty end
    ]' "${subscriptionFile}"
}

# Read Shadowsocks or VLESS Reality outbounds from a sing-box JSON subscription and convert them to Xray config.
buildRelayOutboundFromSingBoxSubscription() {
    local subscriptionFile=$1 selectedTag=$2 outboundTag=$3 outputFile=$4
    local supportedNodes node nodeType
    supportedNodes=$(getRelayNodesFromSingBoxSubscription "${subscriptionFile}") || return 1
    node=$(jq -c --arg tag "${selectedTag}" 'first(.[] | select(.tag == $tag))' <<<"${supportedNodes}") || return 1
    [[ -n "${node}" && "${node}" != "null" ]] || return 1
    nodeType=$(jq -r '._relayType' <<<"${node}")

    if ! jq -e '
        (.server | type == "string" and length > 0) and
        (.server_port | type == "number" and . >= 1 and . <= 65535)
    ' <<<"${node}" >/dev/null; then
        return 1
    fi

    case ${nodeType} in
        shadowsocks)
            if ! jq -e '
            (.method | type == "string" and length > 0) and
            (.password | type == "string" and length > 0)
        ' <<<"${node}" >/dev/null; then
                return 1
            fi
            jq -n --arg tag "${outboundTag}" --argjson node "${node}" '
            {outbounds:[{
                tag:$tag,
                protocol:"shadowsocks",
                settings:{
                    address:$node.server,
                    port:$node.server_port,
                    method:$node.method,
                    password:$node.password
                }
            }]}
        ' >"${outputFile}" || return 1
            relayBuiltProtocol="shadowsocks"
            relayBuiltLabel="Shadowsocks ($(jq -r '.method' <<<"${node}"))"
            ;;
        vless-reality)
            if ! jq -e '
            (.uuid | type == "string" and length > 0) and
            ((.flow // "") | type == "string" and
                (. == "" or . == "xtls-rprx-vision" or . == "xtls-rprx-vision-udp443")) and
            (.tls.server_name | type == "string" and length > 0) and
            (.tls.reality.public_key | type == "string" and length > 0) and
            ((.tls.reality.short_id // "") | type == "string" and test("^([0-9A-Fa-f]{2}){0,8}$")) and
            ((.tls.utls.fingerprint // "chrome") | type == "string" and length > 0)
        ' <<<"${node}" >/dev/null; then
                return 1
            fi
            jq -n --arg tag "${outboundTag}" --argjson node "${node}" '
            {outbounds:[{
                tag:$tag,
                protocol:"vless",
                settings:{vnext:[{
                    address:$node.server,
                    port:$node.server_port,
                    users:[({id:$node.uuid,encryption:"none"} +
                        if (($node.flow // "") | length) > 0 then {flow:$node.flow} else {} end)]
                }]},
                streamSettings:{
                    network:"tcp",
                    security:"reality",
                    realitySettings:({
                        show:false,
                        serverName:$node.tls.server_name,
                        fingerprint:($node.tls.utls.fingerprint // "chrome"),
                        password:$node.tls.reality.public_key,
                        shortId:($node.tls.reality.short_id // ""),
                        spiderX:"/"
                    } + if (($node.tls.reality.mldsa65_verify // "") | length) > 0 then
                        {mldsa65Verify:$node.tls.reality.mldsa65_verify}
                    else {} end)
                }
            }]}
        ' >"${outputFile}" || return 1
            relayBuiltProtocol="reality"
            if [[ -n $(jq -r '.flow // empty' <<<"${node}") ]]; then
                relayBuiltLabel="VLESS + Reality + Vision"
            else
                relayBuiltLabel="VLESS + Reality"
            fi
            ;;
        *) return 1 ;;
    esac

    relayBuiltSubscriptionType=${nodeType}
    relayBuiltAddress=$(jq -r '.server' <<<"${node}")
    relayBuiltPort=$(jq -r '.server_port' <<<"${node}")
    relayBuiltBbrProfile=
}

# The daily cron job applies whatever the subscription returns as root, so it
# must come over HTTPS (redirects included); plain HTTP would let anyone on
# the path swap in their own upstream.
fetchRelaySubscription() {
    local url=$1 destination=$2
    if [[ ! "${url}" =~ ^https:// ]]; then
        echoContent red " ---> 订阅地址必须以 https:// 开头"
        return 1
    fi
    if ! downloadFile "${url}" "${destination}" --https-only; then
        echoContent red " ---> 中转订阅下载失败"
        return 1
    fi
    if ! jq -e '.outbounds | type == "array"' "${destination}" >/dev/null 2>&1; then
        echoContent red " ---> 订阅内容不是有效的 sing-box JSON"
        return 1
    fi
}

# Replace the relay refresh entry in root's crontab; with no argument the
# entry is only removed.
setRelayCronEntry() {
    local entry=${1:-} backupFile=/opt/xray-agent/backup_crontab.cron
    crontab -l >"${backupFile}" 2>/dev/null || true
    {
        sed '/xray-agent-update-relay/d;/xray-agent\/install.sh UpdateRelay/d' "${backupFile}"
        [[ -n "${entry}" ]] && echo "${entry}"
    } >"${backupFile}.new"
    mv "${backupFile}.new" "${backupFile}"
    crontab "${backupFile}"
}

installCronRelaySubscription() {
    touch /opt/xray-agent/crontab_relay.log
    chmod 600 /opt/xray-agent/crontab_relay.log
    setRelayCronEntry "17 4 * * * /bin/bash /opt/xray-agent/install.sh UpdateRelay >> /opt/xray-agent/crontab_relay.log 2>&1 # xray-agent-update-relay"
}

removeCronRelaySubscription() {
    setRelayCronEntry
}

writeRelayState() {
    local content=$1 temporaryFile="${relayStateFile}.tmp.$$"
    jq -e . >/dev/null 2>&1 <<<"${content}" || return 1
    echo "${content}" >"${temporaryFile}" || return 1
    chmod 600 "${temporaryFile}"
    mv "${temporaryFile}" "${relayStateFile}"
}

# Replace the relay state with the output of a state-building command.
# Usage: updateRelayState <command> [args...]
updateRelayState() {
    local newState
    newState=$("$@") || return 1
    writeRelayState "${newState}"
}

# Run a command while holding the relay lock, so the menu and the daily
# refresh job never modify relay state at the same time. The lock is only
# held for the duration of one change, not for a whole menu session.
# Nested calls reuse the lock that is already held.
withRelayLock() {
    local status=0
    if [[ "${relayLockHeld:-false}" == "true" ]] || ! command -v flock >/dev/null 2>&1; then
        "$@"
        return
    fi
    exec 9>"${relayLockFile}" || return 1
    if ! flock -w 30 9; then
        echoContent yellow " ---> 中转配置正被其他任务修改，请稍后重试"
        exec 9>&-
        return 1
    fi
    relayLockHeld=true
    "$@" || status=$?
    relayLockHeld=false
    exec 9>&-
    return "${status}"
}

relayChangeThenRebuild() {
    "$@" && rebuildRelayRouting
}

# Apply one relay change transactionally: run it, regenerate routing from
# the new state, validate with Xray and restore everything on failure. On
# success, drop outbound files no profile uses and sync the refresh cron job.
# Usage: commitRelayChange <description> <command> [args...]
commitRelayChange() {
    local description=$1
    shift
    applyXrayConfigChange "${description}" relayChangeThenRebuild "$@" || return 1
    removeOrphanedRelayFiles
    refreshRelaySubscriptionCron
}

# Convert the legacy state into the "one upstream profile maps to multiple entry selectors" format.
ensureRelayStateV2() {
    if [[ ! -f "${relayStateFile}" ]]; then
        writeRelayState '{"version":2,"profiles":[]}'
        return
    fi
    if jq -e '.version == 2 and (.profiles | type == "array")' "${relayStateFile}" >/dev/null 2>&1; then
        local normalized current
        normalized=$(jq -c '
            .profiles |= map(
                if (.selectors? | type) == "array" then
                    .
                else
                    . + {selectors:[{
                        inboundTags:(.inboundTags // []),
                        users:(.users // [])
                    }]}
                end |
                del(.inboundTags, .users)
            )
        ' "${relayStateFile}") || return 1
        current=$(jq -c . "${relayStateFile}") || return 1
        if [[ "${normalized}" != "${current}" ]]; then
            writeRelayState "${normalized}" || return 1
            echoContent green " ---> 已将中转规则升级为多入口格式"
        else
            chmod 600 "${relayStateFile}"
        fi
        return
    fi
    local migrated
    migrated=$(jq '
        . as $legacy |
        {version:2,profiles:[(
            $legacy + {
                id:"legacy",
                name:($legacy.name // if $legacy.source == "subscription" then "原有订阅中转" else "原有手动中转" end),
                outboundTag:"relay_tcp_outbound",
                outboundFile:"relay_tcp_outbound.json",
                selectors:[{
                    inboundTags:($legacy.inboundTags // []),
                    users:($legacy.users // [])
                }]
            } |
            del(.inboundTags, .users)
        )]}
    ' "${relayStateFile}") || return 1
    writeRelayState "${migrated}"
    echoContent green " ---> 已将原有中转配置迁移为多入口格式"
}

relayProfileFileIsSafe() {
    [[ $1 =~ ^relay_([A-Za-z0-9_]+_)?outbound\.json$ ]]
}

# Check whether the target selectors are already bound to another upstream.
relayTargetsAvailable() {
    local selector=$1 destinationId=${2:-}
    ensureRelayStateV2 || return 1
    if jq -e --argjson selector "${selector}" --arg destinationId "${destinationId}" "${relaySelectorJqDefs}"'
        any(.profiles[]? | select(.id != $destinationId) | .selectors[]?; conflicts(.; $selector))
    ' "${relayStateFile}" >/dev/null; then
        echoContent yellow " ---> 所选目标已属于以下规则:"
        jq -r --argjson selector "${selector}" --arg destinationId "${destinationId}" "${relaySelectorJqDefs}"'
            .profiles[] | select(.id != $destinationId) as $profile |
            $profile.selectors[] |
            select(conflicts(.; $selector)) |
            "     " + $profile.name + " [" + (.inboundTags | join(", ")) + "] 账号: " +
            (if ((.users // []) | length) > 0 then ([.users[] | displayUser] | join(", ")) else "全部 UUID" end)
        ' "${relayStateFile}"
        local reassignStatus
        if [[ $(jq '.users | length' <<<"${selector}") -eq 0 ]]; then
            read -r -p "新规则将覆盖整个入站，是否移除上述旧绑定？[y/N]:" reassignStatus
        else
            read -r -p "是否将这些账号改派到新规则？[y/N]:" reassignStatus
        fi
        [[ "${reassignStatus}" =~ ^[Yy]$ ]] || return 1
    fi
}

# Bind selectors to a destination profile in one state update, removing each
# from any other profile that claimed the same traffic. Prints the new state.
# Usage: buildRelayStateWithSelectors <destinationId> <selectors-json-array> [new-profile-json]
buildRelayStateWithSelectors() {
    local destinationId=$1 selectors=$2 newProfile=${3:-null}
    jq --arg destinationId "${destinationId}" --argjson selectors "${selectors}" --argjson newProfile "${newProfile}" "${relaySelectorJqDefs}"'
        (if $newProfile == null then . else .profiles += [$newProfile] end) |
        reduce $selectors[] as $selector (.;
            .profiles |= map(
                .selectors = (
                    [.selectors[]? | subtractSelector(.; $selector)] +
                    (if .id == $destinationId then [$selector] else [] end)
                )
            )
        ) |
        .profiles |= map(select((.selectors | length) > 0))
    ' "${relayStateFile}"
}

# Delete relay outbound files that no profile in the current state uses.
removeOrphanedRelayFiles() {
    local file name
    for file in "${configPath}"relay_*outbound.json; do
        [[ -f "${file}" ]] || continue
        name=${file##*/}
        relayProfileFileIsSafe "${name}" || continue
        jq -e --arg file "${name}" 'any(.profiles[]?; .outboundFile == $file)' "${relayStateFile}" >/dev/null \
            || rm -f "${file}"
    done
}

refreshRelaySubscriptionCron() {
    ensureRelayStateV2 || return 1
    if jq -e 'any(.profiles[]?; .source == "subscription")' "${relayStateFile}" >/dev/null; then
        installCronRelaySubscription
    else
        removeCronRelaySubscription
    fi
}

# Install a generated outbound and bind the profile's selectors to it.
installRelayProfile() {
    local profile=$1 generatedOutbound=$2 outboundFile profileId selectors emptyProfile
    outboundFile=$(jq -r '.outboundFile' <<<"${profile}")
    profileId=$(jq -r '.id' <<<"${profile}")
    selectors=$(jq -c '.selectors' <<<"${profile}")
    emptyProfile=$(jq -c '.selectors = []' <<<"${profile}")
    cp "${generatedOutbound}" "${configPath}${outboundFile}" || return 1
    chmod 600 "${configPath}${outboundFile}"
    updateRelayState buildRelayStateWithSelectors "${profileId}" "${selectors}" "${emptyProfile}"
}

activateRelayProfile() {
    local profile=$1 generatedOutbound=$2 outboundFile
    outboundFile=$(jq -r '.outboundFile' <<<"${profile}")
    relayProfileFileIsSafe "${outboundFile}" || return 1
    ensureRelayStateV2 || return 1
    commitRelayChange "启用新中转配置" installRelayProfile "${profile}" "${generatedOutbound}" || return 1
    restartXray
}

# Attach several selectors to an existing upstream with one validation and
# one restart.
attachRelaySelectors() {
    local destinationId=$1 selectors=$2 profileName
    ensureRelayStateV2 || return 1
    profileName=$(jq -r --arg id "${destinationId}" 'first(.profiles[] | select(.id == $id)).name // empty' "${relayStateFile}")
    [[ -n "${profileName}" ]] || return 1
    commitRelayChange "绑定入口规则" updateRelayState buildRelayStateWithSelectors "${destinationId}" "${selectors}" || return 1
    restartXray || return 1
    echoContent green " ---> $(jq 'length' <<<"${selectors}") 个入口规则已绑定到现有上游: ${profileName}"
}

selectRelayUdpMode() {
    local udpRelayStatus
    relaySelectedUdpMode=direct
    read -r -p "UDP 也通过此上游转发吗？[y/N]:" udpRelayStatus
    [[ "${udpRelayStatus}" =~ ^[Yy]$ ]] && relaySelectedUdpMode=shared
}

# Add a Shadowsocks or VLESS Reality relay rule from a sing-box JSON subscription.
setupRelaySubscription() {
    local profileName=$1 profileId=$2
    local outboundTag="relay_profile_${profileId}" outboundFile="relay_${profileId}_outbound.json"
    selectRelayUdpMode
    local subscriptionUrl tempDir subscriptionFile supportedNodes nodeCount nodeIndex selectedTag generatedOutbound
    read -r -p "请输入 sing-box JSON 订阅地址:" subscriptionUrl
    [[ -z "${subscriptionUrl}" ]] && echoContent red " ---> 订阅地址不能为空" && return 1
    tempDir=$(mktemp -d /tmp/xray-relay-subscription.XXXXXX) || return 1
    subscriptionFile="${tempDir}/subscription.json"
    generatedOutbound="${tempDir}/${outboundFile}"
    fetchRelaySubscription "${subscriptionUrl}" "${subscriptionFile}" || {
        rm -rf "${tempDir}"
        return 1
    }
    supportedNodes=$(getRelayNodesFromSingBoxSubscription "${subscriptionFile}") || {
        rm -rf "${tempDir}"
        return 1
    }
    nodeCount=$(jq 'length' <<<"${supportedNodes}")
    if ((nodeCount == 0)); then
        echoContent red " ---> 订阅中没有可用的 Shadowsocks 或 VLESS Reality 节点"
        rm -rf "${tempDir}"
        return 1
    elif ((nodeCount == 1)); then
        selectedTag=$(jq -r '.[0].tag' <<<"${supportedNodes}")
    else
        jq -r 'to_entries[] |
            "\(.key + 1).\(.value.tag) [" +
            (if .value._relayType == "vless-reality" then "VLESS Reality" else "Shadowsocks" end) +
            "] -> \(.value.server):\(.value.server_port)"
        ' <<<"${supportedNodes}"
        read -r -p "请选择上游节点:" nodeIndex
        if [[ ! "${nodeIndex}" =~ ^[0-9]+$ ]] || ((nodeIndex < 1 || nodeIndex > nodeCount)); then
            rm -rf "${tempDir}"
            return 1
        fi
        selectedTag=$(jq -r --argjson index "$((nodeIndex - 1))" '.[$index].tag' <<<"${supportedNodes}")
    fi
    buildRelayOutboundFromSingBoxSubscription "${subscriptionFile}" "${selectedTag}" "${outboundTag}" "${generatedOutbound}" || {
        echoContent red " ---> 节点参数不完整或无法转换为 Xray 出站"
        rm -rf "${tempDir}"
        return 1
    }
    local profile
    profile=$(jq -n --arg id "${profileId}" --arg name "${profileName}" --argjson selectors "${relaySelectedSelectors}" \
        --arg outboundTag "${outboundTag}" --arg outboundFile "${outboundFile}" --arg url "${subscriptionUrl}" --arg selectedTag "${selectedTag}" \
        --arg nodeType "${relayBuiltSubscriptionType}" --arg protocol "${relayBuiltProtocol}" --arg label "${relayBuiltLabel}" \
        --arg address "${relayBuiltAddress}" --arg port "${relayBuiltPort}" --arg udpMode "${relaySelectedUdpMode}" '
        {id:$id,name:$name,source:"subscription",selectors:$selectors,outboundTag:$outboundTag,outboundFile:$outboundFile,
         subscription:{format:"sing-box-json",url:$url,selectedTag:$selectedTag,nodeType:$nodeType},
         tcp:{mode:"relay",protocol:$protocol,label:$label,address:$address,port:$port,bbrProfile:""},
         udp:(if $udpMode == "shared" then {mode:"shared",protocol:$protocol,label:$label,address:$address,port:$port,bbrProfile:""} else {mode:"direct",protocol:"",label:"直连",address:"",port:"",bbrProfile:""} end)}')
    activateRelayProfile "${profile}" "${generatedOutbound}" || {
        rm -rf "${tempDir}"
        return 1
    }
    rm -rf "${tempDir}"
    echoContent green " ---> 中转规则 ${profileName} 已启用: ${selectedTag} -> ${relayBuiltAddress}:${relayBuiltPort}"
}

# Generate one upstream outbound. The third argument indicates whether the outbound carries UDP.
buildRelayOutbound() {
    local outboundTag=$1 outputFile=$2 carriesUdp=$3 forcedProtocol=${4:-}
    local protocolChoice=${forcedProtocol}
    local relayAddress relayPort relayUUID relaySNI relayFlow
    local relayPath relayHost relayPublicKey relayShortId relayMldsa65Verify relayAuth relayBbrProfile
    local relayMethod relayPassword
    relayBuiltBbrProfile=

    if [[ -z "${protocolChoice}" ]]; then
        echoContent skyBlue "\n请选择上游节点已安装的协议"
        echoContent yellow "1.VLESS + TCP + TLS Vision [推荐用于 TCP]"
        echoContent yellow "2.VLESS + WebSocket + TLS"
        echoContent yellow "3.VLESS + Reality + Vision"
        echoContent yellow "4.Hysteria2 + TLS + QUIC [推荐用于游戏 UDP]"
        echoContent yellow "5.Shadowsocks [原生支持 TCP/UDP]"
        read -r -p "请选择:" protocolChoice
    fi
    if [[ ! "${protocolChoice}" =~ ^[1-5]$ ]]; then
        echoContent red " ---> 上游协议选择无效"
        return 1
    fi

    read -r -p "上游服务器地址（IP 或域名）:" relayAddress
    [[ -z "${relayAddress}" ]] && echoContent red " ---> 地址不能为空" && return 1

    read -r -p "上游服务器端口[443]:" relayPort
    relayPort=${relayPort:-443}
    if ! isValidPort "${relayPort}"; then
        echoContent red " ---> 端口必须为 1-65535"
        return 1
    fi

    case ${protocolChoice} in
        1)
            read -r -p "上游 Vision UUID:" relayUUID
            [[ -z "${relayUUID}" ]] && echoContent red " ---> UUID 不能为空" && return 1
            read -r -p "SNI[默认使用上游地址]:" relaySNI
            relaySNI=${relaySNI:-${relayAddress}}
            relayFlow="xtls-rprx-vision"
            if [[ "${carriesUdp}" == "true" ]]; then
                relayFlow="xtls-rprx-vision-udp443"
            fi
            jq -n --arg tag "${outboundTag}" --arg address "${relayAddress}" --argjson port "${relayPort}" \
                --arg id "${relayUUID}" --arg flow "${relayFlow}" --arg sni "${relaySNI}" '
            {outbounds:[{tag:$tag,protocol:"vless",settings:{vnext:[{address:$address,port:$port,users:[{id:$id,encryption:"none",flow:$flow}]}]},streamSettings:{network:"tcp",security:"tls",tlsSettings:{serverName:$sni,allowInsecure:false}}}]}' >"${outputFile}"
            relayBuiltProtocol="vision"
            relayBuiltLabel="VLESS + TCP + TLS Vision"
            ;;
        2)
            read -r -p "上游 WebSocket UUID:" relayUUID
            [[ -z "${relayUUID}" ]] && echoContent red " ---> UUID 不能为空" && return 1
            read -r -p "SNI[默认使用上游地址]:" relaySNI
            relaySNI=${relaySNI:-${relayAddress}}
            read -r -p "WebSocket Host[默认与 SNI 相同]:" relayHost
            relayHost=${relayHost:-${relaySNI}}
            read -r -p "WebSocket 路径[例:/ray]:" relayPath
            [[ -z "${relayPath}" ]] && echoContent red " ---> WebSocket 路径不能为空" && return 1
            [[ "${relayPath}" != /* ]] && relayPath="/${relayPath}"
            jq -n --arg tag "${outboundTag}" --arg address "${relayAddress}" --argjson port "${relayPort}" \
                --arg id "${relayUUID}" --arg sni "${relaySNI}" --arg host "${relayHost}" --arg path "${relayPath}" '
            {outbounds:[{tag:$tag,protocol:"vless",settings:{vnext:[{address:$address,port:$port,users:[{id:$id,encryption:"none"}]}]},streamSettings:{network:"ws",security:"tls",tlsSettings:{serverName:$sni,allowInsecure:false},wsSettings:{path:$path,headers:{Host:$host}}}}]}' >"${outputFile}"
            relayBuiltProtocol="websocket"
            relayBuiltLabel="VLESS + WebSocket + TLS"
            ;;
        3)
            read -r -p "上游 Reality UUID:" relayUUID
            [[ -z "${relayUUID}" ]] && echoContent red " ---> UUID 不能为空" && return 1
            read -r -p "Reality Server Name (SNI):" relaySNI
            [[ -z "${relaySNI}" ]] && echoContent red " ---> Reality SNI 不能为空" && return 1
            read -r -p "Reality Password/Public Key:" relayPublicKey
            [[ -z "${relayPublicKey}" ]] && echoContent red " ---> Reality Password/Public Key 不能为空" && return 1
            read -r -p "Reality Short ID[可留空]:" relayShortId
            read -r -p "Reality ML-DSA-65 Verify/PQV[未启用可留空]:" relayMldsa65Verify
            relayFlow="xtls-rprx-vision"
            if [[ "${carriesUdp}" == "true" ]]; then
                relayFlow="xtls-rprx-vision-udp443"
            fi
            jq -n --arg tag "${outboundTag}" --arg address "${relayAddress}" --argjson port "${relayPort}" \
                --arg id "${relayUUID}" --arg flow "${relayFlow}" --arg sni "${relaySNI}" --arg password "${relayPublicKey}" \
                --arg sid "${relayShortId}" --arg pqv "${relayMldsa65Verify}" '
            {outbounds:[{tag:$tag,protocol:"vless",settings:{vnext:[{address:$address,port:$port,users:[{id:$id,encryption:"none",flow:$flow}]}]},streamSettings:{network:"tcp",security:"reality",realitySettings:({show:false,serverName:$sni,fingerprint:"chrome",password:$password,shortId:$sid,spiderX:"/"} + if $pqv == "" then {} else {mldsa65Verify:$pqv} end)}}]}' >"${outputFile}"
            relayBuiltProtocol="reality"
            relayBuiltLabel="VLESS + Reality + Vision"
            ;;
        4)
            read -r -p "上游 Hysteria2 认证密码:" relayAuth
            [[ -z "${relayAuth}" ]] && echoContent red " ---> Hysteria2 认证密码不能为空" && return 1
            read -r -p "SNI[默认使用上游地址]:" relaySNI
            relaySNI=${relaySNI:-${relayAddress}}
            selectHysteria2BbrProfile "standard" "上游Hysteria2"
            relayBbrProfile=${selectedHysteria2BbrProfile}
            jq -n --arg tag "${outboundTag}" --arg address "${relayAddress}" --argjson port "${relayPort}" \
                --arg auth "${relayAuth}" --arg sni "${relaySNI}" --arg bbrProfile "${relayBbrProfile}" '
            {outbounds:[{tag:$tag,protocol:"hysteria",settings:{version:2,address:$address,port:$port},streamSettings:{network:"hysteria",security:"tls",tlsSettings:{serverName:$sni,allowInsecure:false,alpn:["h3"]},hysteriaSettings:{version:2,auth:$auth,udpIdleTimeout:60},finalmask:{quicParams:{congestion:"bbr",bbrProfile:$bbrProfile}}}}]}' >"${outputFile}"
            relayBuiltProtocol="hysteria2"
            relayBuiltLabel="Hysteria2 + TLS + QUIC"
            relayBuiltBbrProfile=${relayBbrProfile}
            ;;
        5)
            read -r -p "Shadowsocks 加密方式[aes-256-gcm]:" relayMethod
            relayMethod=${relayMethod:-aes-256-gcm}
            read -r -s -p "Shadowsocks 密码:" relayPassword
            echo
            [[ -z "${relayPassword}" ]] && echoContent red " ---> Shadowsocks 密码不能为空" && return 1
            jq -n --arg tag "${outboundTag}" --arg address "${relayAddress}" --argjson port "${relayPort}" \
                --arg method "${relayMethod}" --arg password "${relayPassword}" '
            {outbounds:[{tag:$tag,protocol:"shadowsocks",settings:{address:$address,port:$port,method:$method,password:$password}}]}' >"${outputFile}"
            relayBuiltProtocol="shadowsocks"
            relayBuiltLabel="Shadowsocks (${relayMethod})"
            ;;
    esac

    relayBuiltAddress=${relayAddress}
    relayBuiltPort=${relayPort}
    jq empty "${outputFile}" >/dev/null 2>&1 || {
        echoContent red " ---> 上游出站配置生成失败"
        return 1
    }
}

# Rebuild the relay routing from all profiles; inbounds that are not bound keep their existing routing.
rebuildRelayRouting() {
    local routingFile="${configPath}09_routing.json"
    # Other menus (reinstall, global IPv6/WARP modes) may have deleted it.
    [[ -f "${routingFile}" ]] || echo '{"routing":{"rules":[]}}' >"${routingFile}" || return 1
    ensureRelayStateV2 || return 1
    local relayRules managedTags newConfig
    relayRules=$(jq '
        [.profiles[]? as $profile |
            $profile.selectors[]? |
            {profile:$profile,selector:.}
        ] as $bindings |
        (
            [$bindings[] | select(((.selector.users // []) | length) > 0)] +
            [$bindings[] | select(((.selector.users // []) | length) == 0)]
        ) as $orderedBindings |
      [$orderedBindings[] |
        .profile as $profile |
        .selector as $selector |
        ($selector.users // []) as $users |
        [({type:"field",inboundTag:$selector.inboundTags,network:"tcp",outboundTag:$profile.outboundTag} +
            if ($users | length) > 0 then {user:$users} else {} end)] +
        (if $profile.udp.mode == "shared" then
            [({type:"field",inboundTag:$selector.inboundTags,network:"udp",outboundTag:$profile.outboundTag} +
                if ($users | length) > 0 then {user:$users} else {} end)]
         else [] end)
    ] | add // []' "${relayStateFile}") || return 1
    managedTags=$(jq '[.profiles[]?.outboundTag]' "${relayStateFile}") || return 1
    newConfig=$(jq --argjson rules "${relayRules}" --argjson managedTags "${managedTags}" '
        .routing.rules = ($rules + [.routing.rules[] |
            select((.outboundTag as $tag | ($managedTags | index($tag)) == null) and
                   (.outboundTag != "relay_outbound") and
                   (.outboundTag != "relay_tcp_outbound") and
                   (.outboundTag != "relay_udp_outbound") and
                   ((.outboundTag // "") | startswith("relay_profile_") | not))])
    ' "${routingFile}") || return 1
    echo "${newConfig}" >"${routingFile}.tmp.$$" && mv "${routingFile}.tmp.$$" "${routingFile}"
}

# Re-apply relay rules after something else rewrote or deleted
# 09_routing.json, so relay state and live routing cannot drift apart.
syncRelayRouting() {
    [[ -f "${relayStateFile}" ]] || return 0
    jq -e '(.profiles // []) | length > 0' "${relayStateFile}" >/dev/null 2>&1 || return 0
    rebuildRelayRouting
}

setupRelayManual() {
    local profileName=$1 profileId=$2
    local outboundTag="relay_profile_${profileId}" outboundFile="relay_${profileId}_outbound.json"
    selectRelayUdpMode
    local tempDir generatedOutbound carriesUdp profile
    tempDir=$(mktemp -d /tmp/xray-relay-manual.XXXXXX) || return 1
    generatedOutbound="${tempDir}/${outboundFile}"
    carriesUdp=false
    [[ "${relaySelectedUdpMode}" == "shared" ]] && carriesUdp=true
    buildRelayOutbound "${outboundTag}" "${generatedOutbound}" "${carriesUdp}" || {
        rm -rf "${tempDir}"
        return 1
    }
    profile=$(jq -n --arg id "${profileId}" --arg name "${profileName}" --argjson selectors "${relaySelectedSelectors}" \
        --arg outboundTag "${outboundTag}" --arg outboundFile "${outboundFile}" --arg protocol "${relayBuiltProtocol}" \
        --arg label "${relayBuiltLabel}" --arg address "${relayBuiltAddress}" --arg port "${relayBuiltPort}" \
        --arg bbrProfile "${relayBuiltBbrProfile}" --arg udpMode "${relaySelectedUdpMode}" '
        {id:$id,name:$name,source:"manual",selectors:$selectors,outboundTag:$outboundTag,outboundFile:$outboundFile,
         tcp:{mode:"relay",protocol:$protocol,label:$label,address:$address,port:$port,bbrProfile:$bbrProfile},
         udp:(if $udpMode == "shared" then {mode:"shared",protocol:$protocol,label:$label,address:$address,port:$port,bbrProfile:$bbrProfile} else {mode:"direct",protocol:"",label:"直连",address:"",port:"",bbrProfile:""} end)}')
    activateRelayProfile "${profile}" "${generatedOutbound}" || {
        rm -rf "${tempDir}"
        return 1
    }
    rm -rf "${tempDir}"
    echoContent green " ---> 中转规则 ${profileName} 已启用"
}

selectRelayDestination() {
    ensureRelayStateV2 || return 1
    local count selection newOption
    count=$(jq '.profiles | length' "${relayStateFile}")
    relayUseExistingProfile=false
    relaySelectedDestinationId=
    ((count == 0)) && return 0

    echoContent skyBlue "\n请选择目标上游"
    jq -r '.profiles | to_entries[] |
        "\(.key + 1).\(.value.name) -> \(.value.tcp.label) \(.value.tcp.address):\(.value.tcp.port)"
    ' "${relayStateFile}"
    newOption=$((count + 1))
    echoContent yellow "${newOption}.新建上游"
    read -r -p "请选择:" selection
    if [[ ! "${selection}" =~ ^[0-9]+$ ]] || ((selection < 1 || selection > newOption)); then
        echoContent red " ---> 上游选项无效"
        return 1
    fi
    if ((selection <= count)); then
        relayUseExistingProfile=true
        relaySelectedDestinationId=$(jq -r --argjson index "$((selection - 1))" '.profiles[$index].id' "${relayStateFile}")
    fi
}

setupRelay() {
    echoContent skyBlue "\n新增入口规则"
    echoContent yellow "# 一个上游可绑定多个入口；指定账号优先于「全部 UUID」兜底规则\n"
    selectRelayTargets || return
    selectRelayDestination || return
    if [[ "${relayUseExistingProfile}" == "true" ]]; then
        local selector
        # The selector list is read from fd 3 so the y/N prompt inside
        # relayTargetsAvailable still reads from the terminal.
        while read -r -u 3 selector; do
            relayTargetsAvailable "${selector}" "${relaySelectedDestinationId}" || return
        done 3< <(jq -c '.[]' <<<"${relaySelectedSelectors}")
        attachRelaySelectors "${relaySelectedDestinationId}" "${relaySelectedSelectors}"
        return
    fi
    local selector
    while read -r -u 3 selector; do
        relayTargetsAvailable "${selector}" || return
    done 3< <(jq -c '.[]' <<<"${relaySelectedSelectors}")

    echoContent skyBlue "\n请选择上游配置来源"
    echoContent yellow "1.sing-box JSON 订阅中的 Shadowsocks / VLESS Reality 节点"
    echoContent yellow "2.手动输入上游节点"
    local relaySource profileName profileId
    read -r -p "请选择:" relaySource
    [[ ! "${relaySource}" =~ ^[12]$ ]] && echoContent red " ---> 请输入 1-2" && return
    read -r -p "请输入规则名称[例:上游线路A/备用线路]:" profileName
    profileName=${profileName:-中转规则}
    profileId="$(date +%s)_${RANDOM}"
    case ${relaySource} in
        1) setupRelaySubscription "${profileName}" "${profileId}" ;;
        2) setupRelayManual "${profileName}" "${profileId}" ;;
    esac
}

showRelayConfig() {
    ensureRelayStateV2 || return
    local count
    count=$(jq '.profiles | length' "${relayStateFile}")
    if ((count == 0)); then
        echoContent yellow " ---> 当前未配置中转规则"
        return
    fi
    echoContent skyBlue "\n当前中转上游"
    jq -r "${relaySelectorJqDefs}"'.profiles | to_entries[] |
        "\(.key + 1). \(.value.name)\n" +
        (.value.selectors | to_entries | map(
            "   入口 \(.key + 1): \(.value.inboundTags | join(", ")) / 账号: " +
            (if ((.value.users // []) | length) > 0 then
                ([.value.users[] | displayUser] | join(", "))
             else "全部 UUID" end)
        ) | join("\n")) +
        "\n   TCP : \(.value.tcp.label) -> \(.value.tcp.address):\(.value.tcp.port)\n" +
        "   UDP : \(if .value.udp.mode == "shared" then (.value.udp.label + " -> " + .value.udp.address + ":" + .value.udp.port) else "直连" end)\n" +
        "   来源: \(if .value.source == "subscription" then "订阅自动更新" else "手动" end)"
    ' "${relayStateFile}"
}

updateRelaySubscriptionProfile() {
    local profileId=$1 profile subscriptionUrl selectedTag outboundTag outboundFile tempDir subscriptionFile generatedOutbound
    local supportedNodes preferredNodeType newState
    profile=$(jq -c --arg id "${profileId}" 'first(.profiles[] | select(.id == $id))' "${relayStateFile}") || return 1
    subscriptionUrl=$(jq -r '.subscription.url' <<<"${profile}")
    selectedTag=$(jq -r '.subscription.selectedTag' <<<"${profile}")
    preferredNodeType=$(jq -r '.subscription.nodeType // if .tcp.protocol == "reality" then "vless-reality" else "shadowsocks" end' <<<"${profile}")
    outboundTag=$(jq -r '.outboundTag' <<<"${profile}")
    outboundFile=$(jq -r '.outboundFile' <<<"${profile}")
    relayProfileFileIsSafe "${outboundFile}" || return 1
    tempDir=$(mktemp -d /tmp/xray-relay-update.XXXXXX) || return 1
    subscriptionFile="${tempDir}/subscription.json"
    generatedOutbound="${tempDir}/${outboundFile}"
    fetchRelaySubscription "${subscriptionUrl}" "${subscriptionFile}" || {
        rm -rf "${tempDir}"
        return 1
    }
    supportedNodes=$(getRelayNodesFromSingBoxSubscription "${subscriptionFile}") || {
        rm -rf "${tempDir}"
        return 1
    }
    if ! jq -e --arg tag "${selectedTag}" 'any(.[]; .tag == $tag)' <<<"${supportedNodes}" >/dev/null; then
        selectedTag=$(jq -r --arg nodeType "${preferredNodeType}" 'first(.[] | select(._relayType == $nodeType)).tag // empty' <<<"${supportedNodes}")
    fi
    if [[ -z "${selectedTag}" ]]; then
        echoContent red " ---> 更新后的订阅中没有同类型可用节点，保留旧配置"
        rm -rf "${tempDir}"
        return 1
    fi
    buildRelayOutboundFromSingBoxSubscription "${subscriptionFile}" "${selectedTag}" "${outboundTag}" "${generatedOutbound}" || {
        echoContent red " ---> 更新后的节点参数不完整，保留旧配置"
        rm -rf "${tempDir}"
        return 1
    }
    newState=$(jq --arg id "${profileId}" --arg tag "${selectedTag}" --arg nodeType "${relayBuiltSubscriptionType}" \
        --arg protocol "${relayBuiltProtocol}" --arg label "${relayBuiltLabel}" \
        --arg address "${relayBuiltAddress}" --arg port "${relayBuiltPort}" '
        .profiles |= map(if .id == $id then
            .subscription.selectedTag = $tag |
            .subscription.nodeType = $nodeType |
            .tcp.protocol = $protocol | .tcp.label = $label | .tcp.address = $address | .tcp.port = $port |
            if .udp.mode == "shared" then
                .udp.protocol = $protocol | .udp.label = $label | .udp.address = $address | .udp.port = $port
            else . end
        else . end)
    ' "${relayStateFile}") || {
        rm -rf "${tempDir}"
        return 1
    }
    if [[ -f "${configPath}${outboundFile}" ]] && cmp -s "${generatedOutbound}" "${configPath}${outboundFile}"; then
        writeRelayState "${newState}" || {
            rm -rf "${tempDir}"
            return 1
        }
        echoContent green " ---> $(jq -r '.name' <<<"${profile}"): 订阅没有变化"
        rm -rf "${tempDir}"
        return 0
    fi
    if ! commitRelayChange "订阅更新" installRelayOutbound "${generatedOutbound}" "${outboundFile}" "${newState}"; then
        echoContent red " ---> $(jq -r '.name' <<<"${profile}"): 新订阅配置验证失败，已保留旧配置"
        rm -rf "${tempDir}"
        return 1
    fi
    relaySubscriptionChanged=true
    echoContent green " ---> $(jq -r '.name' <<<"${profile}"): 已更新到 ${selectedTag} -> ${relayBuiltAddress}:${relayBuiltPort}"
    rm -rf "${tempDir}"
}

# Install a refreshed outbound file together with its updated state.
installRelayOutbound() {
    local generatedOutbound=$1 outboundFile=$2 newState=$3
    cp "${generatedOutbound}" "${configPath}${outboundFile}" || return 1
    chmod 600 "${configPath}${outboundFile}"
    writeRelayState "${newState}"
}

updateRelaySubscription() {
    withRelayLock updateAllRelaySubscriptions
}

updateAllRelaySubscriptions() {
    ensureRelayStateV2 || return 1
    local profileId updateFailed=false
    relaySubscriptionChanged=false
    while read -r profileId; do
        updateRelaySubscriptionProfile "${profileId}" || updateFailed=true
    done < <(jq -r '.profiles[]? | select(.source == "subscription").id' "${relayStateFile}")
    if [[ "${relaySubscriptionChanged}" == "true" ]]; then
        restartXray || updateFailed=true
    fi
    [[ "${updateFailed}" == "false" ]]
}

removeRelaySelector() {
    ensureRelayStateV2 || return
    local bindings count selection profileId selectorIndex
    bindings=$(jq -c '[
        .profiles[] as $profile |
        $profile.selectors | to_entries[] |
        {
            profileId:$profile.id,
            profileName:$profile.name,
            selectorIndex:.key,
            inboundTags:.value.inboundTags,
            users:(.value.users // [])
        }
    ]' "${relayStateFile}") || return 1
    count=$(jq 'length' <<<"${bindings}")
    ((count == 0)) && echoContent yellow " ---> 当前没有入口规则" && return
    jq -r "${relaySelectorJqDefs}"'to_entries[] |
        "\(.key + 1).\(.value.profileName) <- \(.value.inboundTags | join(", ")) / 账号: " +
        (if (.value.users | length) > 0 then
            ([.value.users[] | displayUser] | join(", "))
         else "全部 UUID" end)
    ' <<<"${bindings}"
    read -r -p "请选择要删除的入口规则:" selection
    if [[ ! "${selection}" =~ ^[0-9]+$ ]] || ((selection < 1 || selection > count)); then
        echoContent red " ---> 入口规则选项无效"
        return
    fi
    profileId=$(jq -r --argjson index "$((selection - 1))" '.[$index].profileId' <<<"${bindings}")
    selectorIndex=$(jq -r --argjson index "$((selection - 1))" '.[$index].selectorIndex' <<<"${bindings}")
    commitRelayChange "删除入口规则" updateRelayState jq --arg id "${profileId}" --argjson selectorIndex "${selectorIndex}" '
        .profiles |= map(if .id == $id then del(.selectors[$selectorIndex]) else . end) |
        .profiles |= map(select((.selectors | length) > 0))
    ' "${relayStateFile}" || return 1
    restartXray || return 1
    echoContent green " ---> 入口规则已删除"
}

removeRelayProfile() {
    ensureRelayStateV2 || return
    local count selection
    count=$(jq '.profiles | length' "${relayStateFile}")
    ((count == 0)) && echoContent yellow " ---> 当前没有中转上游" && return
    jq -r '.profiles | to_entries[] | "\(.key + 1).\(.value.name) [入口规则: \(.value.selectors | length) 条]"' "${relayStateFile}"
    read -r -p "请选择要删除的上游[其全部入口规则也会删除]:" selection
    if [[ ! "${selection}" =~ ^[0-9]+$ ]] || ((selection < 1 || selection > count)); then
        echoContent red " ---> 上游选项无效"
        return
    fi
    # The outbound file is removed by commitRelayChange once nothing uses it.
    commitRelayChange "删除中转上游" updateRelayState jq --argjson index "$((selection - 1))" \
        'del(.profiles[$index])' "${relayStateFile}" || return 1
    restartXray || return 1
    echoContent green " ---> 中转上游已删除"
}

removeRelay() {
    ensureRelayStateV2 || return
    commitRelayChange "停用全部中转" writeRelayState '{"version":2,"profiles":[]}' || return 1
    rm -f /opt/xray-agent/relay_config
    restartXray || return 1
    echoContent green " ---> 所有中转规则已停用，相关入站恢复原有分流"
}

# Remove deleted accounts from every selector. A selector that only listed
# those accounts is dropped entirely: an empty users list would otherwise
# mean "the whole inbound" and silently widen the rule.
# Usage: removeRelayUsers <xray-email>...
removeRelayUsers() {
    [[ -f "${relayStateFile}" ]] || return 0
    local emails
    emails=$(printf '%s\n' "$@" | jq -R . | jq -sc .)
    jq -e --argjson emails "${emails}" 'any(.profiles[]?.selectors[]?; ((.users // []) - $emails) != (.users // []))' \
        "${relayStateFile}" >/dev/null 2>&1 || return 0
    commitRelayChange "清理已删除账号的中转规则" updateRelayState jq --argjson emails "${emails}" '
        .profiles |= map(.selectors |= map(
            if ((.users // []) | length) == 0 then .
            else (.users -= $emails) | select((.users | length) > 0) end
        )) |
        .profiles |= map(select((.selectors | length) > 0))
    ' "${relayStateFile}"
}

manageRelay() {
    if [[ -z "${configPath}" ]]; then
        echoContent red " ---> 未安装，请使用脚本安装"
        return
    fi
    ensureRelayStateV2 || return
    local relayType profileCount selectorCount
    while true; do
        ensureRelayStateV2 || return
        profileCount=$(jq '.profiles | length' "${relayStateFile}")
        selectorCount=$(jq '[.profiles[]?.selectors[]?] | length' "${relayStateFile}")
        echoContent skyBlue "\n功能 1/${totalProgress} : 多规则中转管理"
        echoContent red "\n=============================================================="
        echoContent yellow "# 当前上游: ${profileCount} 个 / 入口规则: ${selectorCount} 条"
        echoContent yellow "1.新增入口规则"
        echoContent yellow "2.查看全部上游与入口"
        echoContent yellow "3.立即更新所有订阅规则"
        echoContent yellow "4.删除一条入口规则"
        echoContent yellow "5.删除一个上游"
        echoContent yellow "6.停用全部中转"
        echoContent yellow "0.返回主菜单"
        echoContent red "=============================================================="
        read -r -p "请选择:" relayType
        case ${relayType} in
            1) withRelayLock setupRelay ;;
            2) showRelayConfig ;;
            3) updateRelaySubscription ;;
            4) withRelayLock removeRelaySelector ;;
            5) withRelayLock removeRelayProfile ;;
            6) withRelayLock removeRelay ;;
            0) return ;;
            *) echoContent red " ---> 请输入 0-6" ;;
        esac
        read -r -p "按回车键继续..."
    done
}
# ==================== Routing tools ====================

# Routing tools
routingToolsMenu() {
    echoContent skyBlue "\n功能 1/${totalProgress} : 分流工具"
    echoContent red "\n=============================================================="
    echoContent yellow "# 注意事项"
    echoContent yellow "# 用于服务端的流量分流，可用于解锁ChatGPT、流媒体等相关内容\n"

    echoContent yellow "1.WARP分流【第三方 IPv4】"
    echoContent yellow "2.WARP分流【第三方 IPv6】"
    echoContent yellow "3.IPv6分流"
    echoContent yellow "4.Socks5分流【替换任意门分流】"
    echoContent yellow "5.DNS分流"
    echoContent yellow "6.SNI反向代理分流"

    read -r -p "请选择:" selectType

    case ${selectType} in
        1)
            warpRoutingReg 1 IPv4
            ;;
        2)
            warpRoutingReg 1 IPv6
            ;;
        3)
            ipv6Routing 1
            ;;
        4)
            socks5Routing
            ;;
        5)
            dnsRouting 1
            ;;
        6)
            sniRouting 1
            ;;
    esac

}
# SNI reverse proxy split routing
sniRouting() {

    if [[ -z "${configPath}" ]]; then
        echoContent red " ---> 未安装，请使用脚本安装"
        menu
        exit 0
    fi
    echoContent skyBlue "\n功能 1/${totalProgress} : SNI反向代理分流"
    echoContent red "\n=============================================================="
    echoContent yellow "# 注意事项\n"

    echoContent yellow "1.添加"
    echoContent yellow "2.卸载"
    read -r -p "请选择:" selectType

    case ${selectType} in
        1)
            setUnlockSNI
            ;;
        2)
            removeUnlockSNI
            ;;
    esac
}
# Set up SNI split routing
setUnlockSNI() {
    read -r -p "请输入分流的SNI IP:" setSNIP
    if [[ -n ${setSNIP} ]]; then
        echoContent red "=============================================================="
        echoContent yellow "录入示例:netflix,disney,hulu"
        read -r -p "请按照上面示例录入域名:" domainList

        if [[ -n "${domainList}" ]]; then
            local hosts={}
            while read -r domain; do
                hosts=$(echo "${hosts}" | jq -r ".\"geosite:${domain}\"=\"${setSNIP}\"")
            done < <(echo "${domainList}" | tr ',' '\n')
            cat <<EOF >${configPath}11_dns.json
{
    "dns": {
        "hosts":${hosts},
        "servers": [
            "8.8.8.8",
            "1.1.1.1"
        ]
    }
}
EOF
            echoContent red " ---> SNI反向代理分流成功"
            restartXray || return 1
        else
            echoContent red " ---> 域名不可为空"
        fi

    else

        echoContent red " ---> SNI IP不可为空"
    fi
    exit 0
}

# Remove SNI split routing
removeUnlockSNI() {
    cat <<EOF >${configPath}11_dns.json
{
	"dns": {
		"servers": [
			"localhost"
		]
	}
}
EOF
    restartXray || return 1

    echoContent green " ---> 卸载成功"

    exit 0
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

    handleNginx stop
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
    checkGFWStatue $((++step))
    showAccounts $((++step))
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
# Cron job check
cronFunction() {
    if [[ "${cronName}" == "RenewTLS" ]]; then
        renewalTLS
        exit 0
    elif [[ "${cronName}" == "UpdateGeo" ]]; then
        updateGeoSite >>/opt/xray-agent/crontab_updateGeoSite.log
        echoContent green " ---> geo更新日期:$(date "+%F %H:%M:%S")" >>/opt/xray-agent/crontab_updateGeoSite.log
        exit 0
    elif [[ "${cronName}" == "UpdateRelay" ]]; then
        updateRelaySubscription
        exit $?
    fi
}
# Account management
manageAccount() {
    if [[ -z "${configPath}" ]]; then
        echoContent red " ---> 未安装"
        return
    fi

    local manageAccountStatus
    while true; do
        echoContent skyBlue "\n功能 1/${totalProgress} : 账号管理"
        echoContent red "\n=============================================================="
        echoContent yellow "# 这里只管理服务端账号，不生成或修改订阅"
        echoContent yellow "# 添加账号时可自定义 UUID、tag 和目标协议\n"
        echoContent yellow "# 删除账号会从该 UUID 所属的全部协议中移除\n"
        echoContent yellow "1.查看账号"
        echoContent yellow "2.添加账号"
        echoContent yellow "3.删除账号"
        echoContent yellow "0.返回主菜单"
        echoContent red "=============================================================="
        read -r -p "请输入:" manageAccountStatus
        case ${manageAccountStatus} in
            1) listAccounts ;;
            2) addUser ;;
            3) removeUser ;;
            0) return ;;
            *) echoContent red " ---> 选择错误" ;;
        esac
        read -r -p "按回车键继续..."
    done
}
# Install the subscription service
installSubscribe() {
    readNginxSubscribe
    local nginxSubscribeListen=
    local nginxSubscribeSSL=
    local serverName=
    local SSLType=
    local listenIPv6=
    if [[ -z "${subscribePort}" ]]; then

        local nginxBin="nginx"
        if [[ -f "/www/server/nginx/sbin/nginx" ]]; then
            nginxBin="/www/server/nginx/sbin/nginx"
        fi
        nginxVersion=$("${nginxBin}" -v 2>&1)

        if echo "${nginxVersion}" | grep -q "not found" || [[ -z "${nginxVersion}" ]]; then
            echoContent yellow "未检测到nginx，无法使用订阅服务\n"
            read -r -p "是否安装[y/n]？" installNginxStatus
            if [[ "${installNginxStatus}" == "y" ]]; then
                installNginxTools
            else
                echoContent red " ---> 放弃安装nginx\n"
                exit 0
            fi
        fi
        echoContent yellow "开始配置订阅，请输入订阅的端口[默认443]\n"

        local subscribePortInput="${subscribePort}"
        if [[ -z "${subscribePortInput}" ]]; then
            read -r -p "端口:" subscribePortInput
            if [[ -z "${subscribePortInput}" ]]; then
                subscribePortInput=443
            fi
        fi
        result=("${subscribePortInput}")
        echo
        echoContent yellow " ---> 开始配置订阅的伪装站点\n"
        nginxBlog
        echo
        local httpSubscribeStatus=

        if ! echo "${selectCustomInstallType}" | grep -qE ",(0|1|3|6|12|14)," && ! echo "${currentInstallProtocolType}" | grep -qE ",(0|1|3|6|12|14)," && [[ -z "${domain}" ]]; then
            httpSubscribeStatus=true
        fi

        if [[ "${httpSubscribeStatus}" == "true" ]]; then

            echoContent yellow "未发现tls证书，使用无加密订阅，可能被运营商拦截，请注意风险。"
            echo
            read -r -p "是否使用http订阅[y/n]？" addNginxSubscribeStatus
            echo
            if [[ "${addNginxSubscribeStatus}" != "y" ]]; then
                echoContent yellow " ---> 退出安装"
                exit
            fi
        else
            local subscribeServerName=
            if [[ -n "${currentHost}" ]]; then
                subscribeServerName="${currentHost}"
            else
                subscribeServerName="${domain}"
            fi

            SSLType="ssl"
            serverName="server_name ${subscribeServerName};"
            nginxSubscribeSSL="ssl_certificate /opt/xray-agent/tls/${subscribeServerName}.crt;ssl_certificate_key /opt/xray-agent/tls/${subscribeServerName}.key;"
        fi
        if [[ -n "$(curl --connect-timeout 2 -s -6 http://www.cloudflare.com/cdn-cgi/trace | grep "ip" | cut -d "=" -f 2)" ]]; then
            listenIPv6="listen [::]:${result[-1]} ${SSLType};"
        fi
        if echo "${nginxVersion}" | grep -q "1.25" && [[ $(echo "${nginxVersion}" | awk -F "[.]" '{print $3}') -gt 0 ]] || [[ $(echo "${nginxVersion}" | awk -F "[.]" '{print $2}') -gt 25 ]]; then
            nginxSubscribeListen="listen ${result[-1]} ${SSLType} so_keepalive=on;http2 on;${listenIPv6}"
        else
            nginxSubscribeListen="listen ${result[-1]} ${SSLType} so_keepalive=on;${listenIPv6}"
        fi

        cat <<EOF >${nginxConfigPath}subscribe.conf
server {
    ${nginxSubscribeListen}
    ${serverName}
    ${nginxSubscribeSSL}
    ssl_protocols              TLSv1.2 TLSv1.3;
    ssl_ciphers                TLS13_AES_128_GCM_SHA256:TLS13_AES_256_GCM_SHA384:TLS13_CHACHA20_POLY1305_SHA256:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305;
    ssl_prefer_server_ciphers  on;

    resolver                   1.1.1.1 valid=60s;
    resolver_timeout           2s;
    client_max_body_size 100m;
    root ${nginxStaticPath};
    location ~ ^/s/(clashMeta|default|clashMetaProfiles)/(.*) {
        default_type 'text/plain; charset=utf-8';
        alias /opt/xray-agent/subscribe/\$1/\$2;
    }
    location / {
    }
}
EOF
        bootStartup nginx
        handleNginx stop
        handleNginx start
    fi
    if [[ -z $(pgrep -f "nginx") ]]; then
        handleNginx start
    fi
}
# Uninstall the subscription service
unInstallSubscribe() {
    rm -rf ${nginxConfigPath}subscribe.conf >/dev/null 2>&1
}

# Add a subscription
addSubscribeMenu() {
    echoContent skyBlue "\n===================== 添加其他机器订阅 ======================="
    echoContent yellow "1.添加"
    echoContent yellow "2.移除"
    echoContent red "=============================================================="
    read -r -p "请选择:" addSubscribeStatus
    if [[ "${addSubscribeStatus}" == "1" ]]; then
        addOtherSubscribe
    elif [[ "${addSubscribeStatus}" == "2" ]]; then
        if [[ ! -f "/opt/xray-agent/subscribe_remote/remoteSubscribeUrl" ]]; then
            echoContent green " ---> 未安装其他订阅"
            exit 0
        fi
        grep -v '^$' "/opt/xray-agent/subscribe_remote/remoteSubscribeUrl" | awk '{print NR""":"$0}'
        read -r -p "请选择要删除的订阅编号[仅支持单个删除]:" delSubscribeIndex
        if [[ -z "${delSubscribeIndex}" ]]; then
            echoContent green " ---> 不可以为空"
            exit 0
        fi

        sed -i "$((delSubscribeIndex))d" "/opt/xray-agent/subscribe_remote/remoteSubscribeUrl" >/dev/null 2>&1

        echoContent green " ---> 其他机器订阅删除成功"
        subscribe
    fi
}

manageSubscriptions() {
    if [[ -z "${configPath}" ]]; then
        echoContent red " ---> 未安装"
        return
    fi

    local subscriptionManageStatus
    while true; do
        echoContent skyBlue "\n订阅管理"
        echoContent red "\n=============================================================="
        echoContent yellow "1.查看或重新生成本机订阅"
        echoContent yellow "2.管理其他机器订阅"
        echoContent yellow "0.返回主菜单"
        echoContent red "=============================================================="
        read -r -p "请选择:" subscriptionManageStatus
        case ${subscriptionManageStatus} in
            1) subscribe ;;
            2) addSubscribeMenu ;;
            0) return ;;
            *) echoContent red " ---> 请输入 0-2" ;;
        esac
        read -r -p "按回车键继续..."
    done
}

# Add a clashMeta subscription from another machine
addOtherSubscribe() {
    echoContent yellow "#注意事项:"
    echoContent skyBlue "录入示例：example.com:443:vps1\n"
    read -r -p "请输入域名 端口 机器别名:" remoteSubscribeUrl
    if [[ -z "${remoteSubscribeUrl}" ]]; then
        echoContent red " ---> 不可为空"
        addOtherSubscribe
    elif ! echo "${remoteSubscribeUrl}" | grep -q ":"; then
        echoContent red " ---> 规则不合法"
    else

        if [[ -f "/opt/xray-agent/subscribe_remote/remoteSubscribeUrl" ]] && grep -q "${remoteSubscribeUrl}" /opt/xray-agent/subscribe_remote/remoteSubscribeUrl; then
            echoContent red " ---> 此订阅已添加"
            exit 0
        fi
        echo
        read -r -p "是否是HTTP订阅？[y/n]" httpSubscribeStatus
        if [[ "${httpSubscribeStatus}" == "y" ]]; then
            remoteSubscribeUrl="${remoteSubscribeUrl}:http"
        fi
        echo "${remoteSubscribeUrl}" >>/opt/xray-agent/subscribe_remote/remoteSubscribeUrl
        subscribe
    fi
}
# clashMeta config file
clashMetaConfig() {
    local url=$1
    local id=$2
    cat <<EOF >"/opt/xray-agent/subscribe/clashMetaProfiles/${id}"
log-level: debug
mode: rule
ipv6: true
mixed-port: 7890
allow-lan: true
bind-address: "*"
lan-allowed-ips:
  - 0.0.0.0/0
  - ::/0
find-process-mode: strict
external-controller: 0.0.0.0:9090

geox-url:
  geoip: "https://fastly.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geoip.dat"
  geosite: "https://fastly.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geosite.dat"
  mmdb: "https://fastly.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geoip.metadb"
geo-auto-update: true
geo-update-interval: 24

external-controller-cors:
  allow-private-network: true

global-client-fingerprint: chrome

profile:
  store-selected: true
  store-fake-ip: true

sniffer:
  enable: true
  override-destination: false
  sniff:
    QUIC:
      ports: [ 443 ]
    TLS:
      ports: [ 443 ]
    HTTP:
      ports: [80]


dns:
  enable: true
  prefer-h3: false
  listen: 0.0.0.0:1053
  ipv6: true
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.1/16
  fake-ip-filter:
    - '*.lan'
    - '*.local'
    - 'dns.google'
    - "localhost.ptlogin2.qq.com"
  use-hosts: true
  nameserver:
    - https://1.1.1.1/dns-query
    - https://8.8.8.8/dns-query
    - 1.1.1.1
    - 8.8.8.8
  proxy-server-nameserver:
    - https://223.5.5.5/dns-query
    - https://1.12.12.12/dns-query
  nameserver-policy:
    "geosite:cn,private":
      - https://doh.pub/dns-query
      - https://dns.alidns.com/dns-query

proxy-providers:
  ${subscribeSalt}_provider:
    type: http
    path: ./${subscribeSalt}_provider.yaml
    url: ${url}
    interval: 3600
    proxy: DIRECT
    health-check:
      enable: true
      url: https://cp.cloudflare.com/generate_204
      interval: 300

proxy-groups:
  - name: 手动切换
    type: select
    use:
      - ${subscribeSalt}_provider
    proxies: null
  - name: 自动选择
    type: url-test
    url: http://www.gstatic.com/generate_204
    interval: 36000
    tolerance: 50
    use:
      - ${subscribeSalt}_provider
    proxies: null

  - name: 全球代理
    type: select
    use:
      - ${subscribeSalt}_provider
    proxies:
      - 手动切换
      - 自动选择

  - name: 流媒体
    type: select
    use:
      - ${subscribeSalt}_provider
    proxies:
      - 手动切换
      - 自动选择
      - DIRECT
  - name: DNS_Proxy
    type: select
    use:
      - ${subscribeSalt}_provider
    proxies:
      - 自动选择
      - DIRECT

  - name: Telegram
    type: select
    use:
      - ${subscribeSalt}_provider
    proxies:
      - 手动切换
      - 自动选择
  - name: Google
    type: select
    use:
      - ${subscribeSalt}_provider
    proxies:
      - 手动切换
      - 自动选择
      - DIRECT
  - name: YouTube
    type: select
    use:
      - ${subscribeSalt}_provider
    proxies:
      - 手动切换
      - 自动选择
  - name: Netflix
    type: select
    use:
      - ${subscribeSalt}_provider
    proxies:
      - 流媒体
      - 手动切换
      - 自动选择
  - name: Spotify
    type: select
    use:
      - ${subscribeSalt}_provider
    proxies:
      - 流媒体
      - 手动切换
      - 自动选择
      - DIRECT
  - name: HBO
    type: select
    use:
      - ${subscribeSalt}_provider
    proxies:
      - 流媒体
      - 手动切换
      - 自动选择
  - name: Bing
    type: select
    use:
      - ${subscribeSalt}_provider
    proxies:
      - 自动选择
  - name: OpenAI
    type: select
    use:
      - ${subscribeSalt}_provider
    proxies:
      - 自动选择
      - 手动切换
  - name: ClaudeAI
    type: select
    use:
      - ${subscribeSalt}_provider
    proxies:
      - 自动选择
      - 手动切换
  - name: Disney
    type: select
    use:
      - ${subscribeSalt}_provider
    proxies:
      - 流媒体
      - 手动切换
      - 自动选择
  - name: GitHub
    type: select
    use:
      - ${subscribeSalt}_provider
    proxies:
      - 手动切换
      - 自动选择
      - DIRECT

  - name: 国内媒体
    type: select
    use:
      - ${subscribeSalt}_provider
    proxies:
      - DIRECT
  - name: 本地直连
    type: select
    use:
      - ${subscribeSalt}_provider
    proxies:
      - DIRECT
      - 自动选择
  - name: 漏网之鱼
    type: select
    use:
      - ${subscribeSalt}_provider
    proxies:
      - DIRECT
      - 手动切换
      - 自动选择
rule-providers:
  lan:
    type: http
    behavior: classical
    interval: 86400
    url: https://gh-proxy.com/https://raw.githubusercontent.com/blackmatrix7/ios_rule_script/master/rule/Clash/Lan/Lan.yaml
    path: ./Rules/lan.yaml
  reject:
    type: http
    behavior: domain
    url: https://gh-proxy.com/https://raw.githubusercontent.com/Loyalsoldier/clash-rules/release/reject.txt
    path: ./ruleset/reject.yaml
    interval: 86400
  proxy:
    type: http
    behavior: domain
    url: https://gh-proxy.com/https://raw.githubusercontent.com/Loyalsoldier/clash-rules/release/proxy.txt
    path: ./ruleset/proxy.yaml
    interval: 86400
  direct:
    type: http
    behavior: domain
    url: https://gh-proxy.com/https://raw.githubusercontent.com/Loyalsoldier/clash-rules/release/direct.txt
    path: ./ruleset/direct.yaml
    interval: 86400
  private:
    type: http
    behavior: domain
    url: https://gh-proxy.com/https://raw.githubusercontent.com/Loyalsoldier/clash-rules/release/private.txt
    path: ./ruleset/private.yaml
    interval: 86400
  gfw:
    type: http
    behavior: domain
    url: https://gh-proxy.com/https://raw.githubusercontent.com/Loyalsoldier/clash-rules/release/gfw.txt
    path: ./ruleset/gfw.yaml
    interval: 86400
  greatfire:
    type: http
    behavior: domain
    url: https://gh-proxy.com/https://raw.githubusercontent.com/Loyalsoldier/clash-rules/release/greatfire.txt
    path: ./ruleset/greatfire.yaml
    interval: 86400
  tld-not-cn:
    type: http
    behavior: domain
    url: https://gh-proxy.com/https://raw.githubusercontent.com/Loyalsoldier/clash-rules/release/tld-not-cn.txt
    path: ./ruleset/tld-not-cn.yaml
    interval: 86400
  telegramcidr:
    type: http
    behavior: ipcidr
    url: https://gh-proxy.com/https://raw.githubusercontent.com/Loyalsoldier/clash-rules/release/telegramcidr.txt
    path: ./ruleset/telegramcidr.yaml
    interval: 86400
  applications:
    type: http
    behavior: classical
    url: https://gh-proxy.com/https://raw.githubusercontent.com/Loyalsoldier/clash-rules/release/applications.txt
    path: ./ruleset/applications.yaml
    interval: 86400
  Disney:
    type: http
    behavior: classical
    url: https://gh-proxy.com/https://raw.githubusercontent.com/blackmatrix7/ios_rule_script/master/rule/Clash/Disney/Disney.yaml
    path: ./ruleset/disney.yaml
    interval: 86400
  Netflix:
    type: http
    behavior: classical
    url: https://gh-proxy.com/https://raw.githubusercontent.com/blackmatrix7/ios_rule_script/master/rule/Clash/Netflix/Netflix.yaml
    path: ./ruleset/netflix.yaml
    interval: 86400
  YouTube:
    type: http
    behavior: classical
    url: https://gh-proxy.com/https://raw.githubusercontent.com/blackmatrix7/ios_rule_script/master/rule/Clash/YouTube/YouTube.yaml
    path: ./ruleset/youtube.yaml
    interval: 86400
  HBO:
    type: http
    behavior: classical
    url: https://gh-proxy.com/https://raw.githubusercontent.com/blackmatrix7/ios_rule_script/master/rule/Clash/HBO/HBO.yaml
    path: ./ruleset/hbo.yaml
    interval: 86400
  OpenAI:
    type: http
    behavior: classical
    url: https://gh-proxy.com/https://raw.githubusercontent.com/blackmatrix7/ios_rule_script/master/rule/Clash/OpenAI/OpenAI.yaml
    path: ./ruleset/openai.yaml
    interval: 86400
  ClaudeAI:
    type: http
    behavior: classical
    url: https://gh-proxy.com/https://raw.githubusercontent.com/blackmatrix7/ios_rule_script/master/rule/Clash/Claude/Claude.yaml
    path: ./ruleset/claudeai.yaml
    interval: 86400
  Bing:
    type: http
    behavior: classical
    url: https://gh-proxy.com/https://raw.githubusercontent.com/blackmatrix7/ios_rule_script/master/rule/Clash/Bing/Bing.yaml
    path: ./ruleset/bing.yaml
    interval: 86400
  Google:
    type: http
    behavior: classical
    url: https://gh-proxy.com/https://raw.githubusercontent.com/blackmatrix7/ios_rule_script/master/rule/Clash/Google/Google.yaml
    path: ./ruleset/google.yaml
    interval: 86400
  GitHub:
    type: http
    behavior: classical
    url: https://gh-proxy.com/https://raw.githubusercontent.com/blackmatrix7/ios_rule_script/master/rule/Clash/GitHub/GitHub.yaml
    path: ./ruleset/github.yaml
    interval: 86400
  Spotify:
    type: http
    behavior: classical
    url: https://gh-proxy.com/https://raw.githubusercontent.com/blackmatrix7/ios_rule_script/master/rule/Clash/Spotify/Spotify.yaml
    path: ./ruleset/spotify.yaml
    interval: 86400
  ChinaMaxDomain:
    type: http
    behavior: domain
    interval: 86400
    url: https://gh-proxy.com/https://raw.githubusercontent.com/blackmatrix7/ios_rule_script/master/rule/Clash/ChinaMax/ChinaMax_Domain.yaml
    path: ./Rules/ChinaMaxDomain.yaml
  ChinaMaxIPNoIPv6:
    type: http
    behavior: ipcidr
    interval: 86400
    url: https://gh-proxy.com/https://raw.githubusercontent.com/blackmatrix7/ios_rule_script/master/rule/Clash/ChinaMax/ChinaMax_IP_No_IPv6.yaml
    path: ./Rules/ChinaMaxIPNoIPv6.yaml
rules:
  - RULE-SET,YouTube,YouTube,no-resolve
  - RULE-SET,Google,Google,no-resolve
  - RULE-SET,GitHub,GitHub
  - RULE-SET,telegramcidr,Telegram,no-resolve
  - RULE-SET,Spotify,Spotify,no-resolve
  - RULE-SET,Netflix,Netflix
  - RULE-SET,HBO,HBO
  - RULE-SET,Bing,Bing
  - RULE-SET,OpenAI,OpenAI
  - RULE-SET,ClaudeAI,ClaudeAI
  - RULE-SET,Disney,Disney
  - RULE-SET,proxy,全球代理
  - RULE-SET,gfw,全球代理
  - RULE-SET,applications,本地直连
  - RULE-SET,ChinaMaxDomain,本地直连
  - RULE-SET,ChinaMaxIPNoIPv6,本地直连,no-resolve
  - RULE-SET,lan,本地直连,no-resolve
  - GEOIP,CN,本地直连
  - MATCH,漏网之鱼
EOF

}
# Random salt
initRandomSalt() {
    local chars="abcdefghijklmnopqrtuxyz"
    local initCustomPath=
    for i in {1..10}; do
        echo "${i}" >/dev/null
        initCustomPath+="${chars:RANDOM%${#chars}:1}"
    done
    echo "${initCustomPath}"
}
# Subscription
subscribe() {
    readInstallProtocolType
    installSubscribe

    readNginxSubscribe
    local renewSalt=$1
    local showStatus=$2
    if [[ "${coreInstallType}" == "1" ]]; then

        echoContent skyBlue "-------------------------备注---------------------------------"
        echoContent yellow "# 查看订阅会重新生成本地账号的订阅"
        echoContent red "# 需要手动输入md5加密的salt值，如果不了解使用随机即可"
        echoContent yellow "# 不影响已添加的远程订阅的内容\n"

        if [[ -f "/opt/xray-agent/subscribe_local/subscribeSalt" && -n $(cat "/opt/xray-agent/subscribe_local/subscribeSalt") ]]; then
            if [[ -z "${renewSalt}" ]]; then
                read -r -p "读取到上次安装设置的Salt，是否使用上次生成的Salt ？[y/n]:" historySaltStatus
                if [[ "${historySaltStatus}" == "y" ]]; then
                    subscribeSalt=$(cat /opt/xray-agent/subscribe_local/subscribeSalt)
                else
                    read -r -p "请输入salt值, [回车]使用随机:" subscribeSalt
                fi
            else
                subscribeSalt=$(cat /opt/xray-agent/subscribe_local/subscribeSalt)
            fi
        else
            read -r -p "请输入salt值, [回车]使用随机:" subscribeSalt
            showStatus=
        fi

        if [[ -z "${subscribeSalt}" ]]; then
            subscribeSalt=$(initRandomSalt)
        fi
        echoContent yellow "\n ---> Salt: ${subscribeSalt}"

        echo "${subscribeSalt}" >/opt/xray-agent/subscribe_local/subscribeSalt

        rm -rf /opt/xray-agent/subscribe/default/*
        rm -rf /opt/xray-agent/subscribe/clashMeta/*
        rm -rf /opt/xray-agent/subscribe_local/default/*
        rm -rf /opt/xray-agent/subscribe_local/clashMeta/*
        showAccounts >/dev/null
        if [[ -n $(ls /opt/xray-agent/subscribe_local/default/) ]]; then
            if [[ -f "/opt/xray-agent/subscribe_remote/remoteSubscribeUrl" && -n $(cat "/opt/xray-agent/subscribe_remote/remoteSubscribeUrl") ]]; then
                if [[ -z "${renewSalt}" ]]; then
                    read -r -p "读取到其他订阅，是否更新？[y/n]" updateOtherSubscribeStatus
                else
                    updateOtherSubscribeStatus=y
                fi
            fi
            local subscribePortLocal="${subscribePort}"
            find /opt/xray-agent/subscribe_local/default/* | while read -r email; do
                email=$(echo "${email}" | awk -F "[d][e][f][a][u][l][t][/]" '{print $2}')

                local emailMd5=
                emailMd5=$(echo -n "${email}${subscribeSalt}"$'\n' | md5sum | awk '{print $1}')

                cat "/opt/xray-agent/subscribe_local/default/${email}" >>"/opt/xray-agent/subscribe/default/${emailMd5}"
                if [[ "${updateOtherSubscribeStatus}" == "y" ]]; then
                    updateRemoteSubscribe "${emailMd5}" "${email}"
                fi
                local base64Result
                base64Result=$(base64 -w 0 "/opt/xray-agent/subscribe/default/${emailMd5}")
                echo "${base64Result}" >"/opt/xray-agent/subscribe/default/${emailMd5}"
                echoContent yellow "--------------------------------------------------------------"
                local currentDomain=${currentHost}

                if [[ -n "${currentDefaultPort}" && "${currentDefaultPort}" != "443" ]]; then
                    currentDomain="${currentHost}:${currentDefaultPort}"
                fi
                if [[ -n "${subscribePortLocal}" ]]; then
                    if [[ "${subscribeType}" == "http" ]]; then
                        currentDomain="$(getPublicIP):${subscribePort}"
                    else
                        currentDomain="${currentHost}:${subscribePort}"
                    fi
                fi
                if [[ -z "${showStatus}" ]]; then
                    echoContent skyBlue "\n----------默认订阅----------\n"
                    echoContent green "email:${email}\n"
                    echoContent yellow "url:${subscribeType}://${currentDomain}/s/default/${emailMd5}\n"
                    echoContent yellow "在线二维码:https://api-qr-server.zwen.cc/v1/create-qr-code/?size=400x400&data=${subscribeType}://${currentDomain}/s/default/${emailMd5}\n"
                    echo "${subscribeType}://${currentDomain}/s/default/${emailMd5}" | qrencode -s 10 -m 1 -t UTF8

                    # clashMeta
                    if [[ -f "/opt/xray-agent/subscribe_local/clashMeta/${email}" ]]; then

                        cat "/opt/xray-agent/subscribe_local/clashMeta/${email}" >>"/opt/xray-agent/subscribe/clashMeta/${emailMd5}"

                        sed -i '1i\proxies:' "/opt/xray-agent/subscribe/clashMeta/${emailMd5}"

                        local clashProxyUrl="${subscribeType}://${currentDomain}/s/clashMeta/${emailMd5}"
                        clashMetaConfig "${clashProxyUrl}" "${emailMd5}"
                        echoContent skyBlue "\n----------clashMeta订阅----------\n"
                        echoContent yellow "url:${subscribeType}://${currentDomain}/s/clashMetaProfiles/${emailMd5}\n"
                        echoContent yellow "在线二维码:https://api-qr-server.zwen.cc/v1/create-qr-code/?size=400x400&data=${subscribeType}://${currentDomain}/s/clashMetaProfiles/${emailMd5}\n"
                        echo "${subscribeType}://${currentDomain}/s/clashMetaProfiles/${emailMd5}" | qrencode -s 10 -m 1 -t UTF8

                    fi
                    echoContent skyBlue "--------------------------------------------------------------"
                else
                    echoContent green " ---> email:${email}，订阅已更新，请使用客户端重新拉取"
                fi

            done
        fi
    else
        echoContent red " ---> 未安装伪装站点，无法使用订阅服务"
    fi
}

# Update remote subscriptions
updateRemoteSubscribe() {

    local emailMD5=$1
    local email=$2
    while read -r line; do
        local subscribeType=
        subscribeType="https"

        local serverAlias=
        serverAlias=$(echo "${line}" | awk -F "[:]" '{print $3}')

        local remoteUrl=
        remoteUrl=$(echo "${line}" | awk -F "[:]" '{print $1":"$2}')

        local subscribeTypeRemote=
        subscribeTypeRemote=$(echo "${line}" | awk -F "[:]" '{print $4}')

        if [[ -n "${subscribeTypeRemote}" ]]; then
            subscribeType="${subscribeTypeRemote}"
        fi
        local clashMetaProxies=

        clashMetaProxies=$(curl --fail --silent --show-error --connect-timeout 10 --max-time 30 "${subscribeType}://${remoteUrl}/s/clashMeta/${emailMD5}" | sed '/proxies:/d' | sed "s/\"${email}/\"${email}_${serverAlias}/g")

        if ! echo "${clashMetaProxies}" | grep -q "nginx" && [[ -n "${clashMetaProxies}" ]]; then
            echo "${clashMetaProxies}" >>"/opt/xray-agent/subscribe/clashMeta/${emailMD5}"
            echoContent green " ---> clashMeta订阅 ${remoteUrl}:${email} 更新成功"
        else
            echoContent red " ---> clashMeta订阅 ${remoteUrl}:${email}不存在"
        fi

        local default=
        default=$(curl --fail --silent --show-error --connect-timeout 10 --max-time 30 "${subscribeType}://${remoteUrl}/s/default/${emailMD5}")

        if ! echo "${default}" | grep -q "nginx" && [[ -n "${default}" ]]; then
            default=$(echo "${default}" | base64 -d | sed "s/#${email}/#${email}_${serverAlias}/g")
            echo "${default}" >>"/opt/xray-agent/subscribe/default/${emailMD5}"

            echoContent green " ---> 通用订阅 ${remoteUrl}:${email} 更新成功"
        else
            echoContent red " ---> 通用订阅 ${remoteUrl}:${email} 不存在"
        fi

    done < <(grep -v '^$' <"/opt/xray-agent/subscribe_remote/remoteSubscribeUrl")
}
# Read a key from `xray x25519` output. The public key line changed from
# "Password: <key>" to "Password (PublicKey): <key>" in Xray 26.x, so take
# whatever follows ": " instead of the second whitespace field.
# Usage: parseX25519Field <output> private|public
parseX25519Field() {
    local pattern='^(PrivateKey|Private key)'
    [[ "$2" == "public" ]] && pattern='^(Password|Public key)'
    awk -F': ' -v pattern="${pattern}" '$0 ~ pattern {print $2; exit}' <<<"$1"
}

isValidRealityKey() {
    [[ "$1" =~ ^[A-Za-z0-9_-]{43}$ ]]
}

# Installs made with Xray 26.x before the parsing fix stored the literal
# "(PublicKey):" as the public key. The server only needs the private key,
# so recover the public key from it.
repairRealityPublicKey() {
    isValidRealityKey "${currentRealityPublicKey}" && return 0
    isValidRealityKey "${currentRealityPrivateKey}" || return 0
    [[ -x "${xrayBinary}" ]] || return 0
    local derived
    derived=$(parseX25519Field "$("${xrayBinary}" x25519 -i "${currentRealityPrivateKey}")" public)
    isValidRealityKey "${derived}" && currentRealityPublicKey=${derived}
}

# Initialize the Reality key
initRealityKey() {
    echoContent skyBlue "\n================ 生成 Reality 密钥对 ===============\n"
    echoContent yellow "📌 Reality 密钥说明："
    echoContent white "   • Private Key (私钥): 服务器端使用，必须保密"
    echoContent white "   • Public Key (公钥):  客户端使用，可以公开"
    echoContent white "   • 基于 X25519 椭圆曲线算法\n"

    # Always ask whether to reuse the previous key pair, regardless of lastInstallationConfig
    if [[ -n "${currentRealityPublicKey}" ]]; then
        echoContent yellow "检测到上次安装的密钥对"
        echoContent green "Public Key:  ${currentRealityPublicKey}"
        echoContent green "Private Key: ${currentRealityPrivateKey}\n"
        read -r -p "是否使用上次的密钥对？[y/n]:" historyKeyStatus
        if [[ "${historyKeyStatus}" == "y" ]]; then
            realityPrivateKey=${currentRealityPrivateKey}
            realityPublicKey=${currentRealityPublicKey}
        fi
    fi
    if [[ -z "${realityPrivateKey}" ]]; then
        echoContent yellow "💡 通常选择："
        echoContent green "   • 回车 - 自动生成（推荐⭐）"
        echoContent green "   • 手动输入 - 使用已有私钥（高级）\n"
        read -r -p "请输入 Private Key [回车自动生成]:" historyPrivateKey
        if [[ -n "${historyPrivateKey}" ]]; then
            realityX25519Key=$(/opt/xray-agent/xray/xray x25519 -i "${historyPrivateKey}")
        else
            echoContent green "正在生成密钥对...\n"
            realityX25519Key=$(/opt/xray-agent/xray/xray x25519)
        fi
        realityPrivateKey=$(parseX25519Field "${realityX25519Key}" private)
        realityPublicKey=$(parseX25519Field "${realityX25519Key}" public)
        if [[ -z "${realityPrivateKey}" ]]; then
            echoContent red "❌ 输入的 Private Key 不合法"
            initRealityKey
        else
            echoContent green "\n✅ 密钥对生成成功："
            echoContent green "   Private Key: ${realityPrivateKey}"
            echoContent green "   Public Key:  ${realityPublicKey}\n"
        fi
    fi
}
# Initialize mldsa65Seed
initRealityMldsa65() {
    echoContent skyBlue "\n生成Reality mldsa65\n"
    if /opt/xray-agent/xray/xray tls ping "${realityServerName}:${realityDomainPort}" 2>/dev/null | grep -q "X25519MLKEM768"; then
        length=$(/opt/xray-agent/xray/xray tls ping "${realityServerName}:${realityDomainPort}" | grep "Certificate chain's total length:" | awk '{print $5}' | head -1)

        if [ "$length" -gt 3500 ]; then
            if [[ -n "${currentRealityMldsa65}" && -z "${lastInstallationConfig}" ]]; then
                read -r -p "读取到上次安装记录，是否使用上次安装时的Seed/Verify ？[y/n]:" historyMldsa65Status
                if [[ "${historyMldsa65Status}" == "y" ]]; then
                    realityMldsa65Seed=${currentRealityMldsa65Seed}
                    realityMldsa65Verify=${currentRealityMldsa65Verify}
                fi
            elif [[ -n "${currentRealityMldsa65Seed}" && -n "${lastInstallationConfig}" ]]; then
                realityMldsa65Seed=${currentRealityMldsa65Seed}
                realityMldsa65Verify=${currentRealityMldsa65Verify}
            fi
            if [[ -z "${realityMldsa65Seed}" ]]; then
                realityMldsa65=$(/opt/xray-agent/xray/xray mldsa65)
                realityMldsa65Seed=$(echo "${realityMldsa65}" | head -1 | awk '{print $2}')
                realityMldsa65Verify=$(echo "${realityMldsa65}" | tail -n 1 | awk '{print $2}')
            fi
        else
            echoContent green " 目标域名支持X25519MLKEM768，但是证书的长度不足，忽略ML-DSA-65。"
        fi
    else
        echoContent green " 目标域名不支持X25519MLKEM768，忽略ML-DSA-65。"
    fi
}

# Initialize the client-usable serverNames
initRealityClientServersName() {
    local realityDestDomainList="gateway.icloud.com,itunes.apple.com,swdist.apple.com,swcdn.apple.com,updates.cdn-apple.com,mensura.cdn-apple.com,osxapps.itunes.apple.com,aod.itunes.apple.com,download-installer.cdn.mozilla.net,addons.mozilla.org,s0.awsstatic.com,d1.awsstatic.com,images-na.ssl-images-amazon.com,m.media-amazon.com,player.live-video.net,one-piece.com,lol.secure.dyn.riotcdn.net,www.swift.com,academy.nvidia.com,www.cisco.com,www.asus.com,www.samsung.com,www.amd.com,cdn-dynmedia-1.microsoft.com,software.download.prss.microsoft.com,dl.google.com,www.google-analytics.com"
    # Always ask whether to reuse the previous domain, regardless of lastInstallationConfig
    if [[ -n "${realityServerName}" ]]; then
        if echo ${realityDestDomainList} | grep -q "${realityServerName}"; then
            read -r -p "读取到上次安装设置的Reality域名，是否使用？[y/n]:" realityServerNameStatus
            if [[ "${realityServerNameStatus}" != "y" ]]; then
                realityServerName=
                realityDomainPort=
            fi
        else
            realityServerName=
            realityDomainPort=
        fi
    fi

    if [[ -z "${realityServerName}" ]]; then
        if [[ -n "${domain}" ]]; then
            echo
            read -r -p "是否使用 ${domain} 此域名作为Reality目标域名 ？[y/n]:" realityServerNameCurrentDomainStatus
            if [[ "${realityServerNameCurrentDomainStatus}" == "y" ]]; then
                realityServerName="${domain}"
                if [[ -z "${subscribePort}" ]]; then
                    echo
                    installSubscribe
                    readNginxSubscribe
                    realityDomainPort="${subscribePort}"
                else
                    realityDomainPort="${subscribePort}"
                fi
            fi
        fi
        if [[ -z "${realityServerName}" ]]; then
            realityDomainPort=443
            echoContent skyBlue "\n================ 配置 Reality 伪装目标网站 ===============\n"
            echoContent yellow "📌 Reality 工作原理："
            echoContent white "   客户端访问 → 假装访问目标网站 → 实际连接你的代理服务器"
            echoContent white "   如果被检测，流量看起来像在访问正常的 HTTPS 网站\n"

            echoContent yellow "💡 推荐的伪装目标（可直接使用）："
            echoContent green "   • addons.mozilla.org        (Mozilla 插件商店)"
            echoContent green "   • gateway.icloud.com        (Apple iCloud)"
            echoContent green "   • download-installer.cdn.mozilla.net"
            echoContent green "   • www.cisco.com             (思科官网)"
            echoContent green "   • www.samsung.com           (三星官网)\n"

            echoContent yellow "⚠️  选择要求："
            echoContent white "   1. 必须支持 TLSv1.3"
            echoContent white "   2. 证书链长度适中（<3500字节）"
            echoContent white "   3. 最好是知名网站（不易被墙）"
            echoContent white "   4. 默认端口 443，可自定义其他端口\n"

            echoContent yellow "📝 输入格式："
            echoContent white "   • 仅域名:     addons.mozilla.org       (使用 443 端口)"
            echoContent white "   • 域名+端口:  www.cisco.com:443        (自定义端口)"
            echoContent white "   • 回车:       随机选择推荐域名\n"

            read -r -p "请输入目标网站域名[回车随机选择]:" realityServerName
            if [[ -z "${realityServerName}" ]]; then
                randomNum=$(randomNum 1 27)
                realityServerName=$(echo "${realityDestDomainList}" | awk -F ',' -v randomNum="$randomNum" '{print $randomNum}')
            fi
            if echo "${realityServerName}" | grep -q ":"; then
                realityDomainPort=$(echo "${realityServerName}" | awk -F "[:]" '{print $2}')
                realityServerName=$(echo "${realityServerName}" | awk -F "[:]" '{print $1}')
            fi
        fi
    fi

    echoContent yellow "\n ---> 客户端可用域名: ${realityServerName}:${realityDomainPort}\n"
}
# Initialize the Reality port
initXrayRealityPort() {
    # Always ask whether to reuse the previous port, regardless of lastInstallationConfig
    if [[ -n "${xrayVLESSRealityPort}" ]]; then
        read -r -p "读取到上次安装记录，是否使用上次安装时的端口 ？[y/n]:" historyRealityPortStatus
        if [[ "${historyRealityPortStatus}" == "y" ]]; then
            realityPort=${xrayVLESSRealityPort}
        fi
    fi

    if [[ -z "${realityPort}" ]]; then
        echoContent skyBlue "\n================ 配置 Reality 监听端口 ===============\n"
        echoContent yellow "📌 这是你的服务器对外开放的端口"
        echoContent white "   • 客户端连接时使用此端口"
        echoContent white "   • 建议使用非标准端口（避免端口扫描）"
        echoContent white "   • 端口范围：1-65535\n"

        echoContent yellow "💡 推荐配置："
        echoContent green "   • 常用端口：443、8443、2053"
        echoContent green "   • 随机端口（回车自动生成 10000-30000)"
        echoContent green "   • 自定义端口：如 12345\n"

        read -r -p "请输入端口[回车随机10000-30000]:" realityPort
        if [[ -z "${realityPort}" ]]; then
            realityPort=$((RANDOM % 20001 + 10000))
        fi
        if [[ -n "${realityPort}" && "${xrayVLESSRealityPort}" != "${realityPort}" ]]; then
            checkPort "${realityPort}"
        fi
    fi
    if [[ -z "${realityPort}" ]]; then
        initXrayRealityPort
    else
        allowPort "${realityPort}"
        echoContent yellow "\n ---> 端口: ${realityPort}"
    fi

}
# Port for VLESS + XHTTP + REALITY. Sets xhttpRealityPort; it must differ
# from the Vision + REALITY port because both are separate inbounds.
initXrayXhttpRealityPort() {
    xhttpRealityPort=
    if [[ -n "${xrayXhttpRealityPort}" ]]; then
        local historyStatus
        read -r -p "读取到上次 XHTTP+Reality 端口 ${xrayXhttpRealityPort}，是否继续使用？[y/n]:" historyStatus
        [[ "${historyStatus}" == "y" ]] && xhttpRealityPort=${xrayXhttpRealityPort}
    fi
    while [[ -z "${xhttpRealityPort}" ]]; do
        echoContent skyBlue "\n============= 配置 XHTTP+Reality 监听端口 =============\n"
        read -r -p "请输入端口[回车随机10000-30000]:" xhttpRealityPort
        xhttpRealityPort=${xhttpRealityPort:-$((RANDOM % 20001 + 10000))}
        if ! isValidPort "${xhttpRealityPort}"; then
            echoContent red " ---> 端口无效"
            xhttpRealityPort=
        elif [[ -n "${realityPort}" && "${xhttpRealityPort}" == "${realityPort}" ]]; then
            echoContent red " ---> 不能与 Vision+Reality 使用同一端口"
            xhttpRealityPort=
        elif [[ "${xhttpRealityPort}" != "${xrayXhttpRealityPort}" ]]; then
            checkPort "${xhttpRealityPort}"
        fi
    done
    allowPort "${xhttpRealityPort}"
    echoContent yellow "\n ---> XHTTP+Reality 端口: ${xhttpRealityPort}"
}

# Reality management
manageReality() {
    readInstallProtocolType
    readConfigHostPathUUID
    readCustomPort

    if [[ -z "${coreInstallType}" ]] \
        || { ! hasProtocol "${currentInstallProtocolType}" 3 && ! hasProtocol "${currentInstallProtocolType}" 12; }; then
        echoContent red "\n ---> 请先安装Reality协议"
        return 1
    fi

    selectCustomInstallType=","
    hasProtocol "${currentInstallProtocolType}" 3 && selectCustomInstallType+="3,"
    hasProtocol "${currentInstallProtocolType}" 12 && selectCustomInstallType+="12,"
    initXrayConfig custom 1 true || return 1
    syncRelayRouting || return 1

    restartXray || return 1
    subscribe false
}
# Hysteria management

# quicParams.bbrProfile exists since Xray v26.4.13 (XTLS/Xray-core#5869).
# Stable v26.3.27 silently ignores it, so the profile would have no effect.
hysteria2BbrProfileMinVersion=v26.4.13

bbrProfileSupported() {
    xrayVersionAtLeast "$(installedXrayVersion)" "${hysteria2BbrProfileMinVersion}"
}

writeHysteria2BbrProfile() {
    local profile=$1 file="${configPath}05_hysteria2_inbounds.json" updated
    updated=$(jq --arg profile "${profile}" '
        .inbounds[0].streamSettings.finalmask.quicParams.congestion = "bbr" |
        .inbounds[0].streamSettings.finalmask.quicParams.bbrProfile = $profile
    ' "${file}") || return 1
    echo "${updated}" >"${file}"
}

setHysteria2BbrProfile() {
    local profile=$1
    [[ "${profile}" =~ ^(conservative|standard|aggressive)$ ]] || return 1
    if [[ ! -f "${configPath}05_hysteria2_inbounds.json" ]]; then
        echoContent red " ---> 未安装Hysteria2"
        return 1
    fi
    if ! bbrProfileSupported; then
        echoContent red " ---> 当前 Xray $(installedXrayVersion) 不支持 bbrProfile，设置不会生效"
        echoContent yellow " ---> 需要 ${hysteria2BbrProfileMinVersion} 或更新版本，可在「Xray版本管理」中升级到预览版"
        return 1
    fi
    applyXrayConfigChange "切换Hysteria2拥塞控制" writeHysteria2BbrProfile "${profile}" || return 1
    restartXray || return 1
    hysteria2BbrProfile=${profile}
    echoContent green " ---> Hysteria2 QUIC拥塞控制已切换为: BBR/${profile}"
}

# Short description of the current HTTP/3 masquerade.
describeHysteria2Masquerade() {
    jq -r '.inbounds[0].streamSettings.hysteriaSettings.masquerade |
        if . == null then "未启用"
        elif .type == "file" then "本地静态网站 " + .dir
        elif .type == "proxy" then "反向代理 " + .url
        elif .type == "string" then "跳转 " + (.headers.Location // "")
        else .type end' "${configPath}05_hysteria2_inbounds.json"
}

writeHysteria2Masquerade() {
    local file="${configPath}05_hysteria2_inbounds.json" updated
    updated=$(jq --argjson masquerade "${hysteria2MasqueradeConfig}" '
        if $masquerade == null then del(.inbounds[0].streamSettings.hysteriaSettings.masquerade)
        else .inbounds[0].streamSettings.hysteriaSettings.masquerade = $masquerade end
    ' "${file}") || return 1
    echo "${updated}" >"${file}"
}

setHysteria2Masquerade() {
    local currentDir
    # Keep the directory a local-site masquerade already uses (e.g. a panel site).
    currentDir=$(jq -r '.inbounds[0].streamSettings.hysteriaSettings.masquerade | select(.type == "file") | .dir // empty' \
        "${configPath}05_hysteria2_inbounds.json")
    # Always show the menu here; the install-time panel shortcut (btDomain)
    # would otherwise pick the panel site without asking.
    local btDomain=
    nginxStaticPath=${currentDir:-${nginxStaticPath}}
    initHysteria2Masquerade || return 1
    applyXrayConfigChange "修改Hysteria2伪装" writeHysteria2Masquerade || return 1
    restartXray || return 1
    echoContent green " ---> HTTP/3伪装: $(describeHysteria2Masquerade)"
}

manageHysteria2() {
    local hysteriaConfig="${configPath}05_hysteria2_inbounds.json"
    if [[ ! -f "${hysteriaConfig}" ]]; then
        echoContent red " ---> 当前未安装Hysteria2，请先通过任意组合安装"
        return
    fi

    while true; do
        local currentCongestion=
        local currentProfile=
        local manageChoice=
        currentCongestion=$(jq -r '.inbounds[0].streamSettings.finalmask.quicParams.congestion // "默认"' "${hysteriaConfig}")
        currentProfile=$(jq -r '.inbounds[0].streamSettings.finalmask.quicParams.bbrProfile // "standard"' "${hysteriaConfig}")

        echoContent skyBlue "\n===================== Hysteria2管理 ====================="
        echoContent yellow "当前QUIC拥塞控制: ${currentCongestion}/${currentProfile}"
        if ! bbrProfileSupported; then
            echoContent red "注意: 当前 Xray $(installedXrayVersion) 不支持 bbrProfile（${hysteria2BbrProfileMinVersion} 起支持），以下档位不会生效"
        fi
        echoContent green "# 此处调整本机Hysteria2入站；链式上游在中转管理中单独设置"
        echoContent yellow "1.切换为 conservative [低抖动/保守]"
        echoContent yellow "2.切换为 standard [均衡/推荐]"
        echoContent yellow "3.切换为 aggressive [吞吐优先]"
        echoContent yellow "4.端口跳跃[当前: $(currentPortHopRange || echo 未启用)]"
        echoContent yellow "5.HTTP/3伪装[当前: $(describeHysteria2Masquerade)]"
        echoContent yellow "0.返回主菜单"
        echoContent red "========================================================="
        read -r -p "请选择:" manageChoice

        case ${manageChoice} in
            1) setHysteria2BbrProfile conservative ;;
            2) setHysteria2BbrProfile standard ;;
            3) setHysteria2BbrProfile aggressive ;;
            4) managePortHopping ;;
            5) setHysteria2Masquerade ;;
            0) return ;;
            *) echoContent red " ---> 请输入 0-5" ;;
        esac
    done
}

# ==================== Hysteria2 port hopping ====================
#
# Xray's Hysteria2 inbound listens on one port. Port hopping redirects a UDP
# port range to it with nftables, so clients can hop between ports when an
# ISP throttles a single UDP port. (It does not help when UDP as a whole is
# restricted.) The range is stored in hysteria2PortHopFile; on systemd hosts
# a oneshot unit re-applies the rules at boot.

hysteria2PortHopFile=/opt/xray-agent/hysteria2_port_hopping
hysteria2PortHopNftFile=/opt/xray-agent/hysteria2-port-hopping.nft
hysteria2PortHopUnit=/etc/systemd/system/xray-agent-port-hopping.service
hysteria2PortHopTable=xray_agent_port_hopping
hysteria2PortHopDefaultRange=20000-50000
# Client hop interval in seconds (Hysteria's default; minimum 5).
hysteria2PortHopInterval=30

# Usage: isValidPortRange <start-end>
isValidPortRange() {
    [[ "$1" =~ ^([0-9]+)-([0-9]+)$ ]] || return 1
    local start=${BASH_REMATCH[1]} end=${BASH_REMATCH[2]}
    isValidPort "${start}" && isValidPort "${end}" && ((start < end))
}

# Print UDP ports used by other inbounds (extra-port forwarders for
# Hysteria2) that fall inside the range: the redirect would swallow them.
portHopConflicts() {
    local start=${1%-*} end=${1#*-} file port
    for file in "${configPath}"02_dokodemodoor_inbounds_hysteria_*.json; do
        [[ -f "${file}" ]] || continue
        port=$(jq -r '.inbounds[0].port' "${file}")
        if isValidPort "${port}" && ((port >= start && port <= end)); then
            echo "${port}"
        fi
    done
}

currentPortHopRange() {
    local range
    range=$(cat "${hysteria2PortHopFile}" 2>/dev/null)
    isValidPortRange "${range}" && echo "${range}"
}

writePortHopRules() {
    local range=$1
    cat >"${hysteria2PortHopNftFile}" <<NFT
# Managed by xray-agent: Hysteria2 port hopping.
table inet ${hysteria2PortHopTable} {
    chain prerouting {
        type nat hook prerouting priority dstnat; policy accept;
        udp dport ${range} counter redirect to :${hysteria2Port}
    }
}
NFT
}

# (Re)load the rules now, and make them survive reboots where systemd exists.
loadPortHopRules() {
    local nftBin
    nftBin=$(command -v nft) || return 1
    "${nftBin}" delete table inet "${hysteria2PortHopTable}" >/dev/null 2>&1
    if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
        cat >"${hysteria2PortHopUnit}" <<UNIT
[Unit]
Description=xray-agent Hysteria2 port hopping (UDP redirect)
After=network-pre.target nftables.service
Wants=network-pre.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=-${nftBin} delete table inet ${hysteria2PortHopTable}
ExecStart=${nftBin} -f ${hysteria2PortHopNftFile}
ExecStop=${nftBin} delete table inet ${hysteria2PortHopTable}

[Install]
WantedBy=multi-user.target
UNIT
        systemctl daemon-reload && systemctl enable xray-agent-port-hopping.service >/dev/null 2>&1 \
            && systemctl restart xray-agent-port-hopping.service
    else
        "${nftBin}" -f "${hysteria2PortHopNftFile}"
    fi
    "${nftBin}" list table inet "${hysteria2PortHopTable}" >/dev/null 2>&1
}

# Usage: enablePortHopping <start-end>
enablePortHopping() {
    local range=$1 conflicts
    if ! isValidPortRange "${range}"; then
        echoContent red " ---> 端口范围无效，格式为 起始-结束，例如 ${hysteria2PortHopDefaultRange}"
        return 1
    fi
    if [[ ! -f "${configPath}05_hysteria2_inbounds.json" ]]; then
        echoContent red " ---> 未安装Hysteria2"
        return 1
    fi
    hysteria2Port=${hysteria2Port:-$(jq -r '.inbounds[0].port' "${configPath}05_hysteria2_inbounds.json")}
    conflicts=$(portHopConflicts "${range}" | tr '\n' ' ')
    if [[ -n "${conflicts}" ]]; then
        echoContent red " ---> 端口范围包含额外端口的 UDP 转发: ${conflicts}，请换一个范围"
        return 1
    fi
    if ! command -v nft >/dev/null 2>&1; then
        echoContent yellow " ---> 安装 nftables"
        ${installType:-apt -y install} nftables >/dev/null 2>&1
    fi

    local previousRules=
    [[ -f "${hysteria2PortHopNftFile}" ]] && previousRules=$(cat "${hysteria2PortHopNftFile}")
    writePortHopRules "${range}"
    if ! loadPortHopRules; then
        echoContent red " ---> 端口跳跃规则加载失败，已撤销"
        if [[ -n "${previousRules}" ]]; then
            echo "${previousRules}" >"${hysteria2PortHopNftFile}"
            loadPortHopRules
        else
            disablePortHopping >/dev/null
        fi
        return 1
    fi
    echo "${range}" >"${hysteria2PortHopFile}"
    allowPort "${range/-/:}" udp
    echoContent green " ---> 端口跳跃已启用: UDP ${range} -> ${hysteria2Port}"
    echoContent yellow " ---> 云服务器的安全组也需要放行 UDP ${range}"
}

disablePortHopping() {
    if command -v systemctl >/dev/null 2>&1 && [[ -f "${hysteria2PortHopUnit}" ]]; then
        systemctl disable --now xray-agent-port-hopping.service >/dev/null 2>&1
        rm -f "${hysteria2PortHopUnit}"
        systemctl daemon-reload
    fi
    command -v nft >/dev/null 2>&1 && nft delete table inet "${hysteria2PortHopTable}" >/dev/null 2>&1
    rm -f "${hysteria2PortHopNftFile}" "${hysteria2PortHopFile}"
    echoContent green " ---> 端口跳跃已关闭"
}

# Asked while configuring Hysteria2 during installation. Sets
# hysteria2PortHopRange (empty = disabled); the rules are applied after the
# config is written, see syncPortHopping.
initHysteria2PortHopping() {
    local current answer range
    current=$(currentPortHopRange)
    hysteria2PortHopRange=
    if [[ -n "${current}" ]]; then
        read -r -p "检测到端口跳跃 UDP ${current}，是否继续使用？[Y/n]:" answer
        [[ "${answer}" =~ ^[Nn]$ ]] || hysteria2PortHopRange=${current}
        return 0
    fi
    echoContent yellow "端口跳跃: 运营商对单个UDP端口限速/阻断时有用，需要云安全组放行整个UDP范围"
    read -r -p "是否启用 Hysteria2 端口跳跃？[y/N]:" answer
    [[ "${answer}" =~ ^[Yy]$ ]] || return 0
    while true; do
        read -r -p "请输入UDP端口范围[回车默认 ${hysteria2PortHopDefaultRange}]:" range
        range=${range:-${hysteria2PortHopDefaultRange}}
        isValidPortRange "${range}" && break
        echoContent red " ---> 格式为 起始-结束，例如 ${hysteria2PortHopDefaultRange}"
    done
    hysteria2PortHopRange=${range}
}

# Apply the choice made during installation.
syncPortHopping() {
    if [[ -n "${hysteria2PortHopRange}" ]]; then
        enablePortHopping "${hysteria2PortHopRange}"
    elif [[ -n "$(currentPortHopRange)" ]]; then
        disablePortHopping
    fi
}

managePortHopping() {
    local current answer range
    current=$(currentPortHopRange)
    echoContent skyBlue "\n--------------------- 端口跳跃 ---------------------"
    if [[ -n "${current}" ]]; then
        echoContent yellow "当前状态: 已启用 UDP ${current} -> ${hysteria2Port}"
    else
        echoContent yellow "当前状态: 未启用"
    fi
    echoContent yellow "1.启用/修改端口范围"
    echoContent yellow "2.关闭端口跳跃"
    echoContent yellow "0.返回"
    read -r -p "请选择:" answer
    case ${answer} in
        1)
            read -r -p "请输入UDP端口范围[回车默认 ${current:-${hysteria2PortHopDefaultRange}}]:" range
            enablePortHopping "${range:-${current:-${hysteria2PortHopDefaultRange}}}" || return 1
            echoContent yellow " ---> 请重新获取订阅/分享链接，客户端才会开始跳跃"
            ;;
        2)
            disablePortHopping
            echoContent yellow " ---> 请重新获取订阅/分享链接"
            ;;
    esac
}
# Main menu
menu() {
    cd "$HOME" || exit
    echoContent red "\n=============================================================="
    echoContent green "当前版本：v2026.10.09.1791524866"
    echoContent green "描述：Xray 一键安装管理脚本\c"
    showInstallStatus
    echoContent skyBlue "快捷命令：xraya"
    echoContent skyBlue "-------------------------安装---------------------------------"
    if [[ -n "${coreInstallType}" ]]; then
        echoContent yellow "1.重新安装推荐组合"
    else
        echoContent yellow "1.安装推荐组合[Vision + XHTTP + Reality + Hysteria2]"
    fi
    echoContent yellow "2.自选协议安装"
    echoContent skyBlue "-------------------------管理---------------------------------"
    echoContent yellow "3.账号管理"
    echoContent yellow "4.订阅管理"
    echoContent yellow "5.中转管理（链式代理）"
    echoContent yellow "6.协议设置[Reality / Hysteria2 / 额外端口]"
    echoContent yellow "7.分流工具"
    echoContent yellow "8.伪装站与证书"
    echoContent skyBlue "-------------------------维护---------------------------------"
    echoContent yellow "9.Xray版本管理"
    echoContent yellow "10.更新脚本"
    echoContent yellow "11.卸载脚本"
    echoContent yellow "0.退出"
    echoContent red "=============================================================="
    mkdirTools
    aliasInstall
    read -r -p "请选择:" selectInstallType
    case ${selectInstallType} in
        1) installRecommended ;;
        2) customXrayInstall ;;
        3) manageAccount 1 ;;
        4) manageSubscriptions ;;
        5) manageRelay 1 ;;
        6) protocolSettingsMenu ;;
        7) routingToolsMenu 1 ;;
        8) siteAndCertificateMenu ;;
        9) coreVersionManageMenu 1 ;;
        10) updateXrayAgent 1 ;;
        11) unInstall 1 ;;
        0) exit 0 ;;
        *) echoContent red " ---> 请输入 0-11" ;;
    esac
}

protocolSettingsMenu() {
    echoContent skyBlue "\n-------------------------协议设置-----------------------------"
    echoContent yellow "1.Reality管理[更换目标网站/密钥]"
    echoContent yellow "2.Hysteria2管理[拥塞控制]"
    echoContent yellow "3.额外端口[多端口转发到主端口]"
    echoContent yellow "0.返回"
    local selection
    read -r -p "请选择:" selection
    case ${selection} in
        1) manageReality 1 ;;
        2) manageHysteria2 ;;
        3) addCorePort 1 ;;
        0) menu ;;
        *) echoContent red " ---> 请输入 0-3" ;;
    esac
}

siteAndCertificateMenu() {
    echoContent skyBlue "\n-------------------------伪装站与证书-------------------------"
    echoContent yellow "1.更换伪装站"
    echoContent yellow "2.检查/续签证书"
    echoContent yellow "0.返回"
    local selection
    read -r -p "请选择:" selection
    case ${selection} in
        1) updateNginxBlog 1 ;;
        2) renewalTLS 1 ;;
        0) menu ;;
        *) echoContent red " ---> 请输入 0-2" ;;
    esac
}

# ===== Entry Point =====
# Runs after every module is loaded, so initialization can use any function.
initVar "$1"
checkSystem
checkCPUVendor
detectPanelNginxPath
readInstallType
readInstallProtocolType
readConfigHostPathUUID
readCustomPort
checkNginxEnvironment
cronFunction
menu
