#!/usr/bin/env bash
# 模块 02：面板检测、防火墙与配置读取

checkBTPanel() {
    if [[ -n $(pgrep -f "BT-Panel") ]]; then
        # 读取域名
        if [[ -d '/www/server/panel/vhost/nginx/' ]] && [[ -n $(find /www/server/panel/vhost/nginx -maxdepth 1 -name "*.conf" ! -name "xray-agent.conf" ! -name "phpmyadmin.conf") ]]; then
            local -a btDomains=()
            mapfile -t btDomains < <(find /www/server/panel/vhost/nginx -maxdepth 1 -name "*.conf" ! -name "xray-agent.conf" ! -name "phpmyadmin.conf" -printf "%f\n" 2>/dev/null | sed 's/\.conf$//' | sort)
            local btDomainCount=${#btDomains[@]}
            if ((btDomainCount == 0)); then
                return
            fi

            if [[ -z "${currentHost}" ]]; then
                echoContent skyBlue "\n读取宝塔配置\n"

                local displayIndex
                for ((displayIndex = 0; displayIndex < btDomainCount; displayIndex++)); do
                    local printIndex=$((displayIndex + 1))
                    echo "${printIndex}:${btDomains[displayIndex]}"
                done

                read -r -p "请输入编号选择:" selectBTDomain
            else
                local displayIndex
                for ((displayIndex = 0; displayIndex < btDomainCount; displayIndex++)); do
                    if [[ "${btDomains[displayIndex]}" == "${currentHost}" ]]; then
                        selectBTDomain=$((displayIndex + 1))
                        break
                    fi
                done
            fi

            if [[ -n "${selectBTDomain}" && "${selectBTDomain}" =~ ^[0-9]+$ ]]; then
                local selectedIndex=$((selectBTDomain - 1))
                if ((selectedIndex < 0 || selectedIndex >= btDomainCount)); then
                    echoContent red " ---> 选择错误，请重新选择"
                    checkBTPanel
                else
                    btDomain=${btDomains[selectedIndex]}
                    domain=${btDomain}
                    local btConfFile="/www/server/panel/vhost/nginx/${btDomain}.conf"
                    local certFile=
                    local keyFile=
                    certFile=$(awk '$1 == "ssl_certificate" {gsub(/;/, "", $2); print $2; exit}' "${btConfFile}" 2>/dev/null)
                    keyFile=$(awk '$1 == "ssl_certificate_key" {gsub(/;/, "", $2); print $2; exit}' "${btConfFile}" 2>/dev/null)

                    if [[ -z "${certFile}" ]]; then
                        certFile="/www/server/panel/vhost/cert/${btDomain}/fullchain.pem"
                    fi
                    if [[ -z "${keyFile}" ]]; then
                        keyFile="/www/server/panel/vhost/cert/${btDomain}/privkey.pem"
                    fi

                    if [[ ! -f "${certFile}" || ! -f "${keyFile}" ]]; then
                        echoContent red " ---> 未找到宝塔证书文件，请先检查站点SSL配置"
                        return
                    fi

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
            fi
        fi
    fi
}
check1Panel() {
    if [[ -n $(pgrep -f "1panel") ]]; then
        # 读取域名
        if [[ -d '/opt/1panel/apps/openresty/openresty/www/sites/' && -n $(find /opt/1panel/apps/openresty/openresty/www/sites/*/ssl/fullchain.pem) ]]; then
            if [[ -z "${currentHost}" ]]; then
                echoContent skyBlue "\n读取1Panel配置\n"

                find /opt/1panel/apps/openresty/openresty/www/sites/*/ssl/fullchain.pem | awk -F "[/]" '{print $9}' | awk '{print NR""":"$0}'

                read -r -p "请输入编号选择:" selectBTDomain
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
        if [[ -z "${currentHost}" ]]; then
            echoContent skyBlue "\n读取HestiaCP配置\n"
            local displayIndex
            for ((displayIndex = 0; displayIndex < domainCount; displayIndex++)); do
                local printIndex=$((displayIndex + 1))
                echo "${printIndex}:${hestiaDomains[displayIndex]} (user:${hestiaUsers[displayIndex]})"
            done
            read -r -p "请输入编号选择:" selectHestiaDomain
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
# 读取当前alpn的顺序
readInstallAlpn() {
    if [[ -n "${currentInstallProtocolType}" && -z "${realityStatus}" ]]; then
        local alpn
        alpn=$(jq -r .inbounds[0].streamSettings.tlsSettings.alpn[0] ${configPath}${frontingType}.json)
        if [[ -n ${alpn} ]]; then
            currentAlpn=${alpn}
        fi
    fi
}

# 检查防火墙
allowPort() {
    local type=$2
    if [[ -z "${type}" ]]; then
        type=tcp
    fi
    
    # 优先检查 UFW (通过 dpkg 检查是否安装)
    if dpkg -l 2>/dev/null | grep -q "^[[:space:]]*ii[[:space:]]\+ufw"; then
        if ufw status 2>/dev/null | grep -q "Status: active"; then
            if ! ufw status | grep -q "$1/${type}"; then
                sudo ufw allow "$1/${type}"
                checkUFWAllowPort "$1"
            fi
        fi
        return
    fi
    
    # 检查 UFW (通过 command 检查)
    if command -v ufw &> /dev/null; then
        if ufw status 2>/dev/null | grep -q "Status: active"; then
            if ! ufw status | grep -q "$1/${type}"; then
                sudo ufw allow "$1/${type}"
                checkUFWAllowPort "$1"
            fi
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
            local updateFirewalldStatus=
            if ! iptables -L | grep -q "$1/${type}(z9)"; then
                updateFirewalldStatus=true
                iptables -I INPUT -p ${type} --dport "$1" -m comment --comment "allow $1/${type}(z9)" -j ACCEPT
            fi

            if echo "${updateFirewalldStatus}" | grep -q "true"; then
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
            currentHost=$(jq -r .inbounds[0].streamSettings.tlsSettings.certificates[0].certificateFile ${configPath}${frontingType}.json | awk -F '[t][l][s][/]' '{print $2}' | awk -F '[.][c][r][t]' '{print $1}')

            currentPort=$(jq .inbounds[0].port ${configPath}${frontingType}.json)

            local defaultPortFile=
            defaultPortFile=$(find ${configPath}* | grep "default")

            if [[ -n "${defaultPortFile}" ]]; then
                currentDefaultPort=$(echo "${defaultPortFile}" | awk -F [_] '{print $4}')
            else
                currentDefaultPort=$(jq -r .inbounds[0].port ${configPath}${frontingType}.json)
            fi
            currentUUID=$(jq -r .inbounds[0].settings.clients[0].id ${configPath}${frontingType}.json)
            currentClients=$(jq -r .inbounds[0].settings.clients ${configPath}${frontingType}.json)
        fi

        # reality
        if echo ${currentInstallProtocolType} | grep -q ",7,"; then

            currentClients=$(jq -r .inbounds[0].settings.clients ${configPath}07_VLESS_vision_reality_inbounds.json)
            currentUUID=$(jq -r .inbounds[0].settings.clients[0].id ${configPath}07_VLESS_vision_reality_inbounds.json)
            xrayVLESSRealityVisionPort=$(jq -r .inbounds[0].port ${configPath}07_VLESS_vision_reality_inbounds.json)
            if [[ "${currentPort}" == "${xrayVLESSRealityVisionPort}" ]]; then
                xrayVLESSRealityVisionPort="${currentDefaultPort}"
            fi
        fi
    fi

    # 读取path
    if [[ -n "${configPath}" && -n "${frontingType}" ]]; then
        if [[ "${coreInstallType}" == "1" ]]; then
            local fallback
            fallback=$(jq -r -c '.inbounds[0].settings.fallbacks[]|select(.path)' ${configPath}${frontingType}.json | head -1)

            local path
            path=$(echo "${fallback}" | jq -r .path | awk -F "[/]" '{print $2}')

            if [[ $(echo "${fallback}" | jq -r .dest) == 31297 ]]; then
                currentPath=$(echo "${path}" | awk -F "[w][s]" '{print $1}')
            elif [[ $(echo "${fallback}" | jq -r .dest) == 31299 ]]; then
                currentPath=$(echo "${path}" | awk -F "[v][w][s]" '{print $1}')
            fi

            # 尝试读取alpn h2 Path
            if [[ -z "${currentPath}" ]]; then
                dest=$(jq -r -c '.inbounds[0].settings.fallbacks[]|select(.alpn)|.dest' ${configPath}${frontingType}.json | head -1)
                if [[ "${dest}" == "31302" || "${dest}" == "31304" ]]; then
                    checkBTPanel
                    check1Panel
                    checkHestiaPanel
                    if grep -q "trojangrpc {" <${nginxConfigPath}xray-agent.conf; then
                        currentPath=$(grep "trojangrpc {" <${nginxConfigPath}xray-agent.conf | awk -F "[/]" '{print $2}' | awk -F "[t][r][o][j][a][n]" '{print $1}')
                    elif grep -q "grpc {" <${nginxConfigPath}xray-agent.conf; then
                        currentPath=$(grep "grpc {" <${nginxConfigPath}xray-agent.conf | head -1 | awk -F "[/]" '{print $2}' | awk -F "[g][r][p][c]" '{print $1}')
                    fi
                fi
            fi
            if [[ -z "${currentPath}" && -f "${configPath}12_VLESS_XHTTP_inbounds.json" ]]; then
                currentPath=$(jq -r .inbounds[0].streamSettings.xhttpSettings.path "${configPath}12_VLESS_XHTTP_inbounds.json" | awk -F "[x][H][T][T][P]" '{print $1}' | awk -F "[/]" '{print $2}')
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

        if echo ${currentInstallProtocolType} | grep -q ",2,"; then
            echoContent yellow "Trojan+gRPC[TLS] \c"
        fi

        if echo ${currentInstallProtocolType} | grep -q ",5,"; then
            echoContent yellow "VLESS+gRPC[TLS] \c"
        fi
        if echo ${currentInstallProtocolType} | grep -q ",6,"; then
            echoContent yellow "Hysteria2 \c"
        fi
        if echo ${currentInstallProtocolType} | grep -q ",7,"; then
            echoContent yellow "VLESS+Reality+Vision \c"
        fi
        if echo ${currentInstallProtocolType} | grep -q ",8,"; then
            echoContent yellow "VLESS+Reality+gRPC \c"
        fi
        if echo ${currentInstallProtocolType} | grep -q ",9,"; then
            echoContent yellow "Tuic \c"
        fi
        if echo ${currentInstallProtocolType} | grep -q ",10,"; then
            echoContent yellow "Naive \c"
        fi
        if echo ${currentInstallProtocolType} | grep -q ",11,"; then
            echoContent yellow "VMess+TLS+HTTPUpgrade \c"
        fi
        if echo ${currentInstallProtocolType} | grep -q ",12,"; then
            echoContent yellow "VLESS+XHTTP \c"
        fi
        if echo ${currentInstallProtocolType} | grep -q ",13,"; then
            echoContent yellow "AnyTLS \c"
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
