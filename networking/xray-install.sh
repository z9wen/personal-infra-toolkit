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
# 读取tls证书详情
readAcmeTLS() {
    local readAcmeDomain=
    installedDNSAPIStatus=
    dnsTLSAcmeCertPath=
    dnsTLSAcmeKeyPath=
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
            # 目录命名在不同 acme.sh 版本中可能不同，以证书 SAN 为准。
            if openssl x509 -in "${candidateCert}" -noout -text 2>/dev/null | grep -Fq "DNS:*.${dnsTLSDomain}"; then
                candidateKey="${candidateCert%.cer}.key"
                if [[ ! -f "${candidateKey}" ]]; then
                    candidateKey=$(find "${candidateDir}" -maxdepth 1 -type f -name '*.key' -print -quit 2>/dev/null)
                fi
                if [[ -f "${candidateKey}" ]]; then
                    installedDNSAPIStatus=true
                    dnsTLSAcmeCertPath="${candidateCert}"
                    dnsTLSAcmeKeyPath="${candidateKey}"
                    return 0
                fi
            fi
        done < <(find "${candidateDir}" -maxdepth 1 -type f -name '*.cer' 2>/dev/null)
    done < <(find "$HOME/.acme.sh" -maxdepth 1 -type d -name "*.${dnsTLSDomain}_ecc" 2>/dev/null)
}

# 读取默认自定义端口
readCustomPort() {
    if [[ -n "${configPath}" && -z "${realityStatus}" && "${coreInstallType}" == "1" ]]; then
        local port=
        port=$(jq -r .inbounds[0].port "${configPath}${frontingType}.json")
        if [[ "${port}" != "443" ]]; then
            customPort=${port}
        fi
    fi
}

# 读取nginx订阅端口
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

# 检测安装方式
readInstallType() {
    coreInstallType=
    configPath=

    # 1.检测安装目录
    if [[ -d "/opt/xray-agent" ]]; then
        if [[ -f "/opt/xray-agent/xray/xray" ]]; then
            # 检测xray-core
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

# 读取协议类型
readInstallProtocolType() {
    currentInstallProtocolType=
    frontingType=

    xrayVLESSRealityPort=
    xrayVLESSRealityServerName=


    hysteria2Port=


    currentRealityPrivateKey=
    currentRealityPublicKey=

    currentRealityMldsa65Seed=
    currentRealityMldsa65Verify=

    frontingTypeReality=

    while read -r row; do
        if echo "${row}" | grep -q VLESS_TCP_inbounds; then
            currentInstallProtocolType="${currentInstallProtocolType}0,"
            frontingType=02_VLESS_TCP_inbounds
        fi
        if echo "${row}" | grep -q VLESS_WS_inbounds; then
            currentInstallProtocolType="${currentInstallProtocolType}1,"
            frontingType=03_VLESS_WS_inbounds
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

            frontingTypeReality=07_VLESS_vision_reality_inbounds
        fi
    done < <(find ${configPath} -name "*inbounds.json" | sort | awk -F "[.]" '{print $1}')

    if [[ "${currentInstallProtocolType:0:1}" != "," ]]; then
        currentInstallProtocolType=",${currentInstallProtocolType}"
    fi
}

# 检查是否安装宝塔/aaPanel。面板进程名在不同版本中并不固定，
# 因此同时依据 Nginx、vhost 目录和面板进程判断。
isBTPanelEnvironment() {
    [[ -d "/www/server/panel/vhost/nginx" ]] || return 1
    [[ -x "/www/server/nginx/sbin/nginx" ]] || pgrep -f "BT-Panel|aaPanel" >/dev/null 2>&1
}

# 仅保留具有合法域名文件名并已配置可用 TLS 证书的面板站点。
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
        # 读取域名
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

            # 如果用户选择不使用上次配置或currentHost为空，则提示用户选择
            if [[ "${forceSelectDomain}" == "true" ]] || [[ -z "${currentHost}" ]]; then
                echoContent skyBlue "\n读取宝塔/aaPanel配置\n"

                local displayIndex
                for ((displayIndex = 0; displayIndex < btDomainCount; displayIndex++)); do
                    local printIndex=$((displayIndex + 1))
                    echo "${printIndex}:${btDomains[displayIndex]}"
                done

                read -r -p "请输入编号选择:" selectBTDomain
                # 选择完成后清除标志
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
        # 读取域名
        if [[ -d '/opt/1panel/apps/openresty/openresty/www/sites/' && -n $(find /opt/1panel/apps/openresty/openresty/www/sites/*/ssl/fullchain.pem) ]]; then
            # 如果用户选择不使用上次配置或currentHost为空，则提示用户选择
            if [[ "${forceSelectDomain}" == "true" ]] || [[ -z "${currentHost}" ]]; then
                echoContent skyBlue "\n读取1Panel配置\n"

                find /opt/1panel/apps/openresty/openresty/www/sites/*/ssl/fullchain.pem | awk -F "[/]" '{print $9}' | awk '{print NR""":"$0}'

                read -r -p "请输入编号选择:" selectBTDomain
                # 选择完成后清除标志
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
checkHestiaPanel() {
    if [[ -d "/usr/local/hestia" ]]; then
        local -a hestiaDomains=()
        local -a hestiaUsers=()
        while IFS= read -r certDir; do
            if [[ -z "${certDir}" ]]; then
                continue
            fi
            local hUser hDomain
            hUser=$(echo "${certDir}" | cut -d'/' -f3)
            hDomain=$(echo "${certDir}" | cut -d'/' -f6)
            if [[ -n "${hUser}" && -n "${hDomain}" ]]; then
                hestiaUsers+=("${hUser}")
                hestiaDomains+=("${hDomain}")
            fi
        done < <(find /home -path "*/conf/web/*/ssl" -type d 2>/dev/null | sort)

        local domainCount=${#hestiaDomains[@]}
        if ((domainCount == 0)); then
            return
        fi

        local selectHestiaDomain=
        # 如果用户选择不使用上次配置或currentHost为空，则提示用户选择
        if [[ "${forceSelectDomain}" == "true" ]] || [[ -z "${currentHost}" ]]; then
            echoContent skyBlue "\n读取HestiaCP配置\n"
            local displayIndex
            for ((displayIndex = 0; displayIndex < domainCount; displayIndex++)); do
                local printIndex=$((displayIndex + 1))
                echo "${printIndex}:${hestiaDomains[displayIndex]} (user:${hestiaUsers[displayIndex]})"
            done
            read -r -p "请输入编号选择:" selectHestiaDomain
            # 选择完成后清除标志
            forceSelectDomain=false
        else
            for ((displayIndex = 0; displayIndex < domainCount; displayIndex++)); do
                if [[ "${hestiaDomains[displayIndex]}" == "${currentHost}" ]]; then
                    selectHestiaDomain=$((displayIndex + 1))
                    break
                fi
            done
        fi

        if [[ -n "${selectHestiaDomain}" && "${selectHestiaDomain}" =~ ^[0-9]+$ ]]; then
            local selectedIndex=$((selectHestiaDomain - 1))
            if ((selectedIndex < 0 || selectedIndex >= domainCount)); then
                echoContent red " ---> 选择错误，请重新选择"
                checkHestiaPanel
                return
            fi

            local hestiaDomain=${hestiaDomains[selectedIndex]}
            local hestiaUser=${hestiaUsers[selectedIndex]}
            local certDir="/home/${hestiaUser}/conf/web/${hestiaDomain}/ssl"
            local certFile=
            local keyFile=

            if [[ -f "${certDir}/${hestiaDomain}.crt" ]]; then
                certFile="${certDir}/${hestiaDomain}.crt"
            elif [[ -f "${certDir}/fullchain.pem" ]]; then
                certFile="${certDir}/fullchain.pem"
            elif [[ -f "${certDir}/cert.pem" ]]; then
                certFile="${certDir}/cert.pem"
            fi

            if [[ -f "${certDir}/${hestiaDomain}.key" ]]; then
                keyFile="${certDir}/${hestiaDomain}.key"
            elif [[ -f "${certDir}/privkey.pem" ]]; then
                keyFile="${certDir}/privkey.pem"
            elif [[ -f "${certDir}/key.pem" ]]; then
                keyFile="${certDir}/key.pem"
            fi

            if [[ -z "${certFile}" || -z "${keyFile}" ]]; then
                echoContent red " ---> 未找到 HestiaCP 证书文件，请先在面板中申请"
                return
            fi

            btDomain=${hestiaDomain}
            domain=${hestiaDomain}

            mkdir -p /opt/xray-agent/tls
            if [[ ! -f "/opt/xray-agent/tls/${hestiaDomain}.crt" && ! -f "/opt/xray-agent/tls/${hestiaDomain}.key" ]]; then
                ln -s "${certFile}" "/opt/xray-agent/tls/${hestiaDomain}.crt"
                ln -s "${keyFile}" "/opt/xray-agent/tls/${hestiaDomain}.key"
            fi

            nginxStaticPath="/home/${hestiaUser}/web/${hestiaDomain}/public_html/"
            mkdir -p "${nginxStaticPath}"
        else
            echoContent red " ---> 选择错误，请重新选择"
            checkHestiaPanel
            return
        fi
    fi
}
# 检查防火墙
allowPort() {
    local type=$2
    if [[ -z "${type}" ]]; then
        type=tcp
    fi
    
    # 只有 UFW 确实启用时才由它处理；仅安装但未启用时继续检查其他防火墙。
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
        if ! ufw status | grep -q "$1/${type}"; then
            ufw allow "$1/${type}"
            checkUFWAllowPort "$1"
        fi
        return
    fi
    
    # 检查 firewalld
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
    
    # 最后检查 iptables (仅当没有其他防火墙时)
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
# 获取公网IP
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

# 输出ufw端口开放状态
checkUFWAllowPort() {
    if ufw status | grep -q "$1"; then
        echoContent green " ---> $1端口开放成功"
    else
        echoContent red " ---> $1端口开放失败"
        exit 0
    fi
}

# 输出firewall-cmd端口开放状态
checkFirewalldAllowPort() {
    if firewall-cmd --list-ports --permanent | grep -q "$1"; then
        echoContent green " ---> $1端口开放成功"
    else
        echoContent red " ---> $1端口开放失败"
        exit 0
    fi
}

# 读取上次安装的配置
readLastInstallationConfig() {
    if [[ -n "${configPath}" ]]; then
        read -r -p "读取到上次安装的配置，是否使用 ？[y/n]:" lastInstallationConfigStatus
        if [[ "${lastInstallationConfigStatus}" == "y" ]]; then
            lastInstallationConfig=true
        else
            # 用户选择不使用上次配置，设置标志强制重新选择
            forceSelectDomain=true
            lastInstallationConfig=
            currentHost=
            currentPath=
            currentDefaultPort=
            btDomain=
        fi
    fi
}
# 检查文件目录以及path路径
readConfigHostPathUUID() {
    currentPath=
    currentDefaultPort=
    currentUUID=
    currentClients=
    currentHost=
    currentPort=
    currentCDNAddress=

    if [[ "${coreInstallType}" == "1" ]]; then

        # 安装
        if [[ -n "${frontingType}" ]]; then
            # 优先从 VLESS TCP 配置中读取域名（因为它有 TLS 证书）
            if [[ -f "${configPath}02_VLESS_TCP_inbounds.json" ]]; then
                currentHost=$(jq -r .inbounds[0].streamSettings.tlsSettings.certificates[0].certificateFile ${configPath}02_VLESS_TCP_inbounds.json | awk -F '[t][l][s][/]' '{print $2}' | awk -F '[.][c][r][t]' '{print $1}')
            else
                currentHost=$(jq -r .inbounds[0].streamSettings.tlsSettings.certificates[0].certificateFile ${configPath}${frontingType}.json | awk -F '[t][l][s][/]' '{print $2}' | awk -F '[.][c][r][t]' '{print $1}')
            fi

            # 优先从 VLESS TCP 读取端口（对外端口）
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
                # 优先从 VLESS TCP 读取对外端口
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

    # 读取path
    if [[ -n "${configPath}" && -n "${frontingType}" ]]; then
        if [[ "${coreInstallType}" == "1" ]]; then
            local fallback
            # 优先从 VLESS TCP 配置中读取path（因为它有 fallbacks）
            if [[ -f "${configPath}02_VLESS_TCP_inbounds.json" ]]; then
                fallback=$(jq -r -c '.inbounds[0].settings.fallbacks[]?|select(.path)' ${configPath}02_VLESS_TCP_inbounds.json | head -1)
            else
                fallback=$(jq -r -c '.inbounds[0].settings.fallbacks[]?|select(.path)' ${configPath}${frontingType}.json | head -1)
            fi

            local path
            path=$(echo "${fallback}" | jq -r .path | awk -F "[/]" '{print $2}')

            if [[ $(echo "${fallback}" | jq -r .dest) == 31297 ]] || [[ $(echo "${fallback}" | jq -r .dest) == 31299 ]]; then
                # path已经是纯路径，不需要去除后缀
                currentPath="${path}"
            fi

        fi
    fi
    if [[ -f "/opt/xray-agent/cdn" ]] && [[ -n "$(head -1 /opt/xray-agent/cdn)" ]]; then
        currentCDNAddress=$(head -1 /opt/xray-agent/cdn)
    else
        currentCDNAddress="${currentHost}"
    fi
}

# 状态展示
showInstallStatus() {
    if [[ -n "${coreInstallType}" ]]; then
        if [[ -n $(pgrep -f "xray/xray") ]]; then
            echoContent yellow "\n核心: Xray-core[运行中]"
        else
            echoContent yellow "\n核心: Xray-core[未运行]"
        fi
        # 读取协议类型
        readInstallProtocolType

        if [[ -n ${currentInstallProtocolType} ]]; then
            echoContent yellow "已安装协议: \c"
        fi
        if echo ${currentInstallProtocolType} | grep -q ",0,"; then
            echoContent yellow "VLESS+TCP[TLS_Vision] \c"
        fi

        if echo ${currentInstallProtocolType} | grep -q ",1,"; then
            echoContent yellow "VLESS+WS[TLS] \c"
        fi

        if echo ${currentInstallProtocolType} | grep -q ",6,"; then
            echoContent yellow "Hysteria2 \c"
        fi
        if echo ${currentInstallProtocolType} | grep -q ",3,"; then
            echoContent yellow "VLESS+Reality+Vision \c"
        fi
    fi
}

# 清理旧残留
cleanUp() {
    if [[ "$1" == "xrayDel" ]]; then
        handleXray stop
        rm -rf /opt/xray-agent/xray/*
    fi
}

# 检测 native ACME 客户端
checkNativeACME() {
    local nativeACMEInstalled=false
    local nativeACMEType=""
    
    # 检测 certbot
    if command -v certbot &> /dev/null; then
        nativeACMEInstalled=true
        nativeACMEType="certbot"
        local certbotVersion=$(certbot --version 2>&1 | head -1)
        echoContent skyBlue "\n检测到 Native ACME 客户端: ${nativeACMEType}"
        echoContent green "  版本: ${certbotVersion}"
        
        # 检查是否有现有证书
        if [[ -d "/etc/letsencrypt/live" ]]; then
            local certCount=$(find /etc/letsencrypt/live -mindepth 1 -maxdepth 1 -type d | wc -l)
            if [[ ${certCount} -gt 0 ]]; then
                echoContent yellow "  已有证书数量: ${certCount}"
                echoContent skyBlue "\n可用证书域名:"
                find /etc/letsencrypt/live -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | nl
            fi
        fi
        return 0
    fi
    
    # 检测其他 ACME 客户端
    if command -v lego &> /dev/null; then
        nativeACMEInstalled=true
        nativeACMEType="lego"
        echoContent skyBlue "\n检测到 Native ACME 客户端: ${nativeACMEType}"
        return 0
    fi
    
    return 1
}

# 使用 native ACME 证书（初始化阶段的检查）
useNativeACMECert() {
    local useNative=false
    
    if checkNativeACME; then
        echoContent skyBlue "\n=============================================================="
        echoContent yellow "检测到系统已安装 Native ACME 客户端"
        echoContent yellow "在安装过程中将提供使用现有证书的选项"
        echoContent red "==============================================================\n"
        # 不再在这里进行证书配置，留到证书安装步骤
    fi
    
    echo "${useNative}"
}

# 检测 Nginx 环境并生成报告
# 检测 Docker 中的 Nginx 容器


# Nginx 环境检测
checkNginxEnvironment() {
    local nginxBin="nginx"
    # 优先检测面板自带的 nginx
    if [[ -f "/www/server/nginx/sbin/nginx" ]]; then
        nginxBin="/www/server/nginx/sbin/nginx"
    fi

    if command -v nginx &> /dev/null || [[ -f "/www/server/nginx/sbin/nginx" ]]; then
        echoContent skyBlue "\n========== Nginx 环境检测 ==========\n"
        
        # Nginx 版本
        local nginxVer=$(${nginxBin} -v 2>&1 | awk -F'/' '{print $2}')
        echoContent green "Nginx 版本: ${nginxVer}"
        
        # 配置文件数量 - 使用 nginxConfigPath
        local confCount=$(find "${nginxConfigPath}" /etc/nginx/sites-enabled -name "*.conf" 2>/dev/null | wc -l)
        echoContent yellow "现有配置文件: ${confCount} 个"
        
        # 监听的端口
        local ports=$(netstat -tlnp 2>/dev/null | grep nginx | awk '{print $4}' | awk -F':' '{print $NF}' | sort -u | tr '\n' ',' | sed 's/,$//')
        if [[ -n "${ports}" ]]; then
            echoContent yellow "监听端口: ${ports}"
        fi
        
        # 配置的域名 - 使用 nginxConfigPath
        local domains=$(grep -rh "server_name" "${nginxConfigPath}" /etc/nginx/sites-enabled 2>/dev/null | grep -v "server_name _" | awk '{for(i=2;i<=NF;i++)print $i}' | sed 's/;//g' | sort -u | head -5)
        if [[ -n "${domains}" ]]; then
            echoContent yellow "已配置域名:"
            echo "${domains}" | while read -r d; do
                echoContent skyBlue "  - ${d}"
            done
        fi
        
        echoContent skyBlue "\n====================================\n"
    fi
}

initVar "$1"
checkSystem
checkCPUVendor

# 面板path早期检测（无需用户输入，仅设置 nginxConfigPath）
detectPanelNginxPath() {
    # aaPanel/宝塔的面板进程可能未运行或进程名不同，Nginx 与 vhost 目录
    # 才是判断配置位置的可靠依据。
    if [[ -x "/www/server/nginx/sbin/nginx" ]] && [[ -d "/www/server/panel/vhost/nginx" ]]; then
        nginxConfigPath="/www/server/panel/vhost/nginx/"
    elif [[ -d "/opt/1panel/apps/openresty/openresty/conf/conf.d" ]]; then
        nginxConfigPath="/opt/1panel/apps/openresty/openresty/conf/conf.d/"
    fi
}
detectPanelNginxPath

readInstallType
readInstallProtocolType
readConfigHostPathUUID
readCustomPort
checkNginxEnvironment
# -------------------------------------------------------------

# 初始化安装目录
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

# 安装工具包
installTools() {
    echoContent skyBlue "\n进度  $1/${totalProgress} : 安装工具"
    # 修复ubuntu个别系统问题
    if [[ "${release}" == "ubuntu" ]]; then
        dpkg --configure -a
    fi

    local packageWaitCount=0
    while pgrep -x apt >/dev/null 2>&1 || pgrep -x apt-get >/dev/null 2>&1 || pgrep -x dpkg >/dev/null 2>&1 || pgrep -x unattended-upgrade >/dev/null 2>&1; do
        if (( packageWaitCount >= 30 )); then
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
        # 检查是否已安装 UFW
        if dpkg -l 2>/dev/null | grep -q "^[[:space:]]*ii[[:space:]]\+ufw" || command -v ufw &> /dev/null; then
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

    # 检测nginx版本，并提供是否安装/卸载的选项
    if [[ "${selectCustomInstallType}" == ",3," ]]; then
        echoContent green " ---> 检测到无需依赖Nginx的服务，跳过安装"
    else
        # 检测宝塔/aaPanel 面板自带的 nginx（不在系统PATH，但已安装）
        local panelNginxBin=""
        if [[ -f "/www/server/nginx/sbin/nginx" ]]; then
            panelNginxBin="/www/server/nginx/sbin/nginx"
        fi
        if ! command -v nginx &> /dev/null && [[ -z "${panelNginxBin}" ]]; then
            echoContent yellow " ---> 未检测到 Nginx，开始安装"
            installNginxTools
        else
            local nginxBinToUse="nginx"
            [[ -n "${panelNginxBin}" ]] && nginxBinToUse="${panelNginxBin}"
            local existingConfCount=$(find "${nginxConfigPath}" /etc/nginx/sites-enabled -name "*.conf" 2>/dev/null | wc -l)

            if [[ -n "${panelNginxBin}" ]]; then
                echoContent green " ---> 检测到面板（宝塔/aaPanel）管理的 Nginx，跳过重装"
            elif [[ ${existingConfCount} -gt 0 ]]; then
                    echoContent yellow "\n检测到 Nginx 已安装且有 ${existingConfCount} 个配置文件"
                    echoContent skyBlue "脚本将在共存模式下运行，不会影响现有业务"
                    echoContent green "提示：建议使用不同的域名避免冲突\n"
            fi
        fi
    fi

    # 检查是否使用 native ACME
    local useNativeACME=$(useNativeACMECert)
        
        if [[ "${nativeACMEEnabled}" != "true" ]]; then
            # 未使用 native ACME，安装 acme.sh
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
# 开机启动
bootStartup() {
    local serviceName=$1
    systemctl daemon-reload
    systemctl enable "${serviceName}"
}
# 安装Nginx
installNginxTools() {

    if [[ "${release}" == "debian" ]]; then
        sudo apt install gnupg2 ca-certificates lsb-release -y >/dev/null 2>&1
        # 使用 stable 版本而非 mainline
        echo "deb http://nginx.org/packages/debian $(lsb_release -cs) nginx" | sudo tee /etc/apt/sources.list.d/nginx.list >/dev/null 2>&1
        echo -e "Package: *\nPin: origin nginx.org\nPin: release o=nginx\nPin-Priority: 900\n" | sudo tee /etc/apt/preferences.d/99nginx >/dev/null 2>&1
        downloadFile "https://nginx.org/keys/nginx_signing.key" "/tmp/nginx_signing.key" || return 1
        # gpg --dry-run --quiet --import --import-options import-show /tmp/nginx_signing.key
        sudo mv /tmp/nginx_signing.key /etc/apt/trusted.gpg.d/nginx_signing.asc
        sudo apt update >/dev/null 2>&1

    elif [[ "${release}" == "ubuntu" ]]; then
        sudo apt install gnupg2 ca-certificates lsb-release -y >/dev/null 2>&1
        # 使用 stable 版本而非 mainline
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

# 安装warp
installWarp() {
    if [[ "${cpuVendor}" == "arm" ]]; then
        echoContent red " ---> 官方WARP客户端不支持ARM架构"
        exit 0
    fi

    ${installType} gnupg2 -y >/dev/null 2>&1
    if [[ "${release}" == "debian" ]]; then
        curl -s https://pkg.cloudflareclient.com/pubkey.gpg | sudo apt-key add - >/dev/null 2>&1
        echo "deb http://pkg.cloudflareclient.com/ $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/cloudflare-client.list >/dev/null 2>&1
        sudo apt update >/dev/null 2>&1

    elif [[ "${release}" == "ubuntu" ]]; then
        curl -s https://pkg.cloudflareclient.com/pubkey.gpg | sudo apt-key add - >/dev/null 2>&1
        echo "deb http://pkg.cloudflareclient.com/ focal main" | sudo tee /etc/apt/sources.list.d/cloudflare-client.list >/dev/null 2>&1
        sudo apt update >/dev/null 2>&1

    fi

    echoContent green " ---> 安装WARP"
    ${installType} cloudflare-warp >/dev/null 2>&1
    if [[ -z $(which warp-cli) ]]; then
        echoContent red " ---> 安装WARP失败"
        exit 0
    fi
    systemctl enable warp-svc
    warp-cli --accept-tos register
    warp-cli --accept-tos set-mode proxy
    warp-cli --accept-tos set-proxy-port 31303
    warp-cli --accept-tos connect
    warp-cli --accept-tos enable-always-on

    local warpStatus=
    warpStatus=$(curl -s --socks5 127.0.0.1:31303 https://www.cloudflare.com/cdn-cgi/trace | grep "warp" | cut -d "=" -f 2)

    if [[ "${warpStatus}" == "on" ]]; then
        echoContent green " ---> WARP启动成功"
    fi
}

# 通过dns检查域名的IP
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
# 检查端口实际开放状态
checkPortOpen() {
    handleXray stop >/dev/null 2>&1

    local port=$1
    local domain=$2
    local checkPortOpenResult=
    allowPort "${port}"

    if [[ -z "${btDomain}" ]]; then

        handleNginx stop
        # 初始化nginx配置
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
        # 检查域名+端口的开放
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
                    echoContent red " ---> 请检查是否有网页防火墙，比如Oracle等云服务商"
                    echoContent red " ---> 检查是否自己安装过nginx并且有配置冲突，可以尝试DD纯净系统后重新尝试"
                else
                    echoContent red " ---> 错误日志：${checkPortOpenResult}，请将此错误日志通过issues提交反馈"
                fi
            fi
            exit 0
        fi
        checkIP "${localIP}"
    fi
}

# 初始化Nginx申请证书配置
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
        # 检查域名是否已在 Nginx 中配置
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
        # 修改配置
        handleNginx stop
    fi
}

# 删除nginx默认的配置
removeNginxDefaultConf() {
    if [[ -f ${nginxConfigPath}default.conf ]]; then
        if [[ "$(grep -c "server_name" <${nginxConfigPath}default.conf)" == "1" ]] && [[ "$(grep -c "server_name  localhost;" <${nginxConfigPath}default.conf)" == "1" ]]; then
            echoContent green " ---> 删除Nginx默认配置"
            rm -rf ${nginxConfigPath}default.conf >/dev/null 2>&1
        fi
    fi
}
# 修改nginx重定向配置
updateRedirectNginxConf() {
    local nginxConfFile="${nginxConfigPath}xray-agent.conf"
    local nginxConfTmp="${nginxConfFile}.tmp.$$"

    if [[ ! -d "${nginxConfigPath}" ]]; then
        echoContent red " ---> Nginx配置目录不存在: ${nginxConfigPath}"
        return 1
    fi

    # 备份现有配置
    if [[ -f "${nginxConfFile}" ]]; then
        local backupFile="${nginxConfFile}.bak_$(date +%Y%m%d_%H%M%S)"
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

    if ! cat <<EOF >"${nginxConfTmp}"
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
	location / {
	${fallbackLocationConfig}
	}
}
EOF
    then
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
# 检查ip


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
# 自定义email
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

# 查找 acme_manage.sh 默认安装的 acme.sh，也兼容 ACME_HOME 和 PATH。
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

# 从 acme.sh 的证书配置目录中选择 RSA/ECC 证书。
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

    acmeManagedServiceDomain=${serviceDomain}
    acmeManagedCertSelected=true
    domain=${serviceDomain}
    echoContent green " ---> 已选择 ${acmeManagedSourceDomain} 证书，Xray域名: ${domain}"
    return 0
}

# 使用 acme.sh 官方部署接口复制证书，并让后续续期自动更新 Xray 文件。
deployLocalAcmeCertificate() {
    local certFile="/opt/xray-agent/tls/${domain}.crt"
    local keyFile="/opt/xray-agent/tls/${domain}.key"
    local -a installArgs=(
        "${acmeManagedHome}/acme.sh" --install-cert
        -d "${acmeManagedSourceDomain}"
        --fullchain-file "${certFile}"
        --key-file "${keyFile}"
        --reloadcmd "systemctl try-restart xray.service >/dev/null 2>&1 || true"
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

# 兼容原有调用：显示本机可被选择的 acme.sh 证书。
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

# 选择ssl安装类型
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
            echo "${googleEabKid}" > /opt/xray-agent/tls/google_eab_kid
            echo "${googleEabHmac}" > /opt/xray-agent/tls/google_eab_hmac
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

# 选择acme安装证书方式
selectAcmeInstallSSL() {
    #    local sslIPv6=
    #    local currentIPType=
    if [[ "${ipType}" == "6" ]]; then
        sslIPv6="--listen-v6"
    fi
    #    currentIPType=$(curl -s "-${ipType}" http://www.cloudflare.com/cdn-cgi/trace | grep "ip" | cut -d "=" -f 2)

    #    if [[ -z "${currentIPType}" ]]; then
    #                currentIPType=$(curl -s -6 http://www.cloudflare.com/cdn-cgi/trace | grep "ip" | cut -d "=" -f 2)
    #        if [[ -n "${currentIPType}" ]]; then
    #            sslIPv6="--listen-v6"
    #        fi
    #    fi

    acmeInstallSSL

    readAcmeTLS
}

# 安装SSL证书
acmeInstallSSL() {
    # Google GTS 需要先注册 EAB 账号
    if [[ "${sslType}" == "google" ]]; then
        local googleEabKid=""
        local googleEabHmac=""
        
        # 读取保存的 EAB 凭证
        if [[ -f /opt/xray-agent/tls/google_eab_kid ]]; then
            googleEabKid=$(cat /opt/xray-agent/tls/google_eab_kid)
            googleEabHmac=$(cat /opt/xray-agent/tls/google_eab_hmac)
        fi
        
        if [[ -n "${googleEabKid}" && -n "${googleEabHmac}" ]]; then
            echoContent skyBlue " ---> 检测到 Google EAB 凭证，正在注册账号..."
            
            # 注册 Google GTS 账号
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
    
    # Standalone 模式需要停止 Nginx 以释放 80 端口
    handleNginx stop
    
    sudo "$HOME/.acme.sh/acme.sh" --issue -d "${tlsDomain}" --standalone -k ec-256 --server "${sslType}" ${sslIPv6} 2>&1 | tee -a /opt/xray-agent/tls/acme.log >/dev/null
    
    # 证书申请完成后重启 Nginx
    handleNginx start
}
# 自定义端口
customPortFunction() {
    local historyCustomPortStatus=
    if [[ -n "${customPort}" || -n "${currentPort}" ]]; then
        echo
        # 总是询问是否使用上次端口，不管lastInstallationConfig的值
        read -r -p "读取到上次安装时的端口，是否使用上次安装时的端口？[y/n]:" historyCustomPortStatus
        if [[ "${historyCustomPortStatus}" == "y" ]]; then
            port=${currentPort}
            echoContent yellow "\n ---> 端口: ${port}"
        fi
    fi
    if [[ -z "${currentPort}" ]] || [[ "${historyCustomPortStatus}" == "n" ]]; then
        echo

        if [[ -n "${btDomain}" ]]; then
            echoContent yellow "请输入端口[不可与BT Panel/1Panel/HestiaCP端口相同，回车随机]"
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
            if [[ "${port}" == "${xrayVLESSRealityPort}" ]]; then
                handleXray stop
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

# 初始化 Xray-core Hysteria2 UDP 监听端口。
# TCP/443 与 UDP/443 可以同时监听，因此默认复用主 TLS 端口。
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
}

# 选择 Xray QUIC BBR 的行为档位，结果写入 selectedHysteria2BbrProfile。
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

initHysteria2BbrProfile() {
    selectHysteria2BbrProfile "${hysteria2BbrProfile:-standard}" "Hysteria2"
    hysteria2BbrProfile=${selectedHysteria2BbrProfile}
}

# 将裸域名补全为 HTTPS URL，同时拒绝非 HTTP(S) 协议和空白字符。
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

# 选择 Hysteria2 未认证 HTTP/3 请求的伪装方式。
initHysteria2Masquerade() {
    # 面板站点已提供完整网站和有效 TLS，直接作为 Hysteria2 伪装目标。
    # Hysteria2 使用 UDP 入站，目标网站使用 TCP/443，不会产生端口冲突。
    if [[ -n "${btDomain}" ]]; then
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
    echoContent yellow "1.本地静态网站"
    echoContent yellow "2.301跳转"
    echoContent yellow "3.反向代理现有网站"
    echoContent skyBlue "------------------------------------------"

    local masqueradeType=
    read -r -p "请选择[默认:1]:" masqueradeType
    masqueradeType=${masqueradeType:-1}

    case ${masqueradeType} in
    1)
        hysteria2MasqueradeConfig=$(jq -nc --arg dir "${nginxStaticPath}" '{type:"file",dir:$dir}')
        echoContent green " ---> 使用本地静态网站: ${nginxStaticPath}"
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

# 检测端口是否占用
checkPort() {
    if [[ -n "$1" ]] && lsof -i "tcp:$1" | grep -q LISTEN; then
        echoContent red "\n=============================================================="
        echoContent yellow "端口 $1 已被占用"
        echoContent skyBlue "\n占用进程信息："
        lsof -i "tcp:$1" | grep LISTEN
        
        # 检查是否是 Nginx 占用
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

# 安装TLS
installTLS() {
    echoContent skyBlue "\n进度  $1/${totalProgress} : 申请TLS证书\n"
    
    # 检查是否使用 Native ACME 证书
    if [[ "${nativeACMEEnabled}" == "true" ]]; then
        echoContent green " ---> 使用 Native ACME 证书"
        echoContent green " ---> 证书路径: ${nativeCertPath}"
        echoContent green " ---> 密钥路径: ${nativeKeyPath}"
        
        # 验证证书文件存在
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

    # 安装tls
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
        if (( ${#localAcmeDirs[@]} > 0 )); then
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

# 初始化随机字符串


initRandomPath() {
    local chars="abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
    local initCustomPath=
    for i in {1..6}; do
        echo "${i}" >/dev/null
        initCustomPath+="${chars:RANDOM%${#chars}:1}"
    done
    customPath=${initCustomPath}
}

# 自定义/随机路径
randomPathFunction() {
    if [[ -n $1 ]]; then
        echoContent skyBlue "\n进度  $1/${totalProgress} : 生成随机路径"
    else
        echoContent skyBlue "生成随机路径"
    fi

    # 总是询问是否使用上次path，不管lastInstallationConfig的值
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
# 随机数
randomNum() {
    shuf -i "$1"-"$2" -n 1
}

# 可靠下载：失败重试、写入临时文件，成功后再替换目标文件。
downloadFile() {
    local url=$1 destination=$2 temporaryFile
    temporaryFile="${destination}.download.$$"
    mkdir -p "$(dirname "${destination}")"
    rm -f "${temporaryFile}"

    if command -v curl >/dev/null 2>&1; then
        curl --fail --location --silent --show-error --retry 3 --retry-delay 2 --connect-timeout 15 --output "${temporaryFile}" "${url}" || {
            rm -f "${temporaryFile}"
            return 1
        }
    elif command -v wget >/dev/null 2>&1; then
        wget --tries=3 --timeout=30 -q -O "${temporaryFile}" "${url}" || {
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

downloadXrayArchive() {
    local releaseVersion=$1
    local archive="/opt/xray-agent/xray/${xrayCoreCPUVendor}.zip"
    local url="https://github.com/XTLS/Xray-core/releases/download/${releaseVersion}/${xrayCoreCPUVendor}.zip"
    downloadVerifiedFile "${url}" "${archive}" "${url}.dgst"
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
# Nginx伪装博客
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

# 修改http_port_t端口
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

# 操作Nginx
handleNginx() {
    # 检测 Nginx 管理方式
    local nginxCtl=""
    
    # 优先检测宝塔/1Panel
    if [[ -n "${btDomain}" ]] || [[ -n $(pgrep -f "BT-Panel") ]] || [[ -f "/etc/init.d/nginx" ]]; then
        if [[ -f "/etc/init.d/nginx" ]]; then
            nginxCtl="/etc/init.d/nginx"
        elif [[ -f "/www/server/nginx/sbin/nginx" ]]; then
            nginxCtl="/www/server/nginx/sbin/nginx"
        fi
    fi
    
    # 如果不是宝塔，检测 systemd
    if [[ -z "${nginxCtl}" ]] && systemctl list-unit-files | grep -q "nginx.service"; then
        nginxCtl="systemctl"
    fi
    
    # 启动 Nginx
    if [[ "${selectCustomInstallType}" != ",3," ]] && [[ -z $(pgrep -f "nginx") ]] && [[ "$1" == "start" ]]; then
        # 验证配置语法
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

    # 停止 Nginx
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

# 定时任务更新tls证书
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
# 定时任务更新geo文件
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

# 更新证书
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
            handleXray stop
            handleXray start
            handleNginx start
        else
            echoContent green " ---> 证书有效"
        fi
    elif [[ -f "/opt/xray-agent/tls/${tlsDomain}.crt" && -f "/opt/xray-agent/tls/${tlsDomain}.key" && -n $(cat "/opt/xray-agent/tls/${tlsDomain}.crt") ]]; then
        echoContent yellow " ---> 检测到使用自定义证书，无法执行renew操作。"
    else
        echoContent red " ---> 未安装"
    fi
}

# 检查wget showProgress
checkWgetShowProgress() {
    if find /usr/bin /usr/sbin | grep -q "/wget" && wget --help | grep -q show-progress; then
        wgetShowProgressStatus="--show-progress"
    fi
}

xrayVersionAtLeast() {
    local currentVersion=${1#v}
    local requiredVersion=${2#v}
    [[ -n "${currentVersion}" && -n "${requiredVersion}" ]] || return 1
    [[ "$(printf '%s\n%s\n' "${requiredVersion}" "${currentVersion}" | sort -V | head -n 1)" == "${requiredVersion}" ]]
}

# 安装xray
installXray() {
    readInstallType
    local prereleaseStatus=false
    if [[ "$2" == "true" ]]; then
        prereleaseStatus=true
    fi

    echoContent skyBlue "\n进度  $1/${totalProgress} : 安装Xray"

    if [[ ! -f "/opt/xray-agent/xray/xray" ]]; then

        version=$(curl -fsSL --retry 3 "https://api.github.com/repos/XTLS/Xray-core/releases?per_page=5" | jq -r ".[]|select (.prerelease==${prereleaseStatus})|.tag_name" | head -1)
        echoContent green " ---> Xray-core版本:${version}"
        if [[ -z "${version}" ]] || ! downloadXrayArchive "${version}"; then
            echoContent red " ---> Xray-core 下载或校验失败"
            return 1
        fi

        if [[ ! -f "/opt/xray-agent/xray/${xrayCoreCPUVendor}.zip" ]]; then
            read -r -p "核心下载失败，请重新尝试安装，是否重新尝试？[y/n]" downloadStatus
            if [[ "${downloadStatus}" == "y" ]]; then
                installXray "$1"
            fi
        else
            unzip -o "/opt/xray-agent/xray/${xrayCoreCPUVendor}.zip" -d /opt/xray-agent/xray >/dev/null
            rm -rf "/opt/xray-agent/xray/${xrayCoreCPUVendor}.zip"

            version=$(curl -fsSL --retry 3 https://api.github.com/repos/Loyalsoldier/v2ray-rules-dat/releases?per_page=1 | jq -r '.[]|.tag_name')
            echoContent skyBlue "------------------------Version-------------------------------"
            echo "version:${version}"
            downloadGeoData "${version}" "/opt/xray-agent/xray" || return 1

            chmod 755 /opt/xray-agent/xray/xray
        fi
    else
        if [[ -z "${lastInstallationConfig}" ]]; then
            echoContent green " ---> Xray-core版本:$(/opt/xray-agent/xray/xray --version | awk '{print $2}' | head -1)"
            read -r -p "是否更新、升级？[y/n]:" reInstallXrayStatus
            if [[ "${reInstallXrayStatus}" == "y" ]]; then
                updateXray "" install
            fi
        fi
    fi
}

# xray版本管理
xrayVersionManageMenu() {
    echoContent skyBlue "\n进度  $1/${totalProgress} : Xray版本管理"
    if [[ "${coreInstallType}" != "1" ]]; then
        echoContent red " ---> 没有检测到安装目录，请执行脚本安装内容"
        exit 0
    fi
    echoContent red "\n=============================================================="
    echoContent yellow "1.升级Xray-core"
    echoContent yellow "2.升级Xray-core 预览版"
    echoContent yellow "3.回退Xray-core"
    echoContent yellow "4.关闭Xray-core"
    echoContent yellow "5.打开Xray-core"
    echoContent yellow "6.重启Xray-core"
    echoContent yellow "7.更新geosite、geoip"
    echoContent yellow "8.设置自动更新geo文件[每天凌晨更新]"
    echoContent yellow "9.查看日志"
    echoContent red "=============================================================="
    read -r -p "请选择:" selectXrayType
    if [[ "${selectXrayType}" == "1" ]]; then
        prereleaseStatus=false
        updateXray
    elif [[ "${selectXrayType}" == "2" ]]; then
        prereleaseStatus=true
        updateXray
    elif [[ "${selectXrayType}" == "3" ]]; then
        echoContent yellow "\n1.只可以回退最近的五个版本"
        echoContent yellow "2.不保证回退后一定可以正常使用"
        echoContent yellow "3.如果回退的版本不支持当前的config，则会无法连接，谨慎操作"
        echoContent skyBlue "------------------------Version-------------------------------"
        curl -s "https://api.github.com/repos/XTLS/Xray-core/releases?per_page=5" | jq -r ".[]|select (.prerelease==false)|.tag_name" | awk '{print ""NR""":"$0}'
        echoContent skyBlue "--------------------------------------------------------------"
        read -r -p "请输入要回退的版本:" selectXrayVersionType
        version=$(curl -s "https://api.github.com/repos/XTLS/Xray-core/releases?per_page=5" | jq -r ".[]|select (.prerelease==false)|.tag_name" | awk '{print ""NR""":"$0}' | grep "${selectXrayVersionType}:" | awk -F "[:]" '{print $2}')
        if [[ -n "${version}" ]]; then
            updateXray "${version}"
        else
            echoContent red "\n ---> 输入有误，请重新输入"
            xrayVersionManageMenu 1
        fi
    elif [[ "${selectXrayType}" == "4" ]]; then
        handleXray stop
    elif [[ "${selectXrayType}" == "5" ]]; then
        handleXray start
    elif [[ "${selectXrayType}" == "6" ]]; then
        handleXray stop
        handleXray start
    elif [[ "${selectXrayType}" == "7" ]]; then
        updateGeoSite
    elif [[ "${selectXrayType}" == "8" ]]; then
        installCronUpdateGeo
    elif [[ "${selectXrayType}" == "9" ]]; then
        checkLog 1
    fi
}

# 更新 geosite
updateGeoSite() {
    echoContent yellow "\n来源 https://github.com/Loyalsoldier/v2ray-rules-dat"

    version=$(curl -fsSL --retry 3 https://api.github.com/repos/Loyalsoldier/v2ray-rules-dat/releases?per_page=1 | jq -r '.[]|.tag_name')
    echoContent skyBlue "------------------------Version-------------------------------"
    echo "version:${version}"
    downloadGeoData "${version}" "${configPath}../" || return 1

    handleXray stop
    handleXray start
    echoContent green " ---> 更新完毕"

}

# 更新Xray
updateXray() {
    readInstallType

    if [[ "$2" == "install" || -z "${coreInstallType}" || "${coreInstallType}" != "1" ]]; then
        if [[ -n "$1" ]]; then
            version=$1
        else
            version=$(curl -fsSL --retry 3 "https://api.github.com/repos/XTLS/Xray-core/releases?per_page=5" | jq -r ".[]|select (.prerelease==${prereleaseStatus})|.tag_name" | head -1)
        fi

        echoContent green " ---> Xray-core版本:${version}"

        if [[ -z "${version}" ]] || ! downloadXrayArchive "${version}"; then
            echoContent red " ---> Xray-core 下载或校验失败，保留当前版本"
            return 1
        fi

        unzip -o "/opt/xray-agent/xray/${xrayCoreCPUVendor}.zip" -d /opt/xray-agent/xray >/dev/null
        rm -rf "/opt/xray-agent/xray/${xrayCoreCPUVendor}.zip"
        chmod 755 /opt/xray-agent/xray/xray
        handleXray stop
        handleXray start
    else
        echoContent green " ---> 当前Xray-core版本:$(/opt/xray-agent/xray/xray --version | awk '{print $2}' | head -1)"

        if [[ -n "$1" ]]; then
            version=$1
        else
            version=$(curl -s "https://api.github.com/repos/XTLS/Xray-core/releases?per_page=10" | jq -r ".[]|select (.prerelease==${prereleaseStatus})|.tag_name" | head -1)
        fi

        if [[ -n "$1" ]]; then
            read -r -p "回退版本为${version}，是否继续？[y/n]:" rollbackXrayStatus
            if [[ "${rollbackXrayStatus}" == "y" ]]; then
                echoContent green " ---> 当前Xray-core版本:$(/opt/xray-agent/xray/xray --version | awk '{print $2}' | head -1)"
                updateXray "${version}" install
            else
                echoContent green " ---> 放弃回退版本"
            fi
        elif [[ "${version}" == "v$(/opt/xray-agent/xray/xray --version | awk '{print $2}' | head -1)" ]]; then
            read -r -p "当前版本与最新版相同，是否重新安装？[y/n]:" reInstallXrayStatus
            if [[ "${reInstallXrayStatus}" == "y" ]]; then
                updateXray "${version}" install
            else
                echoContent green " ---> 放弃重新安装"
            fi
        else
            read -r -p "最新版本为:${version}，是否更新？[y/n]:" installXrayStatus
            if [[ "${installXrayStatus}" == "y" ]]; then
                updateXray "${version}" install
            else
                echoContent green " ---> 放弃更新"
            fi

        fi
    fi
}

# 验证整个服务是否可用
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

# Xray开机自启
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

# 操作xray
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
            exit 0
        fi
    elif [[ "$1" == "stop" ]]; then
        if [[ -z $(pgrep -f "xray/xray") ]]; then
            echoContent green " ---> Xray关闭成功"
        else
            echoContent red "xray关闭失败"
            echoContent red "请手动执行【ps -ef|grep -v grep|grep xray|awk '{print \$2}'|xargs kill -9】"
            exit 0
        fi
    fi
}

# 读取Xray用户数据并初始化


normalizeXrayEmail() {
    local value=$1 suffix
    for suffix in VLESS_TCP/TLS_Vision VLESS_WS vless_reality_vision Hysteria2; do
        if [[ "${value}" == *-"${suffix}" ]]; then
            printf '%s\n' "${value%-${suffix}}"
            return 0
        fi
    done
    printf '%s\n' "${value}"
}

initXrayClients() {
    local clientType=$1
    local newUUID=$2
    local newEmail=$3
    case "${clientType}" in
    0 | 1 | 3) ;;
    *)
        echoContent red "不支持的 Xray 客户端类型: ${clientType}" >&2
        return 1
        ;;
    esac

    # 检查 currentClients 是否为空或 null，避免 jq 操作错误
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
    *) return 1 ;;
    esac
}

# 将脚本现有的 UUID 用户转换为 Xray-core Hysteria2 认证客户端。
# UUID 作为 auth 使用，便于所有已安装协议共用同一套账号。
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
# 添加Xray-core 出站
addXrayOutbound() {
    local tag=$1
    local domainStrategy=

    if echo "${tag}" | grep -q "IPv4"; then
        domainStrategy="ForceIPv4"
    elif echo "${tag}" | grep -q "IPv6"; then
        domainStrategy="ForceIPv6"
    fi

    if [[ -n "${domainStrategy}" ]]; then
        cat <<EOF >"/opt/xray-agent/xray/conf/${tag}.json"
{
    "outbounds":[
        {
            "protocol":"freedom",
            "settings":{
                "domainStrategy":"${domainStrategy}"
            },
            "tag":"${tag}"
        }
    ]
}
EOF
    fi
    # direct
    if echo "${tag}" | grep -q "direct"; then
        cat <<EOF >"/opt/xray-agent/xray/conf/${tag}.json"
{
    "outbounds":[
        {
            "protocol":"freedom",
            "settings": {
                "domainStrategy":"UseIP"
            },
            "tag":"${tag}"
        }
    ]
}
EOF
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
    # socks5 outbound
    if echo "${tag}" | grep -q "socks5"; then
        cat <<EOF >"/opt/xray-agent/xray/conf/${tag}.json"
{
  "outbounds": [
    {
      "protocol": "socks",
      "tag": "${tag}",
      "settings": {
        "servers": [
          {
            "address": "${socks5RoutingOutboundIP}",
            "port": ${socks5RoutingOutboundPort},
            "users": [
              {
                "user": "${socks5RoutingOutboundUserName}",
                "pass": "${socks5RoutingOutboundPassword}"
              }
            ]
          }
        ]
      }
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

# 删除 Xray-core出站
removeXrayOutbound() {
    local tag=$1
    if [[ -f "/opt/xray-agent/xray/conf/${tag}.json" ]]; then
        rm "/opt/xray-agent/xray/conf/${tag}.json" >/dev/null 2>&1
    fi
}
# 初始化Xray 配置文件

initXrayConfig() {
    echoContent skyBlue "\n进度 $2/${totalProgress} : 初始化Xray配置"
    echo
    # 仅保留 Vision、WebSocket、Reality Vision 与 Hysteria2。
    # 重新安装/升级时删除旧版本遗留的其他协议入站，避免 Xray 继续加载。
    find /opt/xray-agent/xray/conf -maxdepth 1 -type f \( \
        -name '*trojan*inbounds.json' -o \
        -name '*VLESS_gRPC_inbounds.json' -o \
        -name '*VLESS_vision_gRPC_inbounds.json' -o \
        -name '*VLESS_XHTTP_inbounds.json' -o \
        -name '*tuic_inbounds.json' -o \
        -name '*naive_inbounds.json' -o \
        -name '*VMess_HTTPUpgrade_inbounds.json' -o \
        -name '*anytls_inbounds.json' \
    \) -delete 2>/dev/null

    local uuid=
    local addClientsStatus=
    # 总是询问是否使用上次用户配置，不管lastInstallationConfig的值
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

        echoContent yellow "\n请输入自定义用户名[需合法]，[回车]随机用户名"
        read -r -p '用户名:' customEmail
        if [[ -z ${customEmail} ]]; then
            customEmail="$(echo "${uuid}" | cut -d "-" -f 1)-VLESS_TCP/TLS_Vision"
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
    # 回落nginx
    local fallbacksList='{"dest":31300,"xver":1},{"alpn":"h2","dest":31302,"xver":1}'

    # VLESS_WS_TLS
    if echo "${selectCustomInstallType}" | grep -q ",1," || [[ "$1" == "all" ]]; then
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
    if echo "${selectCustomInstallType}" | grep -q ",6," || [[ "$1" == "all" ]]; then
        echoContent skyBlue "\n===================== 配置Hysteria2+TLS =====================\n"
        initHysteria2Port
        initHysteria2BbrProfile
        initHysteria2Masquerade
        local hysteria2UserField="clients"
        local installedXrayVersion=
        installedXrayVersion=$(/opt/xray-agent/xray/xray --version 2>/dev/null | awk 'NR == 1 {print $2}')
        if xrayVersionAtLeast "${installedXrayVersion}" "26.5.9"; then
            hysteria2UserField="users"
        fi
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
    elif [[ -z "$3" ]]; then
        rm /opt/xray-agent/xray/conf/05_hysteria2_inbounds.json >/dev/null 2>&1
    fi
    # VLESS Vision
    if echo "${selectCustomInstallType}" | grep -q ",0," || [[ "$1" == "all" ]]; then

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

    # VLESS_TCP/reality
    if echo "${selectCustomInstallType}" | grep -q ",3," || [[ "$1" == "all" ]]; then
        echoContent skyBlue "\n===================== 配置VLESS+Reality =====================\n"

        initXrayRealityPort
        initRealityClientServersName
        initRealityKey
        initRealityMldsa65

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

# 账号
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
}
initSubscribeLocalConfig() {
    rm -rf /opt/xray-agent/subscribe_local/sing-box/*
}
# 通用
defaultBase64Code() {
    local type=$1
    local port=$2
    local email=$3
    local id=$4
    local add=$5
    local path=$6
    case "${type}" in
    vlesstcp | vlessws | vlessReality | hysteria) ;;
    *)
        echoContent red " ---> 当前脚本不再支持该协议: ${type}"
        return 1
        ;;
    esac
    local user=
    user=$(echo "${email}" | awk -F "[-]" '{print $1}')
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
        singBoxSubscribeLocalConfig=$(jq -r ". += [{\"tag\":\"${email}\",\"type\":\"vless\",\"server\":\"${currentHost}\",\"server_port\":${port},\"uuid\":\"${id}\",\"flow\":\"xtls-rprx-vision\",\"tls\":{\"enabled\":true,\"server_name\":\"${currentHost}\",\"utls\":{\"enabled\":true,\"fingerprint\":\"chrome\"}},\"packet_encoding\":\"xudp\"}]" "/opt/xray-agent/subscribe_local/sing-box/${user}")
        echo "${singBoxSubscribeLocalConfig}" | jq . >"/opt/xray-agent/subscribe_local/sing-box/${user}"

        echoContent yellow " ---> 二维码 VLESS(VLESS+TCP+TLS_Vision)"
        echoContent green "    https://api-qr-server.zew9.com/v1/create-qr-code/?size=400x400&data=vless%3A%2F%2F${id}%40${currentHost}%3A${port}%3Fencryption%3Dnone%26fp%3Dchrome%26security%3Dtls%26type%3Dtcp%26${currentHost}%3D${currentHost}%26headerType%3Dnone%26sni%3D${currentHost}%26flow%3Dxtls-rprx-vision%23${email}\n"

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

        singBoxSubscribeLocalConfig=$(jq -r ". += [{\"tag\":\"${email}\",\"type\":\"vless\",\"server\":\"${add}\",\"server_port\":${port},\"uuid\":\"${id}\",\"tls\":{\"enabled\":true,\"server_name\":\"${currentHost}\",\"utls\":{\"enabled\":true,\"fingerprint\":\"chrome\"}},\"multiplex\":{\"enabled\":false,\"protocol\":\"smux\",\"max_streams\":32},\"packet_encoding\":\"xudp\",\"transport\":{\"type\":\"ws\",\"path\":\"${path}\",\"headers\":{\"Host\":\"${currentHost}\"}}}]" "/opt/xray-agent/subscribe_local/sing-box/${user}")
        echo "${singBoxSubscribeLocalConfig}" | jq . >"/opt/xray-agent/subscribe_local/sing-box/${user}"

        echoContent yellow " ---> 二维码 VLESS(VLESS+WS+TLS)"
        echoContent green "    https://api-qr-server.zew9.com/v1/create-qr-code/?size=400x400&data=vless%3A%2F%2F${id}%40${add}%3A${port}%3Fencryption%3Dnone%26security%3Dtls%26type%3Dws%26host%3D${currentHost}%26fp%3Dchrome%26sni%3D${currentHost}%26path%3D${path}%23${email}"

    elif [[ "${type}" == "hysteria" ]]; then
        echoContent yellow " ---> 通用格式(Hysteria2+TLS+QUIC)"
        echoContent green "    hysteria2://${id}@${currentHost}:${port}/?sni=${currentHost}&alpn=h3&insecure=0#${email}\n"
        cat <<EOF >>"/opt/xray-agent/subscribe_local/default/${user}"
hysteria2://${id}@${currentHost}:${port}/?sni=${currentHost}&alpn=h3&insecure=0#${email}
EOF

        cat <<EOF >>"/opt/xray-agent/subscribe_local/clashMeta/${user}"
  - name: "${email}"
    type: hysteria2
    server: ${currentHost}
    port: ${port}
    password: ${id}
    sni: ${currentHost}
    alpn:
      - h3
    skip-cert-verify: false
EOF

        singBoxSubscribeLocalConfig=$(jq -r ". += [{\"tag\":\"${email}\",\"type\":\"hysteria2\",\"server\":\"${currentHost}\",\"server_port\":${port},\"password\":\"${id}\",\"tls\":{\"enabled\":true,\"server_name\":\"${currentHost}\",\"alpn\":[\"h3\"],\"insecure\":false}}]" "/opt/xray-agent/subscribe_local/sing-box/${user}")
        echo "${singBoxSubscribeLocalConfig}" | jq . >"/opt/xray-agent/subscribe_local/sing-box/${user}"

        echoContent yellow " ---> 二维码 Hysteria2(TLS)"
        echoContent green "    https://api-qr-server.zew9.com/v1/create-qr-code/?size=400x400&data=hysteria2%3A%2F%2F${id}%40${currentHost}%3A${port}%2F%3Fsni%3D${currentHost}%26alpn%3Dh3%26insecure%3D0%23${email}\n"

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

        singBoxSubscribeLocalConfig=$(jq -r ". += [{\"tag\":\"${email}\",\"type\":\"vless\",\"server\":\"$(getPublicIP)\",\"server_port\":${port},\"uuid\":\"${id}\",\"flow\":\"xtls-rprx-vision\",\"tls\":{\"enabled\":true,\"server_name\":\"${realityServerName}\",\"utls\":{\"enabled\":true,\"fingerprint\":\"chrome\"},\"reality\":{\"enabled\":true,\"public_key\":\"${publicKey}\",\"short_id\":\"6ba85179e30d4fc2\"}},\"packet_encoding\":\"xudp\"}]" "/opt/xray-agent/subscribe_local/sing-box/${user}")
        echo "${singBoxSubscribeLocalConfig}" | jq . >"/opt/xray-agent/subscribe_local/sing-box/${user}"

        echoContent yellow " ---> 二维码 VLESS(VLESS+reality+uTLS+Vision)"
        echoContent green "    https://api-qr-server.zew9.com/v1/create-qr-code/?size=400x400&data=vless%3A%2F%2F${id}%40$(getPublicIP)%3A${port}%3Fencryption%3Dnone%26security%3Dreality%26type%3Dtcp%26sni%3D${realityServerName}%26fp%3Dchrome%26pbk%3D${publicKey}%26sid%3D6ba85179e30d4fc2%26flow%3Dxtls-rprx-vision%23${email}\n"

    fi

}


# 移除nginx302配置


removeNginx302() {
    # 检查配置文件是否存在
    if [[ ! -f "${nginxConfigPath}xray-agent.conf" ]]; then
        echoContent red " ---> 配置文件不存在: ${nginxConfigPath}xray-agent.conf"
        echoContent yellow " ---> 请先完成 Xray 安装后再使用此功能"
        return 1
    fi
    
    # 使用临时文件避免在循环中修改原文件
    local tmpFile="${nginxConfigPath}xray-agent.conf.tmp"
    cp "${nginxConfigPath}xray-agent.conf" "${tmpFile}"
    
    # 删除所有 return 302/301 行（排除包含 request_uri 的）
    sed -i '/return 30[12]/!b; /request_uri/b; d' "${tmpFile}"
    
    # 替换原文件
    mv "${tmpFile}" "${nginxConfigPath}xray-agent.conf"
}

# 检查302是否成功
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

# 备份恢复nginx文件
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
# 添加302配置
addNginx302() {
    local redirectUrl="$1"
    local redirectCode="302"  # 固定使用 302

    # 检查配置文件是否存在
    if [[ ! -f "${nginxConfigPath}xray-agent.conf" ]]; then
        echoContent red " ---> 配置文件不存在: ${nginxConfigPath}xray-agent.conf"
        echoContent yellow " ---> 请先完成 Xray 安装后再使用此功能"
        backupNginxConfig restoreBackup
        return 1
    fi
    
    # 验证 URL 格式
    if [[ ! "${redirectUrl}" =~ ^https?:// ]]; then
        echoContent red " ---> URL 格式错误，必须以 http:// 或 https:// 开头"
        backupNginxConfig restoreBackup
        return 1
    fi
    
    # 转义特殊字符（单引号）
    redirectUrl="${redirectUrl//\'/\'\\\'\'}"
    
    # 读取所有 location / { 的行号到数组
    local lineNumbers=()
    while IFS= read -r line; do
        lineNumbers+=("$(echo "${line}" | awk -F ":" '{print $1}')")
    done < <(grep -n "location / {" "${nginxConfigPath}xray-agent.conf")
    
    # 从后往前插入，避免行号变化
    local count=${#lineNumbers[@]}
    for ((i=count-1; i>=0; i--)); do
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

# 更新伪装站
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

# 添加新端口
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
    read -r -p "请选择:" selectNewPortType
    if [[ "${selectNewPortType}" == "1" ]]; then
        find ${configPath} -name "*dokodemodoor*" | grep -v "hysteria" | awk -F "[c][o][n][f][/]" '{print $2}' | awk -F "[_]" '{print $4}' | awk -F "[.]" '{print ""NR""":"$1}'
        exit 0
    elif [[ "${selectNewPortType}" == "2" ]]; then
        read -r -p "请输入端口号:" newPort
        read -r -p "请输入默认的端口号，同时会更改订阅端口以及节点端口，[回车]默认443:" defaultPort

        if [[ -n "${defaultPort}" ]]; then
            rm -rf "$(find ${configPath}* | grep "default")"
        fi

        if [[ -n "${newPort}" ]]; then

            while read -r port; do
                rm -rf "$(find ${configPath}* | grep "${port}")"

                local fileName=
                local hysteriaFileName=
                if [[ -n "${defaultPort}" && "${port}" == "${defaultPort}" ]]; then
                    fileName="${configPath}02_dokodemodoor_inbounds_${port}_default.json"
                else
                    fileName="${configPath}02_dokodemodoor_inbounds_${port}.json"
                fi

                if [[ -n ${hysteria2Port} ]]; then
                    hysteriaFileName="${configPath}02_dokodemodoor_inbounds_hysteria_${port}.json"
                fi

                # 开放端口
                allowPort "${port}"
                allowPort "${port}" "udp"

                local settingsPort=443
                if [[ -n "${customPort}" ]]; then
                    settingsPort=${customPort}
                fi

                if [[ -n ${hysteriaFileName} ]]; then
                    cat <<EOF >"${hysteriaFileName}"
{
  "inbounds": [
	{
	  "listen": "0.0.0.0",
	  "port": ${port},
	  "protocol": "dokodemo-door",
	  "settings": {
		"address": "127.0.0.1",
		"port": ${hysteria2Port},
		"network": "udp",
		"followRedirect": false
	  },
	  "tag": "dokodemo-door-newPort-hysteria-${port}"
	}
  ]
}
EOF
                fi
                cat <<EOF >"${fileName}"
{
  "inbounds": [
	{
	  "listen": "0.0.0.0",
	  "port": ${port},
	  "protocol": "dokodemo-door",
	  "settings": {
		"address": "127.0.0.1",
		"port": ${settingsPort},
		"network": "tcp",
		"followRedirect": false
	  },
	  "tag": "dokodemo-door-newPort-${port}"
	}
  ]
}
EOF
            done < <(echo "${newPort}" | tr ',' '\n')

            echoContent green " ---> 添加完毕"
            handleXray stop
            handleXray start
            addCorePort
        fi
    elif [[ "${selectNewPortType}" == "3" ]]; then
        find ${configPath} -name "*dokodemodoor*" | grep -v "hysteria" | awk -F "[c][o][n][f][/]" '{print $2}' | awk -F "[_]" '{print $4}' | awk -F "[.]" '{print ""NR""":"$1}'
        read -r -p "请输入要删除的端口编号:" portIndex
        local dokoConfig
        dokoConfig=$(find ${configPath} -name "*dokodemodoor*" | grep -v "hysteria" | awk -F "[c][o][n][f][/]" '{print $2}' | awk -F "[_]" '{print $4}' | awk -F "[.]" '{print ""NR""":"$1}' | grep "${portIndex}:")
        if [[ -n "${dokoConfig}" ]]; then
            rm "${configPath}02_dokodemodoor_inbounds_$(echo "${dokoConfig}" | awk -F "[:]" '{print $2}').json"
            local hysteriaDokodemodoorFilePath=

            hysteriaDokodemodoorFilePath="${configPath}02_dokodemodoor_inbounds_hysteria_$(echo "${dokoConfig}" | awk -F "[:]" '{print $2}').json"
            if [[ -f "${hysteriaDokodemodoorFilePath}" ]]; then
                rm "${hysteriaDokodemodoorFilePath}"
            fi

            handleXray stop
            handleXray start
            addCorePort
        else
            echoContent yellow "\n ---> 编号输入错误，请重新选择"
            addCorePort
        fi
    fi
}

# 卸载脚本
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

# 自定义uuid
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
            exit 0
        fi
    fi
}

# 自定义email
customUserEmail() {
    read -r -p "请输入合法的email，[回车]随机email:" currentCustomEmail
    echo
    if [[ -z "${currentCustomEmail}" ]]; then
        currentCustomEmail="${currentCustomUUID}"
        echoContent yellow "email: ${currentCustomEmail}\n"
    else
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
            echoContent red " ---> email不可重复"
            exit 0
        fi
    fi
}

# 添加用户
addUser() {
    read -r -p "请输入要添加的用户数量:" userNum
    echo
    if [[ -z ${userNum} || ${userNum} -le 0 ]]; then
        echoContent red " ---> 输入有误，请重新输入"
        exit 0
    fi
    local userConfig=".inbounds[0].settings.clients"

    while [[ ${userNum} -gt 0 ]]; do
        readConfigHostPathUUID
        local users=
        ((userNum--)) || true

        customUUID
        customUserEmail

        uuid=${currentCustomUUID}
        email=${currentCustomEmail}

        # VLESS TCP
        if echo "${currentInstallProtocolType}" | grep -q ",0,"; then
            local clients=
            clients=$(initXrayClients 0 "${uuid}" "${email}")
            clients=$(jq -r "${userConfig} = ${clients}" ${configPath}02_VLESS_TCP_inbounds.json)
            echo "${clients}" | jq . >${configPath}02_VLESS_TCP_inbounds.json
        fi

        # VLESS WS
        if echo "${currentInstallProtocolType}" | grep -q ",1,"; then
            local clients=
            clients=$(initXrayClients 1 "${uuid}" "${email}")
            clients=$(jq -r "${userConfig} = ${clients}" ${configPath}03_VLESS_WS_inbounds.json)
            echo "${clients}" | jq . >${configPath}03_VLESS_WS_inbounds.json
        fi

        # vless reality vision
        if echo "${currentInstallProtocolType}" | grep -q ",3,"; then
            local clients=
            clients=$(initXrayClients 3 "${uuid}" "${email}") || return 1
            clients=$(jq -r "${userConfig} = ${clients}" ${configPath}07_VLESS_vision_reality_inbounds.json)
            echo "${clients}" | jq . >${configPath}07_VLESS_vision_reality_inbounds.json
        fi

        # Hysteria2 使用同一个 UUID 作为认证密码
        if echo "${currentInstallProtocolType}" | grep -q ",6,"; then
            local hysteria2Config=
            hysteria2Config=$(jq --arg auth "${uuid}" --arg email "${email}-Hysteria2" '
                if .inbounds[0].settings.clients != null then
                    .inbounds[0].settings.clients += [{auth: $auth, level: 0, email: $email}]
                else
                    .inbounds[0].settings.users += [{auth: $auth, level: 0, email: $email}]
                end
            ' "${configPath}05_hysteria2_inbounds.json")
            echo "${hysteria2Config}" | jq . >"${configPath}05_hysteria2_inbounds.json"
        fi

    done
    handleXray stop
    handleXray start
    echoContent green " ---> 添加完成"
    subscribe false
    manageAccount 1
}
# 移除用户
removeUser() {
    local sourceConfig= candidateConfig userCount delUserIndex userId temporaryConfig
    local -a preferredConfigs=(
        "02_VLESS_TCP_inbounds.json" "03_VLESS_WS_inbounds.json"
        "07_VLESS_vision_reality_inbounds.json" "05_hysteria2_inbounds.json"
    )

    for candidateConfig in "${preferredConfigs[@]}"; do
        candidateConfig="${configPath}${candidateConfig}"
        [[ -f "${candidateConfig}" ]] || continue
        userCount=$(jq -r '(.inbounds[0].settings.clients // .inbounds[0].settings.users // .inbounds[0].users // []) | length' "${candidateConfig}" 2>/dev/null)
        if [[ "${userCount}" =~ ^[0-9]+$ && ${userCount} -gt 0 ]]; then
            sourceConfig="${candidateConfig}"
            break
        fi
    done

    if [[ -z "${sourceConfig}" ]]; then
        echoContent red " ---> 未找到可删除的用户"
        return 1
    fi

    jq -r '(.inbounds[0].settings.clients // .inbounds[0].settings.users // .inbounds[0].users // [])[] | (.email // .name // .username // "unnamed")' "${sourceConfig}" | awk '{print NR":"$0}'
    read -r -p "请选择要删除的用户编号[仅支持单个删除]:" delUserIndex
    if [[ ! "${delUserIndex}" =~ ^[0-9]+$ || ${delUserIndex} -lt 1 || ${delUserIndex} -gt ${userCount} ]]; then
        echoContent red " ---> 选择错误"
        return 1
    fi

    userId=$(jq -r --argjson index "$((delUserIndex - 1))" '(.inbounds[0].settings.clients // .inbounds[0].settings.users // .inbounds[0].users // [])[$index] | (.id // .uuid // .auth // .password // empty)' "${sourceConfig}")
    if [[ -z "${userId}" ]]; then
        echoContent red " ---> 无法识别该用户的 UUID/auth，未修改配置"
        return 1
    fi

    while IFS= read -r candidateConfig; do
        if ! jq -e --arg userId "${userId}" '
            any((.inbounds[]?.settings.clients[]?, .inbounds[]?.settings.users[]?, .inbounds[]?.users[]?);
                (.id // .uuid // .auth // .password // "") == $userId)
        ' "${candidateConfig}" >/dev/null 2>&1; then
            continue
        fi

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
    done < <(find "${configPath}" -maxdepth 1 -type f -name '*inbounds.json' 2>/dev/null)

    handleXray stop
    handleXray start
    manageAccount 1
}
# 更新脚本
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
    if ! downloadFile "${scriptUrl}" "${temporaryScript}"; then
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

# 防火墙
handleFirewall() {
    if systemctl status ufw 2>/dev/null | grep -q "active (exited)" && [[ "$1" == "stop" ]]; then
        systemctl stop ufw >/dev/null 2>&1
        systemctl disable ufw >/dev/null 2>&1
        echoContent green " ---> ufw关闭成功"

    fi

    if systemctl status firewalld 2>/dev/null | grep -q "active (running)" && [[ "$1" == "stop" ]]; then
        systemctl stop firewalld >/dev/null 2>&1
        systemctl disable firewalld >/dev/null 2>&1
        echoContent green " ---> firewalld关闭成功"
    fi
}

# 查看、检查日志
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
        handleXray stop
        handleXray start
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

# 脚本快捷方式
aliasInstall() {
    # 获取当前脚本的实际路径
    local currentScript
    currentScript="$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")"
    
    # 确保目标目录存在
    if [[ ! -d "/opt/xray-agent" ]]; then
        mkdir -p /opt/xray-agent
    fi
    
    # 只在首次安装或文件不存在时复制
    local targetScript="/opt/xray-agent/install.sh"
    local needCopy=false
    
    if [[ ! -f "$targetScript" ]]; then
        needCopy=true
    elif [[ "$currentScript" != "$targetScript" ]]; then
        # 如果当前脚本不是目标位置，则需要复制（更新场景）
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

    # 检查并创建软连接
    local xrayaType=false
    local symlinkPath=""
    
    if [[ -d "/usr/bin/" ]]; then
        symlinkPath="/usr/bin/xraya"
    elif [[ -d "/usr/sbin" ]]; then
        symlinkPath="/usr/sbin/xraya"
    fi
    
    if [[ -n "$symlinkPath" ]]; then
        # 检查软连接是否已存在且正确
        if [[ -L "$symlinkPath" ]] && [[ "$(readlink "$symlinkPath")" == "$targetScript" ]]; then
            # 软连接已存在且正确，无需重新创建
            xrayaType=true
        else
            # 删除旧的软连接或文件
            rm -f "$symlinkPath"
            
            # 创建新的软连接
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
# 检查ipv6、ipv4
checkIPv6() {
    currentIPv6IP=$(curl -s -6 -m 4 http://www.cloudflare.com/cdn-cgi/trace | grep "ip" | cut -d "=" -f 2)

    if [[ -z "${currentIPv6IP}" ]]; then
        echoContent red " ---> 不支持ipv6"
        exit 0
    fi
}

# ipv6 分流
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

                rm ${configPath}09_routing.json >/dev/null 2>&1
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

    handleXray stop
    handleXray start
}

# ipv6分流规则展示
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
# 域名黑名单


# 添加routing配置
addInstallRouting() {

    local tag=$1    # warp-socks
    local type=$2   # outboundTag/inboundTag
    local domain=$3 # 域名

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
# 根据tag卸载Routing
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

# 卸载嗅探
unInstallSniffing() {

    find ${configPath} -name "*inbounds.json*" | awk -F "[c][o][n][f][/]" '{print $2}' | while read -r inbound; do
        if grep -q "destOverride" <"${configPath}${inbound}"; then
            sniffing=$(jq -r 'del(.inbounds[0].sniffing)' "${configPath}${inbound}")
            echo "${sniffing}" | jq . >"${configPath}${inbound}"
        fi
    done

}

# 安装嗅探
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

# 读取第三方warp配置
readConfigWarpReg() {
    if [[ ! -f "/opt/xray-agent/warp/config" ]]; then
        /opt/xray-agent/warp/warp-reg >/opt/xray-agent/warp/config
    fi

    secretKeyWarpReg=$(grep <"/opt/xray-agent/warp/config" private_key | awk '{print $2}')

    addressWarpReg=$(grep <"/opt/xray-agent/warp/config" v6 | awk '{print $2}')

    publicKeyWarpReg=$(grep <"/opt/xray-agent/warp/config" public_key | awk '{print $2}')

    reservedWarpReg=$(grep <"/opt/xray-agent/warp/config" reserved | awk -F "[:]" '{print $2}')

}
# 安装warp-reg工具
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

# 展示warp分流域名
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

# 添加WireGuard分流
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

# 卸载wireGuard
unInstallWireGuard() {
    local type=$1
    if [[ "${coreInstallType}" == "1" ]]; then

        if [[ "${type}" == "IPv4" ]]; then
            if [[ ! -f "${configPath}wireguard_out_IPv6.json" ]]; then
                rm -rf /opt/xray-agent/warp/config >/dev/null 2>&1
            fi
        elif [[ "${type}" == "IPv6" ]]; then
            if [[ ! -f "${configPath}wireguard_out_IPv4.json" ]]; then
                rm -rf /opt/xray-agent/warp/config >/dev/null 2>&1
            fi
        fi
    fi

}
# 移除WireGuard分流
removeWireGuardRoute() {
    local type=$1
    if [[ "${coreInstallType}" == "1" ]]; then

        unInstallRouting wireguard_out_"${type}" outboundTag

        removeXrayOutbound "wireguard_out_${type}"
        if [[ ! -f "${configPath}IPv4_out.json" ]]; then
            addXrayOutbound IPv4_out
        fi
    fi


    unInstallWireGuard "${type}"
}
# warp分流-第三方IPv4
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

                rm ${configPath}09_routing.json >/dev/null 2>&1
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
    handleXray stop
    handleXray start
}

# ==================== 中转管理 ====================

# 返回本机已安装、可作为中转入口的协议。
detectRelayInbounds() {
    relayInboundTags=()
    relayInboundLabels=()
    [[ -f "${configPath}02_VLESS_TCP_inbounds.json" ]] && relayInboundTags+=("VLESSTCP") && relayInboundLabels+=("VLESS + TCP + TLS Vision")
    [[ -f "${configPath}03_VLESS_WS_inbounds.json" ]] && relayInboundTags+=("VLESSWS") && relayInboundLabels+=("VLESS + WebSocket + TLS")
    [[ -f "${configPath}07_VLESS_vision_reality_inbounds.json" ]] && relayInboundTags+=("VLESSReality") && relayInboundLabels+=("VLESS + Reality + Vision")
    [[ -f "${configPath}05_hysteria2_inbounds.json" ]] && relayInboundTags+=("Hysteria2") && relayInboundLabels+=("Hysteria2 + TLS + QUIC")
}

# 选择需要走中转的本机入站，结果保存为 JSON 数组。
selectRelayInbounds() {
    detectRelayInbounds
    if ((${#relayInboundTags[@]} == 0)); then
        echoContent red " ---> 未检测到可用的入站协议"
        return 1
    fi

    echoContent skyBlue "\n本机已安装的入站协议"
    local index
    for ((index = 0; index < ${#relayInboundTags[@]}; index++)); do
        echoContent yellow "$((index + 1)).${relayInboundLabels[index]}"
    done

    local selection
    read -r -p "请选择需要链式转发的入站[可多选，例:1,4]:" selection
    selection=${selection//，/,}
    if [[ -z "${selection}" ]]; then
        echoContent red " ---> 至少选择一个入站"
        return 1
    fi

    local -a selectedTags=()
    local -a choices=()
    local choice tag existing
    IFS=',' read -r -a choices <<<"${selection}"
    for choice in "${choices[@]}"; do
        choice=${choice//[[:space:]]/}
        if [[ ! "${choice}" =~ ^[0-9]+$ ]] || ((choice < 1 || choice > ${#relayInboundTags[@]})); then
            echoContent red " ---> 入站选项无效: ${choice}"
            return 1
        fi
        tag=${relayInboundTags[choice - 1]}
        existing=false
        local selected
        for selected in "${selectedTags[@]}"; do
            [[ "${selected}" == "${tag}" ]] && existing=true
        done
        [[ "${existing}" == "false" ]] && selectedTags+=("${tag}")
    done

    relaySelectedInboundTags=$(printf '%s\n' "${selectedTags[@]}" | jq -R . | jq -sc .)
}

validateRelayPort() {
    local value=$1
    [[ "${value}" =~ ^[0-9]+$ ]] && ((value >= 1 && value <= 65535))
}

# 从 sing-box JSON 订阅中读取 Shadowsocks 出站并转换为 Xray 配置。
buildRelayOutboundFromSingBoxSubscription() {
    local subscriptionFile=$1 selectedTag=$2 outboundTag=$3 outputFile=$4
    local node
    node=$(jq -c --arg tag "${selectedTag}" '
        first(.outbounds[]? | select(.type == "shadowsocks" and .tag == $tag))
    ' "${subscriptionFile}") || return 1
    [[ -n "${node}" && "${node}" != "null" ]] || return 1

    if ! jq -e '
        (.server | type == "string" and length > 0) and
        (.server_port | type == "number" and . >= 1 and . <= 65535) and
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
    ' >"${outputFile}"
}

fetchRelaySubscription() {
    local url=$1 destination=$2
    if [[ ! "${url}" =~ ^https?:// ]]; then
        echoContent red " ---> 订阅地址必须以 http:// 或 https:// 开头"
        return 1
    fi
    if ! downloadFile "${url}" "${destination}"; then
        echoContent red " ---> 中转订阅下载失败"
        return 1
    fi
    if ! jq -e '.outbounds | type == "array"' "${destination}" >/dev/null 2>&1; then
        echoContent red " ---> 订阅内容不是有效的 sing-box JSON"
        return 1
    fi
}

installCronRelaySubscription() {
    crontab -l >/opt/xray-agent/backup_crontab.cron 2>/dev/null || true
    local historyCrontab
    historyCrontab=$(sed '/xray-agent-update-relay/d;/xray-agent\/install.sh UpdateRelay/d' /opt/xray-agent/backup_crontab.cron)
    echo "${historyCrontab}" >/opt/xray-agent/backup_crontab.cron
    echo "17 4 * * * /bin/bash /opt/xray-agent/install.sh UpdateRelay >> /opt/xray-agent/crontab_relay.log 2>&1 # xray-agent-update-relay" >>/opt/xray-agent/backup_crontab.cron
    crontab /opt/xray-agent/backup_crontab.cron
}

removeCronRelaySubscription() {
    crontab -l >/opt/xray-agent/backup_crontab.cron 2>/dev/null || true
    local historyCrontab
    historyCrontab=$(sed '/xray-agent-update-relay/d;/xray-agent\/install.sh UpdateRelay/d' /opt/xray-agent/backup_crontab.cron)
    echo "${historyCrontab}" >/opt/xray-agent/backup_crontab.cron
    crontab /opt/xray-agent/backup_crontab.cron
}

# 使用 sing-box JSON 订阅配置 Shadowsocks 中转。
setupRelaySubscription() {
    selectRelayInbounds || return

    local subscriptionUrl tempDir subscriptionFile nodeCount nodeIndex selectedTag outboundFile backupDir
    read -r -p "请输入 sing-box JSON 订阅地址:" subscriptionUrl
    [[ -z "${subscriptionUrl}" ]] && echoContent red " ---> 订阅地址不能为空" && return 1

    tempDir=$(mktemp -d /tmp/xray-relay-subscription.XXXXXX) || return 1
    subscriptionFile="${tempDir}/subscription.json"
    outboundFile="${tempDir}/relay_tcp_outbound.json"
    backupDir="${tempDir}/backup"
    mkdir -p "${backupDir}"
    fetchRelaySubscription "${subscriptionUrl}" "${subscriptionFile}" || {
        rm -rf "${tempDir}"
        return 1
    }

    nodeCount=$(jq '[.outbounds[]? | select(.type == "shadowsocks")] | length' "${subscriptionFile}")
    if ((nodeCount == 0)); then
        echoContent red " ---> 订阅中没有 Shadowsocks 节点"
        rm -rf "${tempDir}"
        return 1
    fi
    if ((nodeCount == 1)); then
        selectedTag=$(jq -r 'first(.outbounds[] | select(.type == "shadowsocks")) | .tag' "${subscriptionFile}")
    else
        echoContent skyBlue "\n订阅中的 Shadowsocks 节点"
        jq -r '[.outbounds[] | select(.type == "shadowsocks")] | to_entries[] | "\(.key + 1).\(.value.tag) -> \(.value.server):\(.value.server_port)"' "${subscriptionFile}"
        read -r -p "请选择上游节点:" nodeIndex
        if [[ ! "${nodeIndex}" =~ ^[0-9]+$ ]] || ((nodeIndex < 1 || nodeIndex > nodeCount)); then
            echoContent red " ---> 节点选项无效"
            rm -rf "${tempDir}"
            return 1
        fi
        selectedTag=$(jq -r --argjson index "$((nodeIndex - 1))" '[.outbounds[] | select(.type == "shadowsocks")][$index].tag' "${subscriptionFile}")
    fi

    buildRelayOutboundFromSingBoxSubscription "${subscriptionFile}" "${selectedTag}" "relay_tcp_outbound" "${outboundFile}" || {
        echoContent red " ---> Shadowsocks 节点字段不完整"
        rm -rf "${tempDir}"
        return 1
    }

    local backupFile
    for backupFile in relay_outbound.json relay_tcp_outbound.json relay_udp_outbound.json 09_routing.json; do
        [[ -f "${configPath}${backupFile}" ]] && cp "${configPath}${backupFile}" "${backupDir}/${backupFile}"
    done
    [[ -f /opt/xray-agent/relay_config.json ]] && cp /opt/xray-agent/relay_config.json "${backupDir}/relay_config.json"

    rm -f "${configPath}relay_outbound.json" "${configPath}relay_tcp_outbound.json" "${configPath}relay_udp_outbound.json"
    mv "${outboundFile}" "${configPath}relay_tcp_outbound.json"
    addRelayRouting "${relaySelectedInboundTags}" "relay_tcp_outbound" "relay_tcp_outbound" || {
        restoreRelayBackup "${backupDir}"
        rm -rf "${tempDir}"
        return 1
    }

    local nodeAddress nodePort nodeMethod validationOutput
    nodeAddress=$(jq -r --arg tag "${selectedTag}" 'first(.outbounds[] | select(.type == "shadowsocks" and .tag == $tag)).server' "${subscriptionFile}")
    nodePort=$(jq -r --arg tag "${selectedTag}" 'first(.outbounds[] | select(.type == "shadowsocks" and .tag == $tag)).server_port' "${subscriptionFile}")
    nodeMethod=$(jq -r --arg tag "${selectedTag}" 'first(.outbounds[] | select(.type == "shadowsocks" and .tag == $tag)).method' "${subscriptionFile}")
    jq -n --argjson inboundTags "${relaySelectedInboundTags}" --arg url "${subscriptionUrl}" --arg selectedTag "${selectedTag}" \
        --arg address "${nodeAddress}" --arg port "${nodePort}" --arg method "${nodeMethod}" \
        '{source:"subscription",inboundTags:$inboundTags,subscription:{format:"sing-box-json",url:$url,selectedTag:$selectedTag},tcp:{mode:"relay",protocol:"shadowsocks",label:("Shadowsocks (" + $method + ")"),address:$address,port:$port,bbrProfile:""},udp:{mode:"shared",protocol:"shadowsocks",label:("Shadowsocks (" + $method + ")"),address:$address,port:$port,bbrProfile:""}}' \
        >/opt/xray-agent/relay_config.json
    chmod 600 /opt/xray-agent/relay_config.json "${configPath}relay_tcp_outbound.json"

    if ! validationOutput=$(/opt/xray-agent/xray/xray run -test -confdir "${configPath}" 2>&1); then
        echoContent red " ---> Xray 拒绝了订阅生成的配置，已恢复上一版"
        echoContent yellow "${validationOutput}"
        restoreRelayBackup "${backupDir}"
        rm -rf "${tempDir}"
        return 1
    fi
    rm -rf "${tempDir}"
    installCronRelaySubscription
    handleXray stop
    handleXray start
    echoContent green " ---> Shadowsocks 订阅中转已启用"
    echoContent yellow " ---> 上游: ${selectedTag} -> ${nodeAddress}:${nodePort}"
    echoContent yellow " ---> 已添加每日 04:17 自动更新任务"
}

# 非交互更新订阅中转。保留既有 inboundTags 和路由，只替换上游出站。
updateRelaySubscription() {
    local stateFile=/opt/xray-agent/relay_config.json
    [[ -f "${stateFile}" ]] || return 0
    [[ $(jq -r '.source // "manual"' "${stateFile}") == "subscription" ]] || return 0

    local lockFile=/opt/xray-agent/update-relay.lock
    exec 9>"${lockFile}"
    if command -v flock >/dev/null 2>&1 && ! flock -n 9; then
        echoContent yellow " ---> 中转订阅更新任务正在运行"
        return 0
    fi

    local subscriptionUrl selectedTag tempDir subscriptionFile outboundFile oldOutbound backupFile validationOutput
    subscriptionUrl=$(jq -r '.subscription.url' "${stateFile}")
    selectedTag=$(jq -r '.subscription.selectedTag' "${stateFile}")
    tempDir=$(mktemp -d /tmp/xray-relay-update.XXXXXX) || return 1
    subscriptionFile="${tempDir}/subscription.json"
    outboundFile="${tempDir}/relay_tcp_outbound.json"
    oldOutbound="${configPath}relay_tcp_outbound.json"

    fetchRelaySubscription "${subscriptionUrl}" "${subscriptionFile}" || {
        rm -rf "${tempDir}"
        return 1
    }
    if ! jq -e --arg tag "${selectedTag}" 'any(.outbounds[]?; .type == "shadowsocks" and .tag == $tag)' "${subscriptionFile}" >/dev/null; then
        selectedTag=$(jq -r 'first(.outbounds[]? | select(.type == "shadowsocks")) | .tag // empty' "${subscriptionFile}")
        if [[ -z "${selectedTag}" ]]; then
            echoContent red " ---> 更新后的订阅中没有 Shadowsocks 节点，保留旧配置"
            rm -rf "${tempDir}"
            return 1
        fi
        echoContent yellow " ---> 原节点已移除，自动切换到 ${selectedTag}"
    fi
    buildRelayOutboundFromSingBoxSubscription "${subscriptionFile}" "${selectedTag}" "relay_tcp_outbound" "${outboundFile}" || {
        echoContent red " ---> 新订阅的 Shadowsocks 节点无效，保留旧配置"
        rm -rf "${tempDir}"
        return 1
    }
    if [[ -f "${oldOutbound}" ]] && cmp -s "${outboundFile}" "${oldOutbound}"; then
        echoContent green " ---> 中转订阅没有变化"
        rm -rf "${tempDir}"
        return 0
    fi

    backupFile="${tempDir}/relay_tcp_outbound.backup.json"
    [[ -f "${oldOutbound}" ]] && cp "${oldOutbound}" "${backupFile}"
    mv "${outboundFile}" "${oldOutbound}"
    chmod 600 "${oldOutbound}"
    if ! validationOutput=$(/opt/xray-agent/xray/xray run -test -confdir "${configPath}" 2>&1); then
        [[ -f "${backupFile}" ]] && cp "${backupFile}" "${oldOutbound}"
        echoContent red " ---> 新订阅配置验证失败，已保留旧配置"
        echoContent yellow "${validationOutput}"
        rm -rf "${tempDir}"
        return 1
    fi

    local nodeAddress nodePort nodeMethod newState
    nodeAddress=$(jq -r --arg tag "${selectedTag}" 'first(.outbounds[] | select(.type == "shadowsocks" and .tag == $tag)).server' "${subscriptionFile}")
    nodePort=$(jq -r --arg tag "${selectedTag}" 'first(.outbounds[] | select(.type == "shadowsocks" and .tag == $tag)).server_port' "${subscriptionFile}")
    nodeMethod=$(jq -r --arg tag "${selectedTag}" 'first(.outbounds[] | select(.type == "shadowsocks" and .tag == $tag)).method' "${subscriptionFile}")
    newState=$(jq --arg tag "${selectedTag}" --arg address "${nodeAddress}" --arg port "${nodePort}" --arg method "${nodeMethod}" '
        .subscription.selectedTag = $tag |
        .tcp.label = ("Shadowsocks (" + $method + ")") | .tcp.address = $address | .tcp.port = $port |
        .udp.label = ("Shadowsocks (" + $method + ")") | .udp.address = $address | .udp.port = $port
    ' "${stateFile}") || {
        [[ -f "${backupFile}" ]] && cp "${backupFile}" "${oldOutbound}"
        rm -rf "${tempDir}"
        return 1
    }
    echo "${newState}" >"${stateFile}"
    chmod 600 "${stateFile}"
    rm -rf "${tempDir}"
    handleXray stop
    handleXray start
    echoContent green " ---> 中转订阅已更新: ${selectedTag} -> ${nodeAddress}:${nodePort}"
}

# 生成一个上游出站。第三个参数表示该出站是否承载 UDP。
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
    if ! validateRelayPort "${relayPort}"; then
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

# 追加/更新 TCP、UDP 中转规则。放在规则顶部，避免被通用分流提前截获。
addRelayRouting() {
    local inboundTags=$1 tcpOutboundTag=$2 udpOutboundTag=$3
    local routingFile="/opt/xray-agent/xray/conf/09_routing.json"
    [[ ! -f "${routingFile}" ]] && return 1

    local relayRules='[]'
    if [[ -n "${tcpOutboundTag}" ]]; then
        relayRules=$(jq -nc --argjson tags "${inboundTags}" --arg out "${tcpOutboundTag}" '[{type:"field",inboundTag:$tags,network:"tcp",outboundTag:$out}]')
    fi
    if [[ -n "${udpOutboundTag}" ]]; then
        relayRules=$(jq -c --argjson tags "${inboundTags}" --arg out "${udpOutboundTag}" '. + [{type:"field",inboundTag:$tags,network:"udp",outboundTag:$out}]' <<<"${relayRules}")
    fi

    local newConfig
    newConfig=$(jq --argjson rules "${relayRules}" '
        .routing.rules = ($rules + [.routing.rules[] | select(.outboundTag != "relay_outbound" and .outboundTag != "relay_tcp_outbound" and .outboundTag != "relay_udp_outbound")])' "${routingFile}") || return 1
    echo "${newConfig}" >"${routingFile}"
}

removeRelayRouting() {
    local routingFile="/opt/xray-agent/xray/conf/09_routing.json"
    [[ ! -f "${routingFile}" ]] && return
    local newConfig
    newConfig=$(jq 'del(.routing.rules[] | select(.outboundTag == "relay_outbound" or .outboundTag == "relay_tcp_outbound" or .outboundTag == "relay_udp_outbound"))' "${routingFile}")
    echo "${newConfig}" >"${routingFile}"
}

# 新配置验证失败时恢复更新前的中转文件与路由。
restoreRelayBackup() {
    local backupDir=$1 fileName
    rm -f "${configPath}relay_outbound.json" "${configPath}relay_tcp_outbound.json" "${configPath}relay_udp_outbound.json"
    rm -f /opt/xray-agent/relay_config /opt/xray-agent/relay_config.json
    for fileName in relay_outbound.json relay_tcp_outbound.json relay_udp_outbound.json; do
        [[ -f "${backupDir}/${fileName}" ]] && cp "${backupDir}/${fileName}" "${configPath}${fileName}"
    done
    [[ -f "${backupDir}/09_routing.json" ]] && cp "${backupDir}/09_routing.json" "${configPath}09_routing.json"
    [[ -f "${backupDir}/relay_config" ]] && cp "${backupDir}/relay_config" /opt/xray-agent/relay_config
    [[ -f "${backupDir}/relay_config.json" ]] && cp "${backupDir}/relay_config.json" /opt/xray-agent/relay_config.json
}

# 配置中转：入站可多选，TCP 默认走上游，UDP 可选择是否跟随。
setupRelayManual() {
    if [[ -z "${configPath}" ]]; then
        echoContent red " ---> 未安装，请使用脚本安装"
        menu
        return
    fi

    echoContent skyBlue "\n配置链式代理"
    echoContent yellow "# 路径：用户 → 本机入站 → 上游节点 → 目标"
    echoContent yellow "# 所选入站的 TCP 默认走上游，本机 nginx 流量不受影响\n"
    selectRelayInbounds || return

    local tcpMode="relay" udpMode="direct" udpRelayStatus
    read -r -p "UDP 也通过上游转发吗？[y/N]:" udpRelayStatus
    [[ "${udpRelayStatus}" =~ ^[Yy]$ ]] && udpMode="shared"

    local tempDir tcpTemp backupDir
    tempDir=$(mktemp -d /tmp/xray-relay.XXXXXX) || return
    tcpTemp="${tempDir}/relay_tcp_outbound.json"
    backupDir="${tempDir}/backup"
    mkdir -p "${backupDir}"
    local tcpProtocol="" tcpLabel="直连" tcpAddress="" tcpPort=""
    local udpProtocol="" udpLabel="直连" udpAddress="" udpPort=""
    local tcpBbrProfile="" udpBbrProfile=""

    buildRelayOutbound "relay_tcp_outbound" "${tcpTemp}" "$([[ "${udpMode}" == "shared" ]] && echo true || echo false)" || {
        rm -rf "${tempDir}"
        return
    }
    tcpProtocol=${relayBuiltProtocol}
    tcpLabel=${relayBuiltLabel}
    tcpAddress=${relayBuiltAddress}
    tcpPort=${relayBuiltPort}
    tcpBbrProfile=${relayBuiltBbrProfile}

    if [[ "${udpMode}" == "shared" ]]; then
        udpProtocol=${tcpProtocol}
        udpLabel=${tcpLabel}
        udpAddress=${tcpAddress}
        udpPort=${tcpPort}
        udpBbrProfile=${tcpBbrProfile}
    fi

    # 只在所有输入都验证成功后替换现有配置，并保留可回滚副本。
    local backupFile
    for backupFile in relay_outbound.json relay_tcp_outbound.json relay_udp_outbound.json 09_routing.json; do
        [[ -f "${configPath}${backupFile}" ]] && cp "${configPath}${backupFile}" "${backupDir}/${backupFile}"
    done
    [[ -f /opt/xray-agent/relay_config ]] && cp /opt/xray-agent/relay_config "${backupDir}/relay_config"
    [[ -f /opt/xray-agent/relay_config.json ]] && cp /opt/xray-agent/relay_config.json "${backupDir}/relay_config.json"

    rm -f "${configPath}relay_outbound.json" "${configPath}relay_tcp_outbound.json" "${configPath}relay_udp_outbound.json"
    [[ -f "${tcpTemp}" ]] && mv "${tcpTemp}" "${configPath}relay_tcp_outbound.json"

    local tcpOutboundTag="relay_tcp_outbound" udpOutboundTag=""
    if [[ "${udpMode}" == "shared" ]]; then
        udpOutboundTag="relay_tcp_outbound"
    fi
    addRelayRouting "${relaySelectedInboundTags}" "${tcpOutboundTag}" "${udpOutboundTag}" || {
        echoContent red " ---> 中转路由生成失败"
        restoreRelayBackup "${backupDir}"
        rm -rf "${tempDir}"
        return
    }

    jq -n --argjson inboundTags "${relaySelectedInboundTags}" \
        --arg tcpMode "${tcpMode}" --arg tcpProtocol "${tcpProtocol}" --arg tcpLabel "${tcpLabel}" --arg tcpAddress "${tcpAddress}" --arg tcpPort "${tcpPort}" --arg tcpBbrProfile "${tcpBbrProfile}" \
        --arg udpMode "${udpMode}" --arg udpProtocol "${udpProtocol}" --arg udpLabel "${udpLabel}" --arg udpAddress "${udpAddress}" --arg udpPort "${udpPort}" --arg udpBbrProfile "${udpBbrProfile}" \
        '{inboundTags:$inboundTags,tcp:{mode:$tcpMode,protocol:$tcpProtocol,label:$tcpLabel,address:$tcpAddress,port:$tcpPort,bbrProfile:$tcpBbrProfile},udp:{mode:$udpMode,protocol:$udpProtocol,label:$udpLabel,address:$udpAddress,port:$udpPort,bbrProfile:$udpBbrProfile}}' \
        >"/opt/xray-agent/relay_config.json"
    rm -f /opt/xray-agent/relay_config

    local validationOutput
    if ! validationOutput=$(/opt/xray-agent/xray/xray run -test -confdir "${configPath}" 2>&1); then
        echoContent red " ---> Xray 拒绝了新中转配置，已自动恢复上一版"
        echoContent yellow "${validationOutput}"
        restoreRelayBackup "${backupDir}"
        rm -rf "${tempDir}"
        return
    fi
    rm -rf "${tempDir}"

    handleXray stop
    handleXray start
    removeCronRelaySubscription
    echo
    echoContent green " ---> 链式代理已启用！"
    echoContent yellow " ---> 入站: $(jq -r '.inboundTags | join(", ")' /opt/xray-agent/relay_config.json)"
    echoContent yellow " ---> TCP: ${tcpLabel}${tcpAddress:+ → ${tcpAddress}:${tcpPort}}${tcpBbrProfile:+ [BBR/${tcpBbrProfile}]}"
    echoContent yellow " ---> UDP: ${udpLabel}${udpAddress:+ → ${udpAddress}:${udpPort}}${udpBbrProfile:+ [BBR/${udpBbrProfile}]}"
}

setupRelay() {
    echoContent skyBlue "\n请选择上游配置来源"
    echoContent yellow "1.sing-box JSON 订阅中的 Shadowsocks 节点"
    echoContent yellow "2.手动输入上游节点"
    local relaySource
    read -r -p "请选择:" relaySource
    case ${relaySource} in
    1) setupRelaySubscription ;;
    2) setupRelayManual ;;
    *) echoContent red " ---> 请输入 1-2" ;;
    esac
}

showRelayConfig() {
    local stateFile="/opt/xray-agent/relay_config.json"
    if [[ ! -f "${stateFile}" ]]; then
        if [[ -f "/opt/xray-agent/xray/conf/relay_outbound.json" ]]; then
            echoContent yellow " ---> 检测到旧版 Vision 中转配置，请选择“启用 / 更新中转”进行迁移"
        else
            echoContent yellow " ---> 当前未配置中转"
        fi
        return
    fi
    echoContent skyBlue "\n当前链式代理配置"
    echoContent red "=============================================================="
    echoContent yellow "入站: $(jq -r '.inboundTags | join(", ")' "${stateFile}")"
    echoContent yellow "TCP : $(jq -r 'if .tcp.mode == "direct" then "直连" else (.tcp.label + " -> " + .tcp.address + ":" + .tcp.port + if (.tcp.bbrProfile // "") != "" then " [BBR/" + .tcp.bbrProfile + "]" else "" end) end' "${stateFile}")"
    echoContent yellow "UDP : $(jq -r 'if .udp.mode == "direct" then "直连" else (.udp.label + " -> " + .udp.address + ":" + .udp.port + if (.udp.bbrProfile // "") != "" then " [BBR/" + .udp.bbrProfile + "]" else "" end) end' "${stateFile}")"
    echoContent red "=============================================================="
}

removeRelay() {
    rm -f "${configPath}relay_outbound.json" "${configPath}relay_tcp_outbound.json" "${configPath}relay_udp_outbound.json"
    rm -f /opt/xray-agent/relay_config /opt/xray-agent/relay_config.json
    removeCronRelaySubscription
    removeRelayRouting
    handleXray stop
    handleXray start
    echoContent green " ---> 链式代理已停用，相关入站恢复原有出站"
}

manageRelay() {
    if [[ -z "${configPath}" ]]; then
        echoContent red " ---> 未安装，请使用脚本安装"
        menu
        return
    fi

    local relayStatus relayType
    while true; do
        relayStatus="未启用"
        [[ -f "/opt/xray-agent/relay_config.json" ]] && relayStatus="已启用"
        [[ -f "${configPath}relay_outbound.json" && ! -f "/opt/xray-agent/relay_config.json" ]] && relayStatus="已启用（旧版，待迁移）"

        echoContent skyBlue "\n功能 1/${totalProgress} : 中转管理"
        echoContent red "\n=============================================================="
        echoContent yellow "# 可多选本机已安装的入站协议"
        echoContent yellow "# 所选入站的 TCP 默认走上游，UDP 可选择是否跟随"
        echoContent yellow "# 当前状态: ${relayStatus}\n"
        echoContent yellow "1.启用中转"
        echoContent yellow "2.查看当前配置"
        if [[ -f "/opt/xray-agent/relay_config.json" ]] && [[ $(jq -r '.source // "manual"' /opt/xray-agent/relay_config.json) == "subscription" ]]; then
            echoContent yellow "3.立即更新中转订阅"
        fi
        echoContent yellow "4.停用中转"
        echoContent yellow "0.返回主菜单"
        echoContent red "=============================================================="
        read -r -p "请选择:" relayType

        case ${relayType} in
        1) setupRelay ;;
        2) showRelayConfig ;;
        3)
            if [[ -f "/opt/xray-agent/relay_config.json" ]] && [[ $(jq -r '.source // "manual"' /opt/xray-agent/relay_config.json) == "subscription" ]]; then
                updateRelaySubscription
            else
                echoContent red " ---> 当前中转不是订阅模式"
            fi
            ;;
        4) removeRelay ;;
        0)
            menu
            return
            ;;
        *) echoContent red " ---> 请输入 0-4" ;;
        esac
        read -r -p "按回车键继续..."
    done
}
# ==================== 分流工具 ====================

# 分流工具
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
# SNI反向代理分流
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
# 设置SNI分流
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
            handleXray stop
            handleXray start
        else
            echoContent red " ---> 域名不可为空"
        fi

    else

        echoContent red " ---> SNI IP不可为空"
    fi
    exit 0
}

# 添加xray dns 配置
addXrayDNSConfig() {
    local ip=$1
    local domainList=$2
    local domains=[]
    while read -r line; do
        local geositeStatus
        geositeStatus=$(curl -s "https://api.github.com/repos/v2fly/domain-list-community/contents/data/${line}" | jq .message)

        if [[ "${geositeStatus}" == "null" ]]; then
            domains=$(echo "${domains}" | jq -r '. += ["geosite:'"${line}"'"]')
        else
            domains=$(echo "${domains}" | jq -r '. += ["domain:'"${line}"'"]')
        fi
    done < <(echo "${domainList}" | tr ',' '\n')

    if [[ "${coreInstallType}" == "1" ]]; then

        cat <<EOF >${configPath}11_dns.json
{
    "dns": {
        "servers": [
            {
                "address": "${ip}",
                "port": 53,
                "domains": ${domains}
            },
        "localhost"
        ]
    }
}
EOF
    fi
}

setUnlockDNS() {
    read -r -p "请输入分流的DNS:" setDNS
    if [[ -n ${setDNS} ]]; then
        echoContent red "=============================================================="
        echoContent yellow "录入示例:netflix,disney,hulu"
        read -r -p "请按照上面示例录入域名:" domainList

        if [[ "${coreInstallType}" == "1" ]]; then
            addXrayDNSConfig "${setDNS}" "${domainList}"
        fi


        handleXray stop
        handleXray start

        echoContent yellow "\n ---> 如还无法观看可以尝试以下两种方案"
        echoContent yellow " 1.重启vps"
        echoContent yellow " 2.卸载dns解锁后，修改本地的[/etc/resolv.conf]DNS设置并重启vps\n"
    else
        echoContent red " ---> dns不可为空"
    fi
    exit 0
}

# 移除 DNS分流
removeUnlockDNS() {
    if [[ "${coreInstallType}" == "1" && -f "${configPath}11_dns.json" ]]; then
        cat <<EOF >${configPath}11_dns.json
{
	"dns": {
		"servers": [
			"localhost"
		]
	}
}
EOF
    fi


    handleXray stop
    handleXray start

    echoContent green " ---> 卸载成功"

    exit 0
}

# 移除SNI分流
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
    handleXray stop
    handleXray start

    echoContent green " ---> 卸载成功"

    exit 0
}

# Xray-core个性化安装
mapInstallMenuSelection() {
    local menuSelection=${1//[[:space:]]/}
    [[ "${menuSelection}" =~ ^[1-4](,[1-4])*$ ]] || return 1

    local mappedSelection= menuItem protocolId
    local -a menuItems=()
    IFS=',' read -r -a menuItems <<<"${menuSelection}"
    for menuItem in "${menuItems[@]}"; do
        case "${menuItem}" in
        1) protocolId=0 ;;
        2) protocolId=1 ;;
        3) protocolId=3 ;;
        4) protocolId=6 ;;
        *) return 1 ;;
        esac
        if [[ ",${mappedSelection}," != *",${protocolId},"* ]]; then
            mappedSelection="${mappedSelection:+${mappedSelection},}${protocolId}"
        fi
    done

    # WS 与 Hysteria2 的组合安装沿用 Vision 作为 TLS 前置；Reality 可单独安装。
    if [[ "${mappedSelection}" != "3" && ",${mappedSelection}," != *",0,"* ]]; then
        mappedSelection="0,${mappedSelection}"
    fi
    printf ',%s,\n' "${mappedSelection}"
}

customXrayInstall() {
    echoContent skyBlue "\n========================个性化安装============================"
    echoContent yellow "1.VLESS+TLS Vision+TCP[推荐]"
    echoContent yellow "2.VLESS+TLS+WebSocket[仅CDN推荐]"
    echoContent yellow "3.VLESS+Reality+uTLS+Vision[可单独安装]"
    echoContent yellow "4.Hysteria2+TLS+QUIC[UDP/游戏推荐]"
    echoContent green "提示：选择WebSocket或Hysteria2时会自动包含TLS Vision前置"
    local installMenuSelection=
    read -r -p "请选择[多选]，[例如:1,2,4]:" installMenuSelection
    echoContent skyBlue "--------------------------------------------------------------"
    if echo "${installMenuSelection}" | grep -q "，"; then
        echoContent red " ---> 请使用英文逗号分隔"
        exit 0
    fi
    if ! selectCustomInstallType=$(mapInstallMenuSelection "${installMenuSelection}"); then
        echoContent red " ---> 输入不合法，请使用1-4并以英文逗号分隔"
        customXrayInstall
        return
    fi

    if [[ "${selectCustomInstallType//,/}" =~ ^[0136]+$ ]]; then
        readLastInstallationConfig
        unInstallSubscribe
        checkBTPanel
        check1Panel
        checkHestiaPanel
        totalProgress=12
        installTools 1
        if [[ -n "${btDomain}" ]]; then
            echoContent skyBlue "\n进度  3/${totalProgress} : 检测到宝塔面板/1Panel/HestiaCP，跳过申请TLS步骤"
            handleXray stop
            if [[ "${selectCustomInstallType}" != ",3," ]]; then
                customPortFunction
            fi
        else
            # 申请tls
            if [[ "${selectCustomInstallType}" != ",3," ]]; then
                initTLSNginxConfig 2
                handleXray stop
                installTLS 3
            else
                echoContent skyBlue "\n进度  2/${totalProgress} : 检测到仅安装Reality，跳过TLS证书步骤"
            fi
        fi

        handleNginx stop
        # 随机path
        if echo "${selectCustomInstallType}" | grep -q ",1,"; then
            randomPathFunction 4
        fi
        if [[ -n "${btDomain}" ]]; then
            echoContent skyBlue "\n进度  6/${totalProgress} : 检测到宝塔面板/1Panel/HestiaCP，跳过伪装网站"
        else
            nginxBlog 6
        fi
        if [[ "${selectCustomInstallType}" != ",3," ]]; then
            if ! updateRedirectNginxConf; then
                echoContent red " ---> 无法生成Nginx配置，已中止安装并尝试恢复Nginx"
                handleNginx start
                return 1
            fi
            handleNginx start
        fi

        # 安装Xray
        installXray 7 false
        installXrayService 8
        initXrayConfig custom 9
        if [[ "${selectCustomInstallType}" != ",3," ]]; then
            installCronTLS 10
        fi

        handleXray stop
        handleXray start
        # 生成账号
        checkGFWStatue 11
        showAccounts 12
    else
        echoContent red " ---> 输入不合法"
        customXrayInstall
    fi
}


selectCoreInstall() {
    # 现在只支持 Xray-core，直接进入安装
    if [[ "${selectInstallType}" == "2" ]]; then
        customXrayInstall
    else
        xrayCoreInstall
    fi
}

# xray-core 安装
xrayCoreInstall() {
    readLastInstallationConfig
    unInstallSubscribe
    checkBTPanel
    check1Panel
    checkHestiaPanel
    selectCustomInstallType=
    totalProgress=12
    installTools 2
    if [[ -n "${btDomain}" ]]; then
        echoContent skyBlue "\n进度  3/${totalProgress} : 检测到宝塔面板/1Panel/HestiaCP，跳过申请TLS步骤"
        handleXray stop
        customPortFunction
    else
        # 申请tls
        initTLSNginxConfig 3
        handleXray stop
        installTLS 4
    fi

    handleNginx stop
    randomPathFunction 5

    # 安装Xray
    installXray 6 false
    installXrayService 7
    initXrayConfig all 8
    installCronTLS 9
    if [[ -n "${btDomain}" ]]; then
        echoContent skyBlue "\n进度  11/${totalProgress} : 检测到宝塔面板/1Panel/HestiaCP，跳过伪装网站"
    else
        nginxBlog 10
    fi
    if ! updateRedirectNginxConf; then
        echoContent red " ---> 无法生成Nginx配置，已中止安装并尝试恢复Nginx"
        handleNginx start
        return 1
    fi
    handleXray stop
    sleep 2
    handleXray start

    handleNginx start
    # 生成账号
    checkGFWStatue 11
    showAccounts 12
}

# 核心管理
coreVersionManageMenu() {

    if [[ -z "${coreInstallType}" ]]; then
        echoContent red "\n ---> 没有检测到安装目录，请执行脚本安装内容"
        menu
        exit 0
    fi
    # 现在只支持 Xray-core，直接进入版本管理
    xrayVersionManageMenu 1
}
# 定时任务检查
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
# 账号管理
manageAccount() {
    echoContent skyBlue "\n功能 1/${totalProgress} : 账号管理"
    if [[ -z "${configPath}" ]]; then
        echoContent red " ---> 未安装"
        exit 0
    fi

    echoContent red "\n=============================================================="
    echoContent yellow "# 添加单个用户时可自定义email和uuid"
    echoContent yellow "# 如安装了Hysteria2，账号会同步添加到Hysteria2入站\n"
    echoContent yellow "1.查看账号"
    echoContent yellow "2.查看订阅"
    echoContent yellow "3.管理其他订阅"
    echoContent yellow "4.添加用户"
    echoContent yellow "5.删除用户"
    echoContent red "=============================================================="
    read -r -p "请输入:" manageAccountStatus
    if [[ "${manageAccountStatus}" == "1" ]]; then
        showAccounts 1
    elif [[ "${manageAccountStatus}" == "2" ]]; then
        subscribe
    elif [[ "${manageAccountStatus}" == "3" ]]; then
        addSubscribeMenu 1
    elif [[ "${manageAccountStatus}" == "4" ]]; then
        addUser
    elif [[ "${manageAccountStatus}" == "5" ]]; then
        removeUser
    else
        echoContent red " ---> 选择错误"
    fi
}
# 安装订阅
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

        if ! echo "${selectCustomInstallType}" | grep -qE ",0,|,1,|,3,|,6," && ! echo "${currentInstallProtocolType}" | grep -qE ",0,|,1,|,3,|,6," && [[ -z "${domain}" ]]; then
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
# 卸载订阅
unInstallSubscribe() {
    rm -rf ${nginxConfigPath}subscribe.conf >/dev/null 2>&1
}

# 添加订阅
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
# 添加其他机器clashMeta订阅
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
# clashMeta配置文件
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
# 随机salt
initRandomSalt() {
    local chars="abcdefghijklmnopqrtuxyz"
    local initCustomPath=
    for i in {1..10}; do
        echo "${i}" >/dev/null
        initCustomPath+="${chars:RANDOM%${#chars}:1}"
    done
    echo "${initCustomPath}"
}
# 订阅
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
                    echoContent yellow "在线二维码:https://api-qr-server.zew9.com/v1/create-qr-code/?size=400x400&data=${subscribeType}://${currentDomain}/s/default/${emailMd5}\n"
                    echo "${subscribeType}://${currentDomain}/s/default/${emailMd5}" | qrencode -s 10 -m 1 -t UTF8

                    # clashMeta
                    if [[ -f "/opt/xray-agent/subscribe_local/clashMeta/${email}" ]]; then

                        cat "/opt/xray-agent/subscribe_local/clashMeta/${email}" >>"/opt/xray-agent/subscribe/clashMeta/${emailMd5}"

                        sed -i '1i\proxies:' "/opt/xray-agent/subscribe/clashMeta/${emailMd5}"

                        local clashProxyUrl="${subscribeType}://${currentDomain}/s/clashMeta/${emailMd5}"
                        clashMetaConfig "${clashProxyUrl}" "${emailMd5}"
                        echoContent skyBlue "\n----------clashMeta订阅----------\n"
                        echoContent yellow "url:${subscribeType}://${currentDomain}/s/clashMetaProfiles/${emailMd5}\n"
                        echoContent yellow "在线二维码:https://api-qr-server.zew9.com/v1/create-qr-code/?size=400x400&data=${subscribeType}://${currentDomain}/s/clashMetaProfiles/${emailMd5}\n"
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

# 更新远程订阅
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

        clashMetaProxies=$(curl -s "${subscribeType}://${remoteUrl}/s/clashMeta/${emailMD5}" | sed '/proxies:/d' | sed "s/\"${email}/\"${email}_${serverAlias}/g")

        if ! echo "${clashMetaProxies}" | grep -q "nginx" && [[ -n "${clashMetaProxies}" ]]; then
            echo "${clashMetaProxies}" >>"/opt/xray-agent/subscribe/clashMeta/${emailMD5}"
            echoContent green " ---> clashMeta订阅 ${remoteUrl}:${email} 更新成功"
        else
            echoContent red " ---> clashMeta订阅 ${remoteUrl}:${email}不存在"
        fi

        local default=
        default=$(curl -s "${subscribeType}://${remoteUrl}/s/default/${emailMD5}")

        if ! echo "${default}" | grep -q "nginx" && [[ -n "${default}" ]]; then
            default=$(echo "${default}" | base64 -d | sed "s/#${email}/#${email}_${serverAlias}/g")
            echo "${default}" >>"/opt/xray-agent/subscribe/default/${emailMD5}"

            echoContent green " ---> 通用订阅 ${remoteUrl}:${email} 更新成功"
        else
            echoContent red " ---> 通用订阅 ${remoteUrl}:${email} 不存在"
        fi

    done < <(grep -v '^$' <"/opt/xray-agent/subscribe_remote/remoteSubscribeUrl")
}

# 初始化realityKey
initRealityKey() {
    echoContent skyBlue "\n================ 生成 Reality 密钥对 ===============\n"
    echoContent yellow "📌 Reality 密钥说明："
    echoContent white "   • Private Key (私钥): 服务器端使用，必须保密"
    echoContent white "   • Public Key (公钥):  客户端使用，可以公开"
    echoContent white "   • 基于 X25519 椭圆曲线算法\n"
    
    # 总是询问是否使用上次密钥对，不管lastInstallationConfig的值
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
        realityPrivateKey=$(echo "${realityX25519Key}" | grep "PrivateKey" | awk '{print $2}')
        realityPublicKey=$(echo "${realityX25519Key}" | grep "Password" | awk '{print $2}')
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
# 初始化 mldsa65Seed
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
                #        fi
            fi
            #    echoContent green "\n Seed:${realityMldsa65Seed}"
            #    echoContent green "\n Verify:${realityMldsa65Verify}"
        else
            echoContent green " 目标域名支持X25519MLKEM768，但是证书的长度不足，忽略ML-DSA-65。"
        fi
    else
        echoContent green " 目标域名不支持X25519MLKEM768，忽略ML-DSA-65。"
    fi
}
# 检查reality域名是否符合
checkRealityDest() {
    local traceResult=
    traceResult=$(curl -s "https://$(echo "${realityDestDomain}" | cut -d ':' -f 1)/cdn-cgi/trace" | grep "visit_scheme=https")
    if [[ -n "${traceResult}" ]]; then
        echoContent red "\n ---> 检测到使用的域名，托管在cloudflare并开启了代理，使用此类型域名可能导致VPS流量被其他人使用[不建议使用]\n"
        read -r -p "是否继续 ？[y/n]" setRealityDestStatus
        if [[ "${setRealityDestStatus}" != 'y' ]]; then
            exit 0
        fi
        echoContent yellow "\n ---> 忽略风险，继续使用"
    fi
}

# 初始化客户端可用的ServersName
initRealityClientServersName() {
    local realityDestDomainList="gateway.icloud.com,itunes.apple.com,swdist.apple.com,swcdn.apple.com,updates.cdn-apple.com,mensura.cdn-apple.com,osxapps.itunes.apple.com,aod.itunes.apple.com,download-installer.cdn.mozilla.net,addons.mozilla.org,s0.awsstatic.com,d1.awsstatic.com,images-na.ssl-images-amazon.com,m.media-amazon.com,player.live-video.net,one-piece.com,lol.secure.dyn.riotcdn.net,www.swift.com,academy.nvidia.com,www.cisco.com,www.asus.com,www.samsung.com,www.amd.com,cdn-dynmedia-1.microsoft.com,software.download.prss.microsoft.com,dl.google.com,www.google-analytics.com"
    # 总是询问是否使用上次域名，不管lastInstallationConfig的值
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
# 初始化reality端口
initXrayRealityPort() {
    # 总是询问是否使用上次端口，不管lastInstallationConfig的值
    if [[ -n "${xrayVLESSRealityPort}" ]]; then
        read -r -p "读取到上次安装记录，是否使用上次安装时的端口 ？[y/n]:" historyRealityPortStatus
        if [[ "${historyRealityPortStatus}" == "y" ]]; then
            realityPort=${xrayVLESSRealityPort}
        fi
    fi

    if [[ -z "${realityPort}" ]]; then
        #        if [[ -n "${port}" ]]; then
        #            read -r -p "是否使用TLS+Vision端口 ？[y/n]:" realityPortTLSVisionStatus
        #            if [[ "${realityPortTLSVisionStatus}" == "y" ]]; then
        #                realityPort=${port}
        #            fi
        #        fi
        #        if [[ -z "${realityPort}" ]]; then
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
        #        fi
        if [[ -n "${realityPort}" && "${xrayVLESSRealityPort}" == "${realityPort}" ]]; then
            handleXray stop
        else
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
# reality管理
manageReality() {
    readInstallProtocolType
    readConfigHostPathUUID
    readCustomPort

    if ! echo "${currentInstallProtocolType}" | grep -q ",3," || [[ -z "${coreInstallType}" ]]; then
        echoContent red "\n ---> 请先安装Reality协议"
        exit 0
    fi

    selectCustomInstallType=",3,"
    initXrayConfig custom 1 true

    handleXray stop
    handleXray start
    subscribe false
}

# 安装reality scanner
installRealityScanner() {
    if [[ ! -f "/opt/xray-agent/xray/reality_scan/RealiTLScanner-linux-64" ]]; then
        version=$(curl -s https://api.github.com/repos/XTLS/RealiTLScanner/releases?per_page=1 | jq -r '.[]|.tag_name')
        if ! downloadFile "https://github.com/XTLS/RealiTLScanner/releases/download/${version}/RealiTLScanner-linux-64" "/opt/xray-agent/xray/reality_scan/RealiTLScanner-linux-64"; then
            echoContent red " ---> Reality Scanner 下载失败"
            return 1
        fi
        chmod 755 /opt/xray-agent/xray/reality_scan/RealiTLScanner-linux-64
    fi
}
# reality scanner
realityScanner() {
    echoContent skyBlue "\n进度 1/1 : 扫描Reality域名"
    echoContent red "\n=============================================================="
    echoContent yellow "# 注意事项"
    echoContent yellow "扫描完成后，请自行检查扫描网站结果内容是否合规，需个人承担风险"
    echoContent red "某些IDC不允许扫描操作，比如搬瓦工，其中风险请自行承担\n"
    echoContent yellow "1.扫描IPv4"
    echoContent yellow "2.扫描IPv6"
    echoContent red "=============================================================="
    read -r -p "请选择:" realityScannerStatus
    local type=
    if [[ "${realityScannerStatus}" == "1" ]]; then
        type=4
    elif [[ "${realityScannerStatus}" == "2" ]]; then
        type=6
    fi

    read -r -p "某些IDC不允许扫描操作，比如搬瓦工，其中风险请自行承担，是否继续？[y/n]:" scanStatus

    if [[ "${scanStatus}" != "y" ]]; then
        exit 0
    fi

    publicIP=$(getPublicIP "${type}")
    echoContent yellow "IP:${publicIP}"
    if [[ -z "${publicIP}" ]]; then
        echoContent red " ---> 无法获取IP"
        exit 0
    fi

    read -r -p "IP是否正确？[y/n]:" ipStatus
    if [[ "${ipStatus}" == "y" ]]; then
        echoContent yellow "结果存储在 /opt/xray-agent/xray/reality_scan/result.log 文件中\n"
        /opt/xray-agent/xray/reality_scan/RealiTLScanner-linux-64 -addr "${publicIP}" | tee /opt/xray-agent/xray/reality_scan/result.log
    else
        echoContent red " ---> 无法读取正确IP"
    fi
}
# hysteria管理
setHysteria2BbrProfile() {
    local profile=$1
    local hysteriaConfig="${configPath}05_hysteria2_inbounds.json"
    local tempConfig=
    local backupConfig=
    local validationOutput=

    [[ "${profile}" =~ ^(conservative|standard|aggressive)$ ]] || return 1
    if [[ ! -f "${hysteriaConfig}" ]]; then
        echoContent red " ---> 未安装Hysteria2"
        return 1
    fi

    tempConfig=$(mktemp "${hysteriaConfig}.tmp.XXXXXX") || return 1
    if ! jq --arg profile "${profile}" '
        .inbounds[0].streamSettings.finalmask //= {} |
        .inbounds[0].streamSettings.finalmask.quicParams //= {} |
        .inbounds[0].streamSettings.finalmask.quicParams.congestion = "bbr" |
        .inbounds[0].streamSettings.finalmask.quicParams.bbrProfile = $profile
    ' "${hysteriaConfig}" >"${tempConfig}"; then
        rm -f "${tempConfig}"
        echoContent red " ---> Hysteria2配置更新失败"
        return 1
    fi

    backupConfig=$(mktemp "${hysteriaConfig}.bak.XXXXXX") || {
        rm -f "${tempConfig}"
        return 1
    }
    if ! cp "${hysteriaConfig}" "${backupConfig}"; then
        rm -f "${tempConfig}" "${backupConfig}"
        echoContent red " ---> Hysteria2配置备份失败"
        return 1
    fi
    chmod --reference="${hysteriaConfig}" "${tempConfig}" 2>/dev/null || chmod 644 "${tempConfig}"
    if ! mv "${tempConfig}" "${hysteriaConfig}"; then
        rm -f "${tempConfig}" "${backupConfig}"
        echoContent red " ---> Hysteria2配置保存失败"
        return 1
    fi

    if ! validationOutput=$(/opt/xray-agent/xray/xray run -test -confdir "${configPath}" 2>&1); then
        mv "${backupConfig}" "${hysteriaConfig}"
        echoContent red " ---> Xray拒绝了新配置，已自动恢复"
        echoContent yellow "${validationOutput}"
        return 1
    fi

    rm -f "${backupConfig}"
    handleXray stop
    handleXray start
    hysteria2BbrProfile=${profile}
    echoContent green " ---> Hysteria2 QUIC拥塞控制已切换为: BBR/${profile}"
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
        echoContent green "# 此处调整本机Hysteria2入站；链式上游在中转管理中单独设置"
        echoContent yellow "1.切换为 conservative [低抖动/保守]"
        echoContent yellow "2.切换为 standard [均衡/推荐]"
        echoContent yellow "3.切换为 aggressive [吞吐优先]"
        echoContent yellow "0.返回主菜单"
        echoContent red "========================================================="
        read -r -p "请选择:" manageChoice

        case ${manageChoice} in
        1) setHysteria2BbrProfile conservative ;;
        2) setHysteria2BbrProfile standard ;;
        3) setHysteria2BbrProfile aggressive ;;
        0) return ;;
        *) echoContent red " ---> 请输入 0-3" ;;
        esac
    done
}


# 主菜单
menu() {
    cd "$HOME" || exit
    echoContent red "\n=============================================================="
    echoContent green "当前版本：v2026.07.18.1784356807"
    echoContent green "描述：Xray 一键安装管理脚本\c"
    showInstallStatus
    checkWgetShowProgress
    echoContent skyBlue "快捷命令：xraya"
    echoContent red "\n=============================================================="
    if [[ -n "${coreInstallType}" ]]; then
        echoContent yellow "1.重新安装"
    else
        echoContent yellow "1.安装"
    fi

    echoContent yellow "2.任意组合安装"
    echoContent yellow "3.REALITY管理"

    echoContent skyBlue "-------------------------工具管理-----------------------------"
    echoContent yellow "4.用户管理"
    echoContent yellow "5.伪装站管理"
    echoContent yellow "6.证书管理"
    echoContent yellow "7.分流工具"
    echoContent yellow "8.添加新端口"
    echoContent yellow "9.Hysteria2管理"
    echoContent skyBlue "-------------------------版本管理-----------------------------"
    echoContent yellow "10.Xray版本管理"
    echoContent yellow "11.更新脚本"
    echoContent skyBlue "-------------------------脚本管理-----------------------------"
    echoContent yellow "12.卸载脚本"
    echoContent skyBlue "-------------------------中转管理-----------------------------"
    echoContent yellow "13.中转管理（链式代理）"
    echoContent red "=============================================================="
    mkdirTools
    aliasInstall
    read -r -p "请选择:" selectInstallType
    case ${selectInstallType} in
    1)
        selectCoreInstall
        ;;
    2)
        selectCoreInstall
        ;;
    3)
        manageReality 1
        ;;
    4)
        manageAccount 1
        ;;
    5)
        updateNginxBlog 1
        ;;
    6)
        renewalTLS 1
        ;;
    7)
        routingToolsMenu 1
        ;;
    8)
        addCorePort 1
        ;;
    9)
        manageHysteria2
        ;;
    10)
        coreVersionManageMenu 1
        ;;
    11)
        updateXrayAgent 1
        ;;
    12)
        unInstall 1
        ;;
    13)
        manageRelay 1
        ;;
    esac
}

# ===== Entry Point =====
cronFunction
menu
