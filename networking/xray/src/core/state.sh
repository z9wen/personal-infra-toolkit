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
