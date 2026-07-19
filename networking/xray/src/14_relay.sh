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
    touch /opt/xray-agent/crontab_relay.log
    chmod 600 /opt/xray-agent/crontab_relay.log
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

relayStateFile=/opt/xray-agent/relay_config.json

writeRelayState() {
    local content=$1 temporaryFile="${relayStateFile}.tmp.$$"
    echo "${content}" >"${temporaryFile}" || return 1
    chmod 600 "${temporaryFile}"
    mv "${temporaryFile}" "${relayStateFile}"
}

# 将旧版单中转状态转换成 profiles 数组，保留既有出站与订阅信息。
ensureRelayStateV2() {
    if [[ ! -f "${relayStateFile}" ]]; then
        writeRelayState '{"version":2,"profiles":[]}'
        return
    fi
    if jq -e '.version == 2 and (.profiles | type == "array")' "${relayStateFile}" >/dev/null 2>&1; then
        chmod 600 "${relayStateFile}"
        return
    fi
    local migrated
    migrated=$(jq '
        {version:2,profiles:[. + {
            id:"legacy",
            name:(.name // if .source == "subscription" then "原有订阅中转" else "原有手动中转" end),
            outboundTag:"relay_tcp_outbound",
            outboundFile:"relay_tcp_outbound.json"
        }]}
    ' "${relayStateFile}") || return 1
    writeRelayState "${migrated}"
    echoContent green " ---> 已将原有中转配置迁移为多规则格式"
}

relayProfileFileIsSafe() {
    [[ $1 =~ ^relay_([A-Za-z0-9_]+_)?outbound\.json$ ]]
}

relayInboundTagsAvailable() {
    local inboundTags=$1
    ensureRelayStateV2 || return 1
    relayReassignInbounds=false
    if jq -e --argjson tags "${inboundTags}" '
        any(.profiles[]?.inboundTags[]?; . as $used | $tags | index($used) != null)
    ' "${relayStateFile}" >/dev/null; then
        echoContent yellow " ---> 所选入站已属于以下规则:"
        jq -r --argjson tags "${inboundTags}" '.profiles[] |
            select(any(.inboundTags[]?; . as $used | $tags | index($used) != null)) |
            "     " + .name + " [" + (.inboundTags | join(", ")) + "]"' "${relayStateFile}"
        local reassignStatus
        read -r -p "是否从原规则移除这些入站并分配给新规则？[y/N]:" reassignStatus
        [[ "${reassignStatus}" =~ ^[Yy]$ ]] || return 1
        relayReassignInbounds=true
    fi
}

refreshRelaySubscriptionCron() {
    ensureRelayStateV2 || return 1
    if jq -e 'any(.profiles[]?; .source == "subscription")' "${relayStateFile}" >/dev/null; then
        installCronRelaySubscription
    else
        removeCronRelaySubscription
    fi
}

activateRelayProfile() {
    local profile=$1 generatedOutbound=$2
    local outboundFile backupDir validationOutput newState
    outboundFile=$(jq -r '.outboundFile' <<<"${profile}")
    relayProfileFileIsSafe "${outboundFile}" || return 1
    ensureRelayStateV2 || return 1
    backupDir=$(mktemp -d /tmp/xray-relay-profile.XXXXXX) || return 1
    cp "${relayStateFile}" "${backupDir}/relay_config.json"
    [[ -f "${configPath}09_routing.json" ]] && cp "${configPath}09_routing.json" "${backupDir}/09_routing.json"
    [[ -f "${configPath}${outboundFile}" ]] && cp "${configPath}${outboundFile}" "${backupDir}/${outboundFile}"

    mv "${generatedOutbound}" "${configPath}${outboundFile}" || {
        rm -rf "${backupDir}"
        return 1
    }
    chmod 600 "${configPath}${outboundFile}"
    newState=$(jq --argjson profile "${profile}" '
        $profile.inboundTags as $selected |
        .profiles = ([.profiles[] |
            .inboundTags -= $selected |
            select((.inboundTags | length) > 0)
        ] + [$profile])
    ' "${relayStateFile}") || return 1
    writeRelayState "${newState}" || return 1
    if ! rebuildRelayRouting || ! validationOutput=$(/opt/xray-agent/xray/xray run -test -confdir "${configPath}" 2>&1); then
        cp "${backupDir}/relay_config.json" "${relayStateFile}"
        [[ -f "${backupDir}/09_routing.json" ]] && cp "${backupDir}/09_routing.json" "${configPath}09_routing.json"
        if [[ -f "${backupDir}/${outboundFile}" ]]; then
            cp "${backupDir}/${outboundFile}" "${configPath}${outboundFile}"
        else
            rm -f "${configPath}${outboundFile}"
        fi
        echoContent red " ---> Xray 拒绝了新中转配置，已恢复上一版"
        [[ -n "${validationOutput}" ]] && echoContent yellow "${validationOutput}"
        rm -rf "${backupDir}"
        return 1
    fi
    local orphanedFile
    while read -r orphanedFile; do
        if relayProfileFileIsSafe "${orphanedFile}" && ! jq -e --arg file "${orphanedFile}" 'any(.profiles[]?; .outboundFile == $file)' "${relayStateFile}" >/dev/null; then
            rm -f "${configPath}${orphanedFile}"
        fi
    done < <(jq -r '.profiles[]?.outboundFile' "${backupDir}/relay_config.json")
    rm -rf "${backupDir}"
    refreshRelaySubscriptionCron
    handleXray stop
    handleXray start
}

selectRelayUdpMode() {
    local udpRelayStatus
    relaySelectedUdpMode=direct
    read -r -p "UDP 也通过此上游转发吗？[y/N]:" udpRelayStatus
    [[ "${udpRelayStatus}" =~ ^[Yy]$ ]] && relaySelectedUdpMode=shared
}

# 使用 sing-box JSON 订阅新增 Shadowsocks 中转规则。
setupRelaySubscription() {
    local profileName=$1 profileId=$2 outboundTag="relay_profile_${profileId}" outboundFile="relay_${profileId}_outbound.json"
    selectRelayUdpMode
    local subscriptionUrl tempDir subscriptionFile nodeCount nodeIndex selectedTag generatedOutbound
    read -r -p "请输入 sing-box JSON 订阅地址:" subscriptionUrl
    [[ -z "${subscriptionUrl}" ]] && echoContent red " ---> 订阅地址不能为空" && return 1
    tempDir=$(mktemp -d /tmp/xray-relay-subscription.XXXXXX) || return 1
    subscriptionFile="${tempDir}/subscription.json"
    generatedOutbound="${tempDir}/${outboundFile}"
    fetchRelaySubscription "${subscriptionUrl}" "${subscriptionFile}" || {
        rm -rf "${tempDir}"
        return 1
    }
    nodeCount=$(jq '[.outbounds[]? | select(.type == "shadowsocks")] | length' "${subscriptionFile}")
    if ((nodeCount == 0)); then
        echoContent red " ---> 订阅中没有 Shadowsocks 节点"
        rm -rf "${tempDir}"
        return 1
    elif ((nodeCount == 1)); then
        selectedTag=$(jq -r 'first(.outbounds[] | select(.type == "shadowsocks")).tag' "${subscriptionFile}")
    else
        jq -r '[.outbounds[] | select(.type == "shadowsocks")] | to_entries[] | "\(.key + 1).\(.value.tag) -> \(.value.server):\(.value.server_port)"' "${subscriptionFile}"
        read -r -p "请选择上游节点:" nodeIndex
        if [[ ! "${nodeIndex}" =~ ^[0-9]+$ ]] || ((nodeIndex < 1 || nodeIndex > nodeCount)); then
            rm -rf "${tempDir}"
            return 1
        fi
        selectedTag=$(jq -r --argjson index "$((nodeIndex - 1))" '[.outbounds[] | select(.type == "shadowsocks")][$index].tag' "${subscriptionFile}")
    fi
    buildRelayOutboundFromSingBoxSubscription "${subscriptionFile}" "${selectedTag}" "${outboundTag}" "${generatedOutbound}" || {
        rm -rf "${tempDir}"
        return 1
    }
    local nodeAddress nodePort nodeMethod profile
    nodeAddress=$(jq -r --arg tag "${selectedTag}" 'first(.outbounds[] | select(.type == "shadowsocks" and .tag == $tag)).server' "${subscriptionFile}")
    nodePort=$(jq -r --arg tag "${selectedTag}" 'first(.outbounds[] | select(.type == "shadowsocks" and .tag == $tag)).server_port' "${subscriptionFile}")
    nodeMethod=$(jq -r --arg tag "${selectedTag}" 'first(.outbounds[] | select(.type == "shadowsocks" and .tag == $tag)).method' "${subscriptionFile}")
    profile=$(jq -n --arg id "${profileId}" --arg name "${profileName}" --argjson inboundTags "${relaySelectedInboundTags}" \
        --arg outboundTag "${outboundTag}" --arg outboundFile "${outboundFile}" --arg url "${subscriptionUrl}" --arg selectedTag "${selectedTag}" \
        --arg address "${nodeAddress}" --arg port "${nodePort}" --arg method "${nodeMethod}" --arg udpMode "${relaySelectedUdpMode}" '
        {id:$id,name:$name,source:"subscription",inboundTags:$inboundTags,outboundTag:$outboundTag,outboundFile:$outboundFile,
         subscription:{format:"sing-box-json",url:$url,selectedTag:$selectedTag},
         tcp:{mode:"relay",protocol:"shadowsocks",label:("Shadowsocks ("+$method+")"),address:$address,port:$port,bbrProfile:""},
         udp:(if $udpMode == "shared" then {mode:"shared",protocol:"shadowsocks",label:("Shadowsocks ("+$method+")"),address:$address,port:$port,bbrProfile:""} else {mode:"direct",protocol:"",label:"直连",address:"",port:"",bbrProfile:""} end)}')
    activateRelayProfile "${profile}" "${generatedOutbound}" || {
        rm -rf "${tempDir}"
        return 1
    }
    rm -rf "${tempDir}"
    echoContent green " ---> 中转规则 ${profileName} 已启用: ${selectedTag} -> ${nodeAddress}:${nodePort}"
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

# 根据全部 profiles 重建中转路由，未绑定的入站继续使用原有分流。
rebuildRelayRouting() {
    local routingFile="${configPath}09_routing.json"
    [[ -f "${routingFile}" ]] || return 1
    ensureRelayStateV2 || return 1
    local relayRules managedTags newConfig
    relayRules=$(jq '[.profiles[]? | . as $profile |
        [{type:"field",inboundTag:$profile.inboundTags,network:"tcp",outboundTag:$profile.outboundTag}] +
        (if $profile.udp.mode == "shared" then [{type:"field",inboundTag:$profile.inboundTags,network:"udp",outboundTag:$profile.outboundTag}] else [] end)
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
    echo "${newConfig}" >"${routingFile}"
}

setupRelayManual() {
    local profileName=$1 profileId=$2 outboundTag="relay_profile_${profileId}" outboundFile="relay_${profileId}_outbound.json"
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
    profile=$(jq -n --arg id "${profileId}" --arg name "${profileName}" --argjson inboundTags "${relaySelectedInboundTags}" \
        --arg outboundTag "${outboundTag}" --arg outboundFile "${outboundFile}" --arg protocol "${relayBuiltProtocol}" \
        --arg label "${relayBuiltLabel}" --arg address "${relayBuiltAddress}" --arg port "${relayBuiltPort}" \
        --arg bbrProfile "${relayBuiltBbrProfile}" --arg udpMode "${relaySelectedUdpMode}" '
        {id:$id,name:$name,source:"manual",inboundTags:$inboundTags,outboundTag:$outboundTag,outboundFile:$outboundFile,
         tcp:{mode:"relay",protocol:$protocol,label:$label,address:$address,port:$port,bbrProfile:$bbrProfile},
         udp:(if $udpMode == "shared" then {mode:"shared",protocol:$protocol,label:$label,address:$address,port:$port,bbrProfile:$bbrProfile} else {mode:"direct",protocol:"",label:"直连",address:"",port:"",bbrProfile:""} end)}')
    activateRelayProfile "${profile}" "${generatedOutbound}" || {
        rm -rf "${tempDir}"
        return 1
    }
    rm -rf "${tempDir}"
    echoContent green " ---> 中转规则 ${profileName} 已启用"
}

setupRelay() {
    echoContent skyBlue "\n新增中转规则"
    echoContent yellow "# 每个本机入站只能绑定一条规则，未绑定入站保持原有分流\n"
    selectRelayInbounds || return
    relayInboundTagsAvailable "${relaySelectedInboundTags}" || return
    echoContent skyBlue "\n请选择上游配置来源"
    echoContent yellow "1.sing-box JSON 订阅中的 Shadowsocks 节点"
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
    echoContent skyBlue "\n当前中转规则"
    jq -r '.profiles | to_entries[] |
        "\(.key + 1). \(.value.name)\n   入站: \(.value.inboundTags | join(", "))\n   TCP : \(.value.tcp.label) -> \(.value.tcp.address):\(.value.tcp.port)\n   UDP : \(if .value.udp.mode == "shared" then (.value.udp.label + " -> " + .value.udp.address + ":" + .value.udp.port) else "直连" end)\n   来源: \(if .value.source == "subscription" then "订阅自动更新" else "手动" end)"' "${relayStateFile}"
}

updateRelaySubscriptionProfile() {
    local profileId=$1 profile subscriptionUrl selectedTag outboundTag outboundFile tempDir subscriptionFile generatedOutbound
    profile=$(jq -c --arg id "${profileId}" 'first(.profiles[] | select(.id == $id))' "${relayStateFile}") || return 1
    subscriptionUrl=$(jq -r '.subscription.url' <<<"${profile}")
    selectedTag=$(jq -r '.subscription.selectedTag' <<<"${profile}")
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
    if ! jq -e --arg tag "${selectedTag}" 'any(.outbounds[]?; .type == "shadowsocks" and .tag == $tag)' "${subscriptionFile}" >/dev/null; then
        selectedTag=$(jq -r 'first(.outbounds[]? | select(.type == "shadowsocks")).tag // empty' "${subscriptionFile}")
    fi
    if [[ -z "${selectedTag}" ]]; then
        echoContent red " ---> 更新后的订阅中没有 Shadowsocks 节点，保留旧配置"
        rm -rf "${tempDir}"
        return 1
    fi
    buildRelayOutboundFromSingBoxSubscription "${subscriptionFile}" "${selectedTag}" "${outboundTag}" "${generatedOutbound}" || {
        rm -rf "${tempDir}"
        return 1
    }
    if [[ -f "${configPath}${outboundFile}" ]] && cmp -s "${generatedOutbound}" "${configPath}${outboundFile}"; then
        if [[ $(jq -r '.subscription.selectedTag' <<<"${profile}") != "${selectedTag}" ]]; then
            local renamedState
            renamedState=$(jq --arg id "${profileId}" --arg tag "${selectedTag}" '.profiles |= map(if .id == $id then .subscription.selectedTag = $tag else . end)' "${relayStateFile}") || return 1
            writeRelayState "${renamedState}" || return 1
        fi
        echoContent green " ---> $(jq -r '.name' <<<"${profile}"): 订阅没有变化"
        rm -rf "${tempDir}"
        return 0
    fi
    local backupFile="${tempDir}/backup.json" validationOutput nodeAddress nodePort nodeMethod newState
    [[ -f "${configPath}${outboundFile}" ]] && cp "${configPath}${outboundFile}" "${backupFile}"
    mv "${generatedOutbound}" "${configPath}${outboundFile}"
    chmod 600 "${configPath}${outboundFile}"
    if ! validationOutput=$(/opt/xray-agent/xray/xray run -test -confdir "${configPath}" 2>&1); then
        [[ -f "${backupFile}" ]] && cp "${backupFile}" "${configPath}${outboundFile}"
        echoContent red " ---> 新订阅配置验证失败，已保留旧配置"
        echoContent yellow "${validationOutput}"
        rm -rf "${tempDir}"
        return 1
    fi
    nodeAddress=$(jq -r --arg tag "${selectedTag}" 'first(.outbounds[] | select(.type == "shadowsocks" and .tag == $tag)).server' "${subscriptionFile}")
    nodePort=$(jq -r --arg tag "${selectedTag}" 'first(.outbounds[] | select(.type == "shadowsocks" and .tag == $tag)).server_port' "${subscriptionFile}")
    nodeMethod=$(jq -r --arg tag "${selectedTag}" 'first(.outbounds[] | select(.type == "shadowsocks" and .tag == $tag)).method' "${subscriptionFile}")
    newState=$(jq --arg id "${profileId}" --arg tag "${selectedTag}" --arg address "${nodeAddress}" --arg port "${nodePort}" --arg method "${nodeMethod}" '
        .profiles |= map(if .id == $id then
            .subscription.selectedTag = $tag |
            .tcp.label = ("Shadowsocks ("+$method+")") | .tcp.address = $address | .tcp.port = $port |
            if .udp.mode == "shared" then .udp.label = ("Shadowsocks ("+$method+")") | .udp.address = $address | .udp.port = $port else . end
        else . end)
    ' "${relayStateFile}") || return 1
    writeRelayState "${newState}" || return 1
    relaySubscriptionChanged=true
    echoContent green " ---> $(jq -r '.name' <<<"${profile}"): 已更新到 ${selectedTag} -> ${nodeAddress}:${nodePort}"
    rm -rf "${tempDir}"
}

updateRelaySubscription() {
    ensureRelayStateV2 || return 1
    exec 9>/opt/xray-agent/update-relay.lock
    if command -v flock >/dev/null 2>&1 && ! flock -n 9; then
        echoContent yellow " ---> 中转订阅更新任务正在运行"
        return 0
    fi
    local profileId updateFailed=false
    relaySubscriptionChanged=false
    while read -r profileId; do
        updateRelaySubscriptionProfile "${profileId}" || updateFailed=true
    done < <(jq -r '.profiles[]? | select(.source == "subscription").id' "${relayStateFile}")
    if [[ "${relaySubscriptionChanged}" == "true" ]]; then
        handleXray stop
        handleXray start
    fi
    [[ "${updateFailed}" == "false" ]]
}

removeRelayProfile() {
    ensureRelayStateV2 || return
    local count selection profile outboundFile backupDir newState validationOutput
    count=$(jq '.profiles | length' "${relayStateFile}")
    ((count == 0)) && echoContent yellow " ---> 当前没有中转规则" && return
    jq -r '.profiles | to_entries[] | "\(.key + 1).\(.value.name) [\(.value.inboundTags | join(", "))]"' "${relayStateFile}"
    read -r -p "请选择要删除的规则:" selection
    if [[ ! "${selection}" =~ ^[0-9]+$ ]] || ((selection < 1 || selection > count)); then
        echoContent red " ---> 规则选项无效"
        return
    fi
    profile=$(jq -c --argjson index "$((selection - 1))" '.profiles[$index]' "${relayStateFile}")
    outboundFile=$(jq -r '.outboundFile' <<<"${profile}")
    relayProfileFileIsSafe "${outboundFile}" || return 1
    backupDir=$(mktemp -d /tmp/xray-relay-remove.XXXXXX) || return
    cp "${relayStateFile}" "${backupDir}/relay_config.json"
    cp "${configPath}09_routing.json" "${backupDir}/09_routing.json"
    [[ -f "${configPath}${outboundFile}" ]] && cp "${configPath}${outboundFile}" "${backupDir}/${outboundFile}"
    newState=$(jq --argjson index "$((selection - 1))" 'del(.profiles[$index])' "${relayStateFile}") || return 1
    writeRelayState "${newState}" || return 1
    rm -f "${configPath}${outboundFile}"
    if ! rebuildRelayRouting || ! validationOutput=$(/opt/xray-agent/xray/xray run -test -confdir "${configPath}" 2>&1); then
        cp "${backupDir}/relay_config.json" "${relayStateFile}"
        cp "${backupDir}/09_routing.json" "${configPath}09_routing.json"
        [[ -f "${backupDir}/${outboundFile}" ]] && cp "${backupDir}/${outboundFile}" "${configPath}${outboundFile}"
        echoContent red " ---> 删除后的配置验证失败，已恢复"
        rm -rf "${backupDir}"
        return 1
    fi
    rm -rf "${backupDir}"
    refreshRelaySubscriptionCron
    handleXray stop
    handleXray start
    echoContent green " ---> 中转规则已删除"
}

removeRelay() {
    ensureRelayStateV2 || return
    local outboundFile
    while read -r outboundFile; do
        relayProfileFileIsSafe "${outboundFile}" && rm -f "${configPath}${outboundFile}"
    done < <(jq -r '.profiles[]?.outboundFile' "${relayStateFile}")
    writeRelayState '{"version":2,"profiles":[]}'
    rebuildRelayRouting
    rm -f /opt/xray-agent/relay_config
    removeCronRelaySubscription
    handleXray stop
    handleXray start
    echoContent green " ---> 所有中转规则已停用，相关入站恢复原有分流"
}

manageRelay() {
    if [[ -z "${configPath}" ]]; then
        echoContent red " ---> 未安装，请使用脚本安装"
        return
    fi
    ensureRelayStateV2 || return
    local relayType profileCount
    while true; do
        ensureRelayStateV2 || return
        profileCount=$(jq '.profiles | length' "${relayStateFile}")
        echoContent skyBlue "\n功能 1/${totalProgress} : 多规则中转管理"
        echoContent red "\n=============================================================="
        echoContent yellow "# 当前中转规则: ${profileCount} 条"
        echoContent yellow "1.新增中转规则"
        echoContent yellow "2.查看全部规则"
        echoContent yellow "3.立即更新所有订阅规则"
        echoContent yellow "4.删除一条规则"
        echoContent yellow "5.停用全部中转"
        echoContent yellow "0.返回主菜单"
        echoContent red "=============================================================="
        read -r -p "请选择:" relayType
        case ${relayType} in
        1) setupRelay ;;
        2) showRelayConfig ;;
        3) updateRelaySubscription ;;
        4) removeRelayProfile ;;
        5) removeRelay ;;
        0) return ;;
        *) echoContent red " ---> 请输入 0-5" ;;
        esac
        read -r -p "按回车键继续..."
    done
}
