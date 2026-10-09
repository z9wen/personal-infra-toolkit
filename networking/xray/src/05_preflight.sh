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
