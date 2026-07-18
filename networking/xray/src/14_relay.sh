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
