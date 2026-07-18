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
setupRelay() {
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
    echo
    echoContent green " ---> 链式代理已启用！"
    echoContent yellow " ---> 入站: $(jq -r '.inboundTags | join(", ")' /opt/xray-agent/relay_config.json)"
    echoContent yellow " ---> TCP: ${tcpLabel}${tcpAddress:+ → ${tcpAddress}:${tcpPort}}${tcpBbrProfile:+ [BBR/${tcpBbrProfile}]}"
    echoContent yellow " ---> UDP: ${udpLabel}${udpAddress:+ → ${udpAddress}:${udpPort}}${udpBbrProfile:+ [BBR/${udpBbrProfile}]}"
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
        echoContent yellow "3.停用中转"
        echoContent yellow "0.返回主菜单"
        echoContent red "=============================================================="
        read -r -p "请选择:" relayType

        case ${relayType} in
        1) setupRelay ;;
        2) showRelayConfig ;;
        3) removeRelay ;;
        0)
            menu
            return
            ;;
        *) echoContent red " ---> 请输入 0-3" ;;
        esac
        read -r -p "按回车键继续..."
    done
}
