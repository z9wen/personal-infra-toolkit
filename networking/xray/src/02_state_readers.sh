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

