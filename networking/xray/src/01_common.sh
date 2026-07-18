#!/usr/bin/env bash

# 检测区
# -------------------------------------------------------------
# 检查系统
export LANG=en_US.UTF-8

echoContent() {
    case $1 in
    # 红色
    "red")
        # shellcheck disable=SC2154
        ${echoType} "\033[31m${printN}$2 \033[0m"
        ;;
        # 天蓝色
    "skyBlue")
        ${echoType} "\033[1;36m${printN}$2 \033[0m"
        ;;
        # 绿色
    "green")
        ${echoType} "\033[32m${printN}$2 \033[0m"
        ;;
        # 白色
    "white")
        ${echoType} "\033[37m${printN}$2 \033[0m"
        ;;
    "magenta")
        ${echoType} "\033[31m${printN}$2 \033[0m"
        ;;
        # 黄色
    "yellow")
        ${echoType} "\033[33m${printN}$2 \033[0m"
        ;;
    esac
}
checkSystem() {
    if { [[ -f "/etc/issue" ]] && grep -qi "debian" /etc/issue; } || { [[ -f "/proc/version" ]] && grep -qi "debian" /proc/version; } || { [[ -f "/etc/os-release" ]] && grep -qi "ID=debian" /etc/issue; }; then
        release="debian"
        installType='apt -y install'
        upgrade="apt update"
        updateReleaseInfoChange='apt-get --allow-releaseinfo-change update'
        removeType='apt -y autoremove'

    elif { [[ -f "/etc/issue" ]] && grep -qi "ubuntu" /etc/issue; } || { [[ -f "/proc/version" ]] && grep -qi "ubuntu" /proc/version; }; then
        release="ubuntu"
        installType='apt -y install'
        upgrade="apt update"
        updateReleaseInfoChange='apt-get --allow-releaseinfo-change update'
        removeType='apt -y autoremove'
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

# 检查CPU提供商
checkCPUVendor() {
    if [[ -n $(which uname) ]]; then
        if [[ "$(uname)" == "Linux" ]]; then
            case "$(uname -m)" in
            'amd64' | 'x86_64')
                xrayCoreCPUVendor="Xray-linux-64"
                warpRegCoreCPUVendor="main-linux-amd64"
                ;;
            'armv8' | 'aarch64')
                cpuVendor="arm"
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

# 初始化全局变量
initVar() {
    installType='apt -y install'
    removeType='apt -y autoremove'
    upgrade="apt update"
    updateReleaseInfoChange='apt-get --allow-releaseinfo-change update'
    echoType='echo -e'

    # 核心支持的cpu版本
    xrayCoreCPUVendor=""
    warpRegCoreCPUVendor=""
    cpuVendor=""

    # 域名
    domain=
    # 安装总进度
    totalProgress=1

    # Xray-core 安装状态
    coreInstallType=

    # 核心安装path
    # coreInstallPath=

    # v2ctl Path
    ctlPath=
    # 当前安装的协议编号：0 Vision、1 WebSocket、3 Reality、6 Hysteria2
    currentInstallProtocolType=


    # 前置类型
    frontingType=

    # 选择的个性化安装方式
    selectCustomInstallType=

    # Xray-core 配置文件路径
    configPath=

    # xray-core reality状态
    realityStatus=

    # nginx订阅端口
    subscribePort=

    subscribeType=

    # xray-core reality serverName publicKey
    xrayVLESSRealityServerName=
    xrayVLESSRealityPort=
    #    xrayVLESSRealityPublicKey=

    # 配置文件的path
    currentPath=

    # 配置文件的host
    currentHost=

    # 随机路径
    customPath=

    # UUID
    currentUUID=

    # clients
    currentClients=

    # previousClients
    #    previousClients=

    localIP=

    # 定时任务执行任务名称 RenewTLS-更新证书 UpdateGeo-更新geo文件 UpdateRelay-更新中转订阅
    cronName=$1

    # tls安装失败后尝试的次数
    installTLSCount=

    # BTPanel状态
    #	BTPanelStatus=
    # 宝塔域名
    btDomain=
    # nginx配置文件路径
    nginxConfigPath=/etc/nginx/conf.d/
    nginxStaticPath=/usr/share/nginx/html/

    # 是否为预览版
    prereleaseStatus=false

    # ssl类型
    sslType=
    # ssl邮箱
    sslEmail=

    # 检查天数
    sslRenewalDays=90

    # dns ssl状态
    #    dnsSSLStatus=

    # dns tls domain
    dnsTLSDomain=
    ipType=

    # 该域名是否通过dns安装通配符证书
    #    installDNSACMEStatus=

    # 自定义端口
    customPort=

    # hysteria端口

    # Xray-core Hysteria2 UDP端口
    hysteria2Port=
    hysteria2BbrProfile=
    hysteria2MasqueradeConfig=
    selectedHysteria2BbrProfile=

    # Reality
    realityPrivateKey=
    realityServerName=
    realityDestDomain=

    # 端口状态
    #    isPortOpen=
    # 通配符域名状态
    #    wildcardDomainStatus=
    # 通过nginx检查的端口
    #    nginxIPort=

    # wget show progress
    wgetShowProgressStatus=

    # warp
    reservedWarpReg=
    publicKeyWarpReg=
    addressWarpReg=
    secretKeyWarpReg=

    # 上次安装配置状态
    lastInstallationConfig=

    # Native ACME 相关
    nativeACMEEnabled=
    nativeCertPath=
    nativeKeyPath=

    # 由 acme.sh/acme_manage.sh 管理的现有证书
    acmeManagedCertSelected=
    acmeManagedHome=
    acmeManagedSourceDomain=
    acmeManagedServiceDomain=
    acmeManagedEcc=

    # 自动发现的泛域名 acme.sh 证书路径
    dnsTLSAcmeCertPath=
    dnsTLSAcmeKeyPath=

}
