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
