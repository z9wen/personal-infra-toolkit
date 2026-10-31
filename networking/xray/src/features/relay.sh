# ==================== Relay management ====================
#
# Relay state (relayStateFile) is the single source of truth: a list of
# upstream profiles, each with the selectors routed through it. A selector is
# {inboundTags: [...], users: [...]}; an empty users list means the whole
# inbound. 09_routing.json is regenerated from that state, never edited by
# hand, and every change goes through commitRelayChange so it is validated by
# Xray and rolled back on failure.

relayStateFile=/opt/xray-agent/relay_config.json
relayLockFile=/opt/xray-agent/update-relay.lock

# jq definitions shared by every selector query.
relaySelectorJqDefs='
    def overlap($left; $right):
        any($left[]?; . as $item | $right | index($item) != null);
    # Does $current already claim traffic that $selected wants?
    def conflicts($current; $selected):
        overlap($current.inboundTags; $selected.inboundTags) and
        (
            (($selected.users // []) | length) == 0 or
            (
                ((($current.users // []) | length) > 0) and
                overlap(($current.users // []); ($selected.users // []))
            )
        );
    # Remove from $current whatever $selected takes over; empty results vanish.
    def subtractSelector($current; $selected):
        if (($selected.users // []) | length) == 0 then
            $current | .inboundTags -= $selected.inboundTags | select((.inboundTags | length) > 0)
        elif ((($current.users // []) | length) > 0 and overlap($current.inboundTags; $selected.inboundTags)) then
            $current | .users -= $selected.users | select((.users | length) > 0)
        else $current end;
    # Account tag without the protocol suffix added to Xray emails.
    def displayUser:
        sub("-(VLESS_TCP/TLS_Vision|VLESS_WS|VLESS_XHTTP_Reality|VLESS_XHTTP|vless_reality_vision|Hysteria2)$"; "");
'

# Return the protocols installed on this host that can serve as relay entries.
detectRelayInbounds() {
    relayInboundTags=()
    relayInboundLabels=()
    [[ -f "${configPath}02_VLESS_TCP_inbounds.json" ]] && relayInboundTags+=("VLESSTCP") && relayInboundLabels+=("VLESS + TCP + TLS Vision")
    [[ -f "${configPath}03_VLESS_WS_inbounds.json" ]] && relayInboundTags+=("VLESSWS") && relayInboundLabels+=("VLESS + WebSocket + TLS")
    [[ -f "${configPath}07_VLESS_vision_reality_inbounds.json" ]] && relayInboundTags+=("VLESSReality") && relayInboundLabels+=("VLESS + Reality + Vision")
    [[ -f "${configPath}14_VLESS_XHTTP_TLS_inbounds.json" ]] && relayInboundTags+=("VLESSXHTTP") && relayInboundLabels+=("VLESS + XHTTP + TLS")
    [[ -f "${configPath}12_VLESS_XHTTP_inbounds.json" ]] && relayInboundTags+=("VLESSRealityXHTTP") && relayInboundLabels+=("VLESS + XHTTP + Reality")
    [[ -f "${configPath}05_hysteria2_inbounds.json" ]] && relayInboundTags+=("Hysteria2") && relayInboundLabels+=("Hysteria2 + TLS + QUIC")
}

# Generate selectable "inbound + account" targets. Each inbound can be selected as a whole, or narrowed to a specific UUID/auth that has an email.
buildRelayTargetChoices() {
    detectRelayInbounds
    relayTargetChoices='[]'
    if ((${#relayInboundTags[@]} == 0)); then
        echoContent red " ---> 未检测到可用的入站协议"
        return 1
    fi

    local index inboundTag inboundLabel inboundConfig clients
    for ((index = 0; index < ${#relayInboundTags[@]}; index++)); do
        inboundTag=${relayInboundTags[index]}
        inboundLabel=${relayInboundLabels[index]}
        case "${inboundTag}" in
            VLESSTCP) inboundConfig="${configPath}02_VLESS_TCP_inbounds.json" ;;
            VLESSWS) inboundConfig="${configPath}03_VLESS_WS_inbounds.json" ;;
            VLESSReality) inboundConfig="${configPath}07_VLESS_vision_reality_inbounds.json" ;;
            VLESSXHTTP) inboundConfig="${configPath}14_VLESS_XHTTP_TLS_inbounds.json" ;;
            VLESSRealityXHTTP) inboundConfig="${configPath}12_VLESS_XHTTP_inbounds.json" ;;
            Hysteria2) inboundConfig="${configPath}05_hysteria2_inbounds.json" ;;
            *) continue ;;
        esac
        relayTargetChoices=$(jq -c --arg tag "${inboundTag}" --arg label "${inboundLabel}" '
            . + [{selector:{inboundTags:[$tag],users:[]},label:($label + " / 整个入站（全部 UUID/auth）")}]
        ' <<<"${relayTargetChoices}")
        clients=$(jq -c '
            (.inbounds[0].settings.clients // .inbounds[0].settings.users // .inbounds[0].users // [])
            | map(select((.email // "") != ""))
        ' "${inboundConfig}") || return 1
        relayTargetChoices=$(jq -c --arg tag "${inboundTag}" --arg label "${inboundLabel}" --argjson clients "${clients}" "${relaySelectorJqDefs}"'
            reduce $clients[] as $client (.;
                ($client.email | displayUser) as $accountTag |
                ($client.id // $client.uuid // $client.auth // $client.password // "unknown") as $credential |
                . + [{selector:{inboundTags:[$tag],users:[$client.email]},
                    label:($label + " / tag: " + $accountTag + " / UUID/auth: " + $credential)}]
            )
        ' <<<"${relayTargetChoices}")
    done
}

# Multiple exact targets can be selected at once, e.g. a Vision UUID plus a Hysteria2 auth.
selectRelayTargets() {
    buildRelayTargetChoices || return 1
    local targetCount selection
    targetCount=$(jq 'length' <<<"${relayTargetChoices}")
    ((targetCount > 0)) || return 1
    echoContent skyBlue "\n请选择需要链式转发的精确目标"
    jq -r 'to_entries[] | "\(.key + 1).\(.value.label)"' <<<"${relayTargetChoices}"

    read -r -p "请选择[可多选，例:3,6]:" selection
    selection=${selection//，/,}
    if [[ -z "${selection}" ]]; then
        echoContent red " ---> 至少选择一个目标"
        return 1
    fi

    relaySelectedSelectors='[]'
    local -a choices=()
    local choice selector
    IFS=',' read -r -a choices <<<"${selection}"
    for choice in "${choices[@]}"; do
        choice=${choice//[[:space:]]/}
        if [[ ! "${choice}" =~ ^[0-9]+$ ]] || ((choice < 1 || choice > targetCount)); then
            echoContent red " ---> 目标选项无效: ${choice}"
            return 1
        fi
        selector=$(jq -c --argjson index "$((choice - 1))" '.[$index].selector' <<<"${relayTargetChoices}")
        relaySelectedSelectors=$(jq -c --argjson selector "${selector}" '
            ($selector.inboundTags[0]) as $tag |
            if (($selector.users | length) == 0) then
                [ .[] | select(.inboundTags[0] != $tag) ] + [$selector]
            elif any(.[]; .inboundTags[0] == $tag and ((.users // []) | length) == 0) then .
            elif index($selector) == null then . + [$selector]
            else . end
        ' <<<"${relaySelectedSelectors}")
    done
    echoContent green " ---> 已选择 $(jq 'length' <<<"${relaySelectedSelectors}") 个独立入口规则"
}

# Return the nodes in a sing-box JSON subscription that can be converted to Xray outbounds.
# For now Reality only accepts VLESS + Reality (RAW/TCP) with no extra transport configured.
getRelayNodesFromSingBoxSubscription() {
    local subscriptionFile=$1
    jq -c '[
        .outbounds[]? |
        select((.tag | type) == "string" and (.tag | length) > 0) |
        # Xray has no SIP003 plugin support; such nodes would pass
        # `xray -test` but never connect.
        if .type == "shadowsocks" and ((.plugin // "") == "") then
            . + {_relayType:"shadowsocks"}
        elif (
            .type == "vless" and
            .tls.enabled == true and
            .tls.reality.enabled == true and
            (((.transport // {}) | type) == "object") and
            (((.transport // {}) | length) == 0)
        ) then
            . + {_relayType:"vless-reality"}
        else empty end
    ]' "${subscriptionFile}"
}

# Read Shadowsocks or VLESS Reality outbounds from a sing-box JSON subscription and convert them to Xray config.
buildRelayOutboundFromSingBoxSubscription() {
    local subscriptionFile=$1 selectedTag=$2 outboundTag=$3 outputFile=$4
    local supportedNodes node nodeType
    supportedNodes=$(getRelayNodesFromSingBoxSubscription "${subscriptionFile}") || return 1
    node=$(jq -c --arg tag "${selectedTag}" 'first(.[] | select(.tag == $tag))' <<<"${supportedNodes}") || return 1
    [[ -n "${node}" && "${node}" != "null" ]] || return 1
    nodeType=$(jq -r '._relayType' <<<"${node}")

    if ! jq -e '
        (.server | type == "string" and length > 0) and
        (.server_port | type == "number" and . >= 1 and . <= 65535)
    ' <<<"${node}" >/dev/null; then
        return 1
    fi

    case ${nodeType} in
        shadowsocks)
            if ! jq -e '
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
        ' >"${outputFile}" || return 1
            relayBuiltProtocol="shadowsocks"
            relayBuiltLabel="Shadowsocks ($(jq -r '.method' <<<"${node}"))"
            ;;
        vless-reality)
            if ! jq -e '
            (.uuid | type == "string" and length > 0) and
            ((.flow // "") | type == "string" and
                (. == "" or . == "xtls-rprx-vision" or . == "xtls-rprx-vision-udp443")) and
            (.tls.server_name | type == "string" and length > 0) and
            (.tls.reality.public_key | type == "string" and length > 0) and
            ((.tls.reality.short_id // "") | type == "string" and test("^([0-9A-Fa-f]{2}){0,8}$")) and
            ((.tls.utls.fingerprint // "chrome") | type == "string" and length > 0)
        ' <<<"${node}" >/dev/null; then
                return 1
            fi
            jq -n --arg tag "${outboundTag}" --argjson node "${node}" '
            {outbounds:[{
                tag:$tag,
                protocol:"vless",
                settings:{vnext:[{
                    address:$node.server,
                    port:$node.server_port,
                    users:[({id:$node.uuid,encryption:"none"} +
                        if (($node.flow // "") | length) > 0 then {flow:$node.flow} else {} end)]
                }]},
                streamSettings:{
                    network:"tcp",
                    security:"reality",
                    realitySettings:({
                        show:false,
                        serverName:$node.tls.server_name,
                        fingerprint:($node.tls.utls.fingerprint // "chrome"),
                        password:$node.tls.reality.public_key,
                        shortId:($node.tls.reality.short_id // ""),
                        spiderX:"/"
                    } + if (($node.tls.reality.mldsa65_verify // "") | length) > 0 then
                        {mldsa65Verify:$node.tls.reality.mldsa65_verify}
                    else {} end)
                }
            }]}
        ' >"${outputFile}" || return 1
            relayBuiltProtocol="reality"
            if [[ -n $(jq -r '.flow // empty' <<<"${node}") ]]; then
                relayBuiltLabel="VLESS + Reality + Vision"
            else
                relayBuiltLabel="VLESS + Reality"
            fi
            ;;
        *) return 1 ;;
    esac

    relayBuiltSubscriptionType=${nodeType}
    relayBuiltAddress=$(jq -r '.server' <<<"${node}")
    relayBuiltPort=$(jq -r '.server_port' <<<"${node}")
    relayBuiltBbrProfile=
}

# The daily cron job applies whatever the subscription returns as root, so it
# must come over HTTPS (redirects included); plain HTTP would let anyone on
# the path swap in their own upstream.
fetchRelaySubscription() {
    local url=$1 destination=$2
    if [[ ! "${url}" =~ ^https:// ]]; then
        echoContent red " ---> 订阅地址必须以 https:// 开头"
        return 1
    fi
    if ! downloadFile "${url}" "${destination}" --https-only; then
        echoContent red " ---> 中转订阅下载失败"
        return 1
    fi
    if ! jq -e '.outbounds | type == "array"' "${destination}" >/dev/null 2>&1; then
        echoContent red " ---> 订阅内容不是有效的 sing-box JSON"
        return 1
    fi
}

# Replace the relay refresh entry in root's crontab; with no argument the
# entry is only removed.
setRelayCronEntry() {
    local entry=${1:-} backupFile=/opt/xray-agent/backup_crontab.cron
    crontab -l >"${backupFile}" 2>/dev/null || true
    {
        sed '/xray-agent-update-relay/d;/xray-agent\/install.sh UpdateRelay/d' "${backupFile}"
        [[ -n "${entry}" ]] && echo "${entry}"
    } >"${backupFile}.new"
    mv "${backupFile}.new" "${backupFile}"
    crontab "${backupFile}"
}

installCronRelaySubscription() {
    touch /opt/xray-agent/crontab_relay.log
    chmod 600 /opt/xray-agent/crontab_relay.log
    setRelayCronEntry "17 4 * * * /bin/bash /opt/xray-agent/install.sh UpdateRelay >> /opt/xray-agent/crontab_relay.log 2>&1 # xray-agent-update-relay"
}

removeCronRelaySubscription() {
    setRelayCronEntry
}

writeRelayState() {
    local content=$1 temporaryFile="${relayStateFile}.tmp.$$"
    jq -e . >/dev/null 2>&1 <<<"${content}" || return 1
    echo "${content}" >"${temporaryFile}" || return 1
    chmod 600 "${temporaryFile}"
    mv "${temporaryFile}" "${relayStateFile}"
}

# Replace the relay state with the output of a state-building command.
# Usage: updateRelayState <command> [args...]
updateRelayState() {
    local newState
    newState=$("$@") || return 1
    writeRelayState "${newState}"
}

# Run a command while holding the relay lock, so the menu and the daily
# refresh job never modify relay state at the same time. The lock is only
# held for the duration of one change, not for a whole menu session.
# Nested calls reuse the lock that is already held.
withRelayLock() {
    local status=0
    if [[ "${relayLockHeld:-false}" == "true" ]] || ! command -v flock >/dev/null 2>&1; then
        "$@"
        return
    fi
    exec 9>"${relayLockFile}" || return 1
    if ! flock -w 30 9; then
        echoContent yellow " ---> 中转配置正被其他任务修改，请稍后重试"
        exec 9>&-
        return 1
    fi
    relayLockHeld=true
    "$@" || status=$?
    relayLockHeld=false
    exec 9>&-
    return "${status}"
}

relayChangeThenRebuild() {
    "$@" && rebuildRelayRouting
}

# Apply one relay change transactionally: run it, regenerate routing from
# the new state, validate with Xray and restore everything on failure. On
# success, drop outbound files no profile uses and sync the refresh cron job.
# Usage: commitRelayChange <description> <command> [args...]
commitRelayChange() {
    local description=$1
    shift
    applyXrayConfigChange "${description}" relayChangeThenRebuild "$@" || return 1
    removeOrphanedRelayFiles
    refreshRelaySubscriptionCron
}

# Convert the legacy state into the "one upstream profile maps to multiple entry selectors" format.
ensureRelayStateV2() {
    if [[ ! -f "${relayStateFile}" ]]; then
        writeRelayState '{"version":2,"profiles":[]}'
        return
    fi
    if jq -e '.version == 2 and (.profiles | type == "array")' "${relayStateFile}" >/dev/null 2>&1; then
        local normalized current
        normalized=$(jq -c '
            .profiles |= map(
                if (.selectors? | type) == "array" then
                    .
                else
                    . + {selectors:[{
                        inboundTags:(.inboundTags // []),
                        users:(.users // [])
                    }]}
                end |
                del(.inboundTags, .users)
            )
        ' "${relayStateFile}") || return 1
        current=$(jq -c . "${relayStateFile}") || return 1
        if [[ "${normalized}" != "${current}" ]]; then
            writeRelayState "${normalized}" || return 1
            echoContent green " ---> 已将中转规则升级为多入口格式"
        else
            chmod 600 "${relayStateFile}"
        fi
        return
    fi
    local migrated
    migrated=$(jq '
        . as $legacy |
        {version:2,profiles:[(
            $legacy + {
                id:"legacy",
                name:($legacy.name // if $legacy.source == "subscription" then "原有订阅中转" else "原有手动中转" end),
                outboundTag:"relay_tcp_outbound",
                outboundFile:"relay_tcp_outbound.json",
                selectors:[{
                    inboundTags:($legacy.inboundTags // []),
                    users:($legacy.users // [])
                }]
            } |
            del(.inboundTags, .users)
        )]}
    ' "${relayStateFile}") || return 1
    writeRelayState "${migrated}"
    echoContent green " ---> 已将原有中转配置迁移为多入口格式"
}

relayProfileFileIsSafe() {
    [[ $1 =~ ^relay_([A-Za-z0-9_]+_)?outbound\.json$ ]]
}

# Check whether the target selectors are already bound to another upstream.
relayTargetsAvailable() {
    local selector=$1 destinationId=${2:-}
    ensureRelayStateV2 || return 1
    if jq -e --argjson selector "${selector}" --arg destinationId "${destinationId}" "${relaySelectorJqDefs}"'
        any(.profiles[]? | select(.id != $destinationId) | .selectors[]?; conflicts(.; $selector))
    ' "${relayStateFile}" >/dev/null; then
        echoContent yellow " ---> 所选目标已属于以下规则:"
        jq -r --argjson selector "${selector}" --arg destinationId "${destinationId}" "${relaySelectorJqDefs}"'
            .profiles[] | select(.id != $destinationId) as $profile |
            $profile.selectors[] |
            select(conflicts(.; $selector)) |
            "     " + $profile.name + " [" + (.inboundTags | join(", ")) + "] 账号: " +
            (if ((.users // []) | length) > 0 then ([.users[] | displayUser] | join(", ")) else "全部 UUID" end)
        ' "${relayStateFile}"
        local reassignStatus
        if [[ $(jq '.users | length' <<<"${selector}") -eq 0 ]]; then
            read -r -p "新规则将覆盖整个入站，是否移除上述旧绑定？[y/N]:" reassignStatus
        else
            read -r -p "是否将这些账号改派到新规则？[y/N]:" reassignStatus
        fi
        [[ "${reassignStatus}" =~ ^[Yy]$ ]] || return 1
    fi
}

# Bind selectors to a destination profile in one state update, removing each
# from any other profile that claimed the same traffic. Prints the new state.
# Usage: buildRelayStateWithSelectors <destinationId> <selectors-json-array> [new-profile-json]
buildRelayStateWithSelectors() {
    local destinationId=$1 selectors=$2 newProfile=${3:-null}
    jq --arg destinationId "${destinationId}" --argjson selectors "${selectors}" --argjson newProfile "${newProfile}" "${relaySelectorJqDefs}"'
        (if $newProfile == null then . else .profiles += [$newProfile] end) |
        reduce $selectors[] as $selector (.;
            .profiles |= map(
                .selectors = (
                    [.selectors[]? | subtractSelector(.; $selector)] +
                    (if .id == $destinationId then [$selector] else [] end)
                )
            )
        ) |
        .profiles |= map(select((.selectors | length) > 0))
    ' "${relayStateFile}"
}

# Delete relay outbound files that no profile in the current state uses.
removeOrphanedRelayFiles() {
    local file name
    for file in "${configPath}"relay_*outbound.json; do
        [[ -f "${file}" ]] || continue
        name=${file##*/}
        relayProfileFileIsSafe "${name}" || continue
        jq -e --arg file "${name}" 'any(.profiles[]?; .outboundFile == $file)' "${relayStateFile}" >/dev/null \
            || rm -f "${file}"
    done
}

refreshRelaySubscriptionCron() {
    ensureRelayStateV2 || return 1
    if jq -e 'any(.profiles[]?; .source == "subscription")' "${relayStateFile}" >/dev/null; then
        installCronRelaySubscription
    else
        removeCronRelaySubscription
    fi
}

# Install a generated outbound and bind the profile's selectors to it.
installRelayProfile() {
    local profile=$1 generatedOutbound=$2 outboundFile profileId selectors emptyProfile
    outboundFile=$(jq -r '.outboundFile' <<<"${profile}")
    profileId=$(jq -r '.id' <<<"${profile}")
    selectors=$(jq -c '.selectors' <<<"${profile}")
    emptyProfile=$(jq -c '.selectors = []' <<<"${profile}")
    cp "${generatedOutbound}" "${configPath}${outboundFile}" || return 1
    chmod 600 "${configPath}${outboundFile}"
    updateRelayState buildRelayStateWithSelectors "${profileId}" "${selectors}" "${emptyProfile}"
}

activateRelayProfile() {
    local profile=$1 generatedOutbound=$2 outboundFile
    outboundFile=$(jq -r '.outboundFile' <<<"${profile}")
    relayProfileFileIsSafe "${outboundFile}" || return 1
    ensureRelayStateV2 || return 1
    commitRelayChange "启用新中转配置" installRelayProfile "${profile}" "${generatedOutbound}" || return 1
    restartXray
}

# Attach several selectors to an existing upstream with one validation and
# one restart.
attachRelaySelectors() {
    local destinationId=$1 selectors=$2 profileName
    ensureRelayStateV2 || return 1
    profileName=$(jq -r --arg id "${destinationId}" 'first(.profiles[] | select(.id == $id)).name // empty' "${relayStateFile}")
    [[ -n "${profileName}" ]] || return 1
    commitRelayChange "绑定入口规则" updateRelayState buildRelayStateWithSelectors "${destinationId}" "${selectors}" || return 1
    restartXray || return 1
    echoContent green " ---> $(jq 'length' <<<"${selectors}") 个入口规则已绑定到现有上游: ${profileName}"
}

selectRelayUdpMode() {
    local udpRelayStatus
    relaySelectedUdpMode=direct
    read -r -p "UDP 也通过此上游转发吗？[y/N]:" udpRelayStatus
    [[ "${udpRelayStatus}" =~ ^[Yy]$ ]] && relaySelectedUdpMode=shared
}

# Add a Shadowsocks or VLESS Reality relay rule from a sing-box JSON subscription.
setupRelaySubscription() {
    local profileName=$1 profileId=$2
    local outboundTag="relay_profile_${profileId}" outboundFile="relay_${profileId}_outbound.json"
    selectRelayUdpMode
    local subscriptionUrl tempDir subscriptionFile supportedNodes nodeCount nodeIndex selectedTag generatedOutbound
    read -r -p "请输入 sing-box JSON 订阅地址:" subscriptionUrl
    [[ -z "${subscriptionUrl}" ]] && echoContent red " ---> 订阅地址不能为空" && return 1
    tempDir=$(mktemp -d /tmp/xray-relay-subscription.XXXXXX) || return 1
    subscriptionFile="${tempDir}/subscription.json"
    generatedOutbound="${tempDir}/${outboundFile}"
    fetchRelaySubscription "${subscriptionUrl}" "${subscriptionFile}" || {
        rm -rf "${tempDir}"
        return 1
    }
    supportedNodes=$(getRelayNodesFromSingBoxSubscription "${subscriptionFile}") || {
        rm -rf "${tempDir}"
        return 1
    }
    nodeCount=$(jq 'length' <<<"${supportedNodes}")
    if ((nodeCount == 0)); then
        echoContent red " ---> 订阅中没有可用的 Shadowsocks 或 VLESS Reality 节点"
        rm -rf "${tempDir}"
        return 1
    elif ((nodeCount == 1)); then
        selectedTag=$(jq -r '.[0].tag' <<<"${supportedNodes}")
    else
        jq -r 'to_entries[] |
            "\(.key + 1).\(.value.tag) [" +
            (if .value._relayType == "vless-reality" then "VLESS Reality" else "Shadowsocks" end) +
            "] -> \(.value.server):\(.value.server_port)"
        ' <<<"${supportedNodes}"
        read -r -p "请选择上游节点:" nodeIndex
        if [[ ! "${nodeIndex}" =~ ^[0-9]+$ ]] || ((nodeIndex < 1 || nodeIndex > nodeCount)); then
            rm -rf "${tempDir}"
            return 1
        fi
        selectedTag=$(jq -r --argjson index "$((nodeIndex - 1))" '.[$index].tag' <<<"${supportedNodes}")
    fi
    buildRelayOutboundFromSingBoxSubscription "${subscriptionFile}" "${selectedTag}" "${outboundTag}" "${generatedOutbound}" || {
        echoContent red " ---> 节点参数不完整或无法转换为 Xray 出站"
        rm -rf "${tempDir}"
        return 1
    }
    local profile
    profile=$(jq -n --arg id "${profileId}" --arg name "${profileName}" --argjson selectors "${relaySelectedSelectors}" \
        --arg outboundTag "${outboundTag}" --arg outboundFile "${outboundFile}" --arg url "${subscriptionUrl}" --arg selectedTag "${selectedTag}" \
        --arg nodeType "${relayBuiltSubscriptionType}" --arg protocol "${relayBuiltProtocol}" --arg label "${relayBuiltLabel}" \
        --arg address "${relayBuiltAddress}" --arg port "${relayBuiltPort}" --arg udpMode "${relaySelectedUdpMode}" '
        {id:$id,name:$name,source:"subscription",selectors:$selectors,outboundTag:$outboundTag,outboundFile:$outboundFile,
         subscription:{format:"sing-box-json",url:$url,selectedTag:$selectedTag,nodeType:$nodeType},
         tcp:{mode:"relay",protocol:$protocol,label:$label,address:$address,port:$port,bbrProfile:""},
         udp:(if $udpMode == "shared" then {mode:"shared",protocol:$protocol,label:$label,address:$address,port:$port,bbrProfile:""} else {mode:"direct",protocol:"",label:"直连",address:"",port:"",bbrProfile:""} end)}')
    activateRelayProfile "${profile}" "${generatedOutbound}" || {
        rm -rf "${tempDir}"
        return 1
    }
    rm -rf "${tempDir}"
    echoContent green " ---> 中转规则 ${profileName} 已启用: ${selectedTag} -> ${relayBuiltAddress}:${relayBuiltPort}"
}

# Generate one upstream outbound. The third argument indicates whether the outbound carries UDP.
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
    if ! isValidPort "${relayPort}"; then
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

# Rebuild the relay routing from all profiles; inbounds that are not bound keep their existing routing.
rebuildRelayRouting() {
    local routingFile="${configPath}09_routing.json"
    # Other menus (reinstall, global IPv6/WARP modes) may have deleted it.
    [[ -f "${routingFile}" ]] || echo '{"routing":{"rules":[]}}' >"${routingFile}" || return 1
    ensureRelayStateV2 || return 1
    local relayRules managedTags newConfig
    relayRules=$(jq '
        [.profiles[]? as $profile |
            $profile.selectors[]? |
            {profile:$profile,selector:.}
        ] as $bindings |
        (
            [$bindings[] | select(((.selector.users // []) | length) > 0)] +
            [$bindings[] | select(((.selector.users // []) | length) == 0)]
        ) as $orderedBindings |
      [$orderedBindings[] |
        .profile as $profile |
        .selector as $selector |
        ($selector.users // []) as $users |
        [({type:"field",inboundTag:$selector.inboundTags,network:"tcp",outboundTag:$profile.outboundTag} +
            if ($users | length) > 0 then {user:$users} else {} end)] +
        (if $profile.udp.mode == "shared" then
            [({type:"field",inboundTag:$selector.inboundTags,network:"udp",outboundTag:$profile.outboundTag} +
                if ($users | length) > 0 then {user:$users} else {} end)]
         else [] end)
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
    echo "${newConfig}" >"${routingFile}.tmp.$$" && mv "${routingFile}.tmp.$$" "${routingFile}"
}

# Re-apply relay rules after something else rewrote or deleted
# 09_routing.json, so relay state and live routing cannot drift apart.
syncRelayRouting() {
    [[ -f "${relayStateFile}" ]] || return 0
    jq -e '(.profiles // []) | length > 0' "${relayStateFile}" >/dev/null 2>&1 || return 0
    rebuildRelayRouting
}

setupRelayManual() {
    local profileName=$1 profileId=$2
    local outboundTag="relay_profile_${profileId}" outboundFile="relay_${profileId}_outbound.json"
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
    profile=$(jq -n --arg id "${profileId}" --arg name "${profileName}" --argjson selectors "${relaySelectedSelectors}" \
        --arg outboundTag "${outboundTag}" --arg outboundFile "${outboundFile}" --arg protocol "${relayBuiltProtocol}" \
        --arg label "${relayBuiltLabel}" --arg address "${relayBuiltAddress}" --arg port "${relayBuiltPort}" \
        --arg bbrProfile "${relayBuiltBbrProfile}" --arg udpMode "${relaySelectedUdpMode}" '
        {id:$id,name:$name,source:"manual",selectors:$selectors,outboundTag:$outboundTag,outboundFile:$outboundFile,
         tcp:{mode:"relay",protocol:$protocol,label:$label,address:$address,port:$port,bbrProfile:$bbrProfile},
         udp:(if $udpMode == "shared" then {mode:"shared",protocol:$protocol,label:$label,address:$address,port:$port,bbrProfile:$bbrProfile} else {mode:"direct",protocol:"",label:"直连",address:"",port:"",bbrProfile:""} end)}')
    activateRelayProfile "${profile}" "${generatedOutbound}" || {
        rm -rf "${tempDir}"
        return 1
    }
    rm -rf "${tempDir}"
    echoContent green " ---> 中转规则 ${profileName} 已启用"
}

selectRelayDestination() {
    ensureRelayStateV2 || return 1
    local count selection newOption
    count=$(jq '.profiles | length' "${relayStateFile}")
    relayUseExistingProfile=false
    relaySelectedDestinationId=
    ((count == 0)) && return 0

    echoContent skyBlue "\n请选择目标上游"
    jq -r '.profiles | to_entries[] |
        "\(.key + 1).\(.value.name) -> \(.value.tcp.label) \(.value.tcp.address):\(.value.tcp.port)"
    ' "${relayStateFile}"
    newOption=$((count + 1))
    echoContent yellow "${newOption}.新建上游"
    read -r -p "请选择:" selection
    if [[ ! "${selection}" =~ ^[0-9]+$ ]] || ((selection < 1 || selection > newOption)); then
        echoContent red " ---> 上游选项无效"
        return 1
    fi
    if ((selection <= count)); then
        relayUseExistingProfile=true
        relaySelectedDestinationId=$(jq -r --argjson index "$((selection - 1))" '.profiles[$index].id' "${relayStateFile}")
    fi
}

setupRelay() {
    echoContent skyBlue "\n新增入口规则"
    echoContent yellow "# 一个上游可绑定多个入口；指定账号优先于「全部 UUID」兜底规则\n"
    selectRelayTargets || return
    selectRelayDestination || return
    if [[ "${relayUseExistingProfile}" == "true" ]]; then
        local selector
        # The selector list is read from fd 3 so the y/N prompt inside
        # relayTargetsAvailable still reads from the terminal.
        while read -r -u 3 selector; do
            relayTargetsAvailable "${selector}" "${relaySelectedDestinationId}" || return
        done 3< <(jq -c '.[]' <<<"${relaySelectedSelectors}")
        attachRelaySelectors "${relaySelectedDestinationId}" "${relaySelectedSelectors}"
        return
    fi
    local selector
    while read -r -u 3 selector; do
        relayTargetsAvailable "${selector}" || return
    done 3< <(jq -c '.[]' <<<"${relaySelectedSelectors}")

    echoContent skyBlue "\n请选择上游配置来源"
    echoContent yellow "1.sing-box JSON 订阅中的 Shadowsocks / VLESS Reality 节点"
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
    echoContent skyBlue "\n当前中转上游"
    jq -r "${relaySelectorJqDefs}"'.profiles | to_entries[] |
        "\(.key + 1). \(.value.name)\n" +
        (.value.selectors | to_entries | map(
            "   入口 \(.key + 1): \(.value.inboundTags | join(", ")) / 账号: " +
            (if ((.value.users // []) | length) > 0 then
                ([.value.users[] | displayUser] | join(", "))
             else "全部 UUID" end)
        ) | join("\n")) +
        "\n   TCP : \(.value.tcp.label) -> \(.value.tcp.address):\(.value.tcp.port)\n" +
        "   UDP : \(if .value.udp.mode == "shared" then (.value.udp.label + " -> " + .value.udp.address + ":" + .value.udp.port) else "直连" end)\n" +
        "   来源: \(if .value.source == "subscription" then "订阅自动更新" else "手动" end)"
    ' "${relayStateFile}"
}

updateRelaySubscriptionProfile() {
    local profileId=$1 profile subscriptionUrl selectedTag outboundTag outboundFile tempDir subscriptionFile generatedOutbound
    local supportedNodes preferredNodeType newState
    profile=$(jq -c --arg id "${profileId}" 'first(.profiles[] | select(.id == $id))' "${relayStateFile}") || return 1
    subscriptionUrl=$(jq -r '.subscription.url' <<<"${profile}")
    selectedTag=$(jq -r '.subscription.selectedTag' <<<"${profile}")
    preferredNodeType=$(jq -r '.subscription.nodeType // if .tcp.protocol == "reality" then "vless-reality" else "shadowsocks" end' <<<"${profile}")
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
    supportedNodes=$(getRelayNodesFromSingBoxSubscription "${subscriptionFile}") || {
        rm -rf "${tempDir}"
        return 1
    }
    if ! jq -e --arg tag "${selectedTag}" 'any(.[]; .tag == $tag)' <<<"${supportedNodes}" >/dev/null; then
        selectedTag=$(jq -r --arg nodeType "${preferredNodeType}" 'first(.[] | select(._relayType == $nodeType)).tag // empty' <<<"${supportedNodes}")
    fi
    if [[ -z "${selectedTag}" ]]; then
        echoContent red " ---> 更新后的订阅中没有同类型可用节点，保留旧配置"
        rm -rf "${tempDir}"
        return 1
    fi
    buildRelayOutboundFromSingBoxSubscription "${subscriptionFile}" "${selectedTag}" "${outboundTag}" "${generatedOutbound}" || {
        echoContent red " ---> 更新后的节点参数不完整，保留旧配置"
        rm -rf "${tempDir}"
        return 1
    }
    newState=$(jq --arg id "${profileId}" --arg tag "${selectedTag}" --arg nodeType "${relayBuiltSubscriptionType}" \
        --arg protocol "${relayBuiltProtocol}" --arg label "${relayBuiltLabel}" \
        --arg address "${relayBuiltAddress}" --arg port "${relayBuiltPort}" '
        .profiles |= map(if .id == $id then
            .subscription.selectedTag = $tag |
            .subscription.nodeType = $nodeType |
            .tcp.protocol = $protocol | .tcp.label = $label | .tcp.address = $address | .tcp.port = $port |
            if .udp.mode == "shared" then
                .udp.protocol = $protocol | .udp.label = $label | .udp.address = $address | .udp.port = $port
            else . end
        else . end)
    ' "${relayStateFile}") || {
        rm -rf "${tempDir}"
        return 1
    }
    if [[ -f "${configPath}${outboundFile}" ]] && cmp -s "${generatedOutbound}" "${configPath}${outboundFile}"; then
        writeRelayState "${newState}" || {
            rm -rf "${tempDir}"
            return 1
        }
        echoContent green " ---> $(jq -r '.name' <<<"${profile}"): 订阅没有变化"
        rm -rf "${tempDir}"
        return 0
    fi
    if ! commitRelayChange "订阅更新" installRelayOutbound "${generatedOutbound}" "${outboundFile}" "${newState}"; then
        echoContent red " ---> $(jq -r '.name' <<<"${profile}"): 新订阅配置验证失败，已保留旧配置"
        rm -rf "${tempDir}"
        return 1
    fi
    relaySubscriptionChanged=true
    echoContent green " ---> $(jq -r '.name' <<<"${profile}"): 已更新到 ${selectedTag} -> ${relayBuiltAddress}:${relayBuiltPort}"
    rm -rf "${tempDir}"
}

# Install a refreshed outbound file together with its updated state.
installRelayOutbound() {
    local generatedOutbound=$1 outboundFile=$2 newState=$3
    cp "${generatedOutbound}" "${configPath}${outboundFile}" || return 1
    chmod 600 "${configPath}${outboundFile}"
    writeRelayState "${newState}"
}

updateRelaySubscription() {
    withRelayLock updateAllRelaySubscriptions
}

updateAllRelaySubscriptions() {
    ensureRelayStateV2 || return 1
    local profileId updateFailed=false
    relaySubscriptionChanged=false
    while read -r profileId; do
        updateRelaySubscriptionProfile "${profileId}" || updateFailed=true
    done < <(jq -r '.profiles[]? | select(.source == "subscription").id' "${relayStateFile}")
    if [[ "${relaySubscriptionChanged}" == "true" ]]; then
        restartXray || updateFailed=true
    fi
    [[ "${updateFailed}" == "false" ]]
}

removeRelaySelector() {
    ensureRelayStateV2 || return
    local bindings count selection profileId selectorIndex
    bindings=$(jq -c '[
        .profiles[] as $profile |
        $profile.selectors | to_entries[] |
        {
            profileId:$profile.id,
            profileName:$profile.name,
            selectorIndex:.key,
            inboundTags:.value.inboundTags,
            users:(.value.users // [])
        }
    ]' "${relayStateFile}") || return 1
    count=$(jq 'length' <<<"${bindings}")
    ((count == 0)) && echoContent yellow " ---> 当前没有入口规则" && return
    jq -r "${relaySelectorJqDefs}"'to_entries[] |
        "\(.key + 1).\(.value.profileName) <- \(.value.inboundTags | join(", ")) / 账号: " +
        (if (.value.users | length) > 0 then
            ([.value.users[] | displayUser] | join(", "))
         else "全部 UUID" end)
    ' <<<"${bindings}"
    read -r -p "请选择要删除的入口规则:" selection
    if [[ ! "${selection}" =~ ^[0-9]+$ ]] || ((selection < 1 || selection > count)); then
        echoContent red " ---> 入口规则选项无效"
        return
    fi
    profileId=$(jq -r --argjson index "$((selection - 1))" '.[$index].profileId' <<<"${bindings}")
    selectorIndex=$(jq -r --argjson index "$((selection - 1))" '.[$index].selectorIndex' <<<"${bindings}")
    commitRelayChange "删除入口规则" updateRelayState jq --arg id "${profileId}" --argjson selectorIndex "${selectorIndex}" '
        .profiles |= map(if .id == $id then del(.selectors[$selectorIndex]) else . end) |
        .profiles |= map(select((.selectors | length) > 0))
    ' "${relayStateFile}" || return 1
    restartXray || return 1
    echoContent green " ---> 入口规则已删除"
}

removeRelayProfile() {
    ensureRelayStateV2 || return
    local count selection
    count=$(jq '.profiles | length' "${relayStateFile}")
    ((count == 0)) && echoContent yellow " ---> 当前没有中转上游" && return
    jq -r '.profiles | to_entries[] | "\(.key + 1).\(.value.name) [入口规则: \(.value.selectors | length) 条]"' "${relayStateFile}"
    read -r -p "请选择要删除的上游[其全部入口规则也会删除]:" selection
    if [[ ! "${selection}" =~ ^[0-9]+$ ]] || ((selection < 1 || selection > count)); then
        echoContent red " ---> 上游选项无效"
        return
    fi
    # The outbound file is removed by commitRelayChange once nothing uses it.
    commitRelayChange "删除中转上游" updateRelayState jq --argjson index "$((selection - 1))" \
        'del(.profiles[$index])' "${relayStateFile}" || return 1
    restartXray || return 1
    echoContent green " ---> 中转上游已删除"
}

removeRelay() {
    ensureRelayStateV2 || return
    commitRelayChange "停用全部中转" writeRelayState '{"version":2,"profiles":[]}' || return 1
    rm -f /opt/xray-agent/relay_config
    restartXray || return 1
    echoContent green " ---> 所有中转规则已停用，相关入站恢复原有分流"
}

# Remove deleted accounts from every selector. A selector that only listed
# those accounts is dropped entirely: an empty users list would otherwise
# mean "the whole inbound" and silently widen the rule.
# Usage: removeRelayUsers <xray-email>...
removeRelayUsers() {
    [[ -f "${relayStateFile}" ]] || return 0
    local emails
    emails=$(printf '%s\n' "$@" | jq -R . | jq -sc .)
    jq -e --argjson emails "${emails}" 'any(.profiles[]?.selectors[]?; ((.users // []) - $emails) != (.users // []))' \
        "${relayStateFile}" >/dev/null 2>&1 || return 0
    commitRelayChange "清理已删除账号的中转规则" updateRelayState jq --argjson emails "${emails}" '
        .profiles |= map(.selectors |= map(
            if ((.users // []) | length) == 0 then .
            else (.users -= $emails) | select((.users | length) > 0) end
        )) |
        .profiles |= map(select((.selectors | length) > 0))
    ' "${relayStateFile}"
}

manageRelay() {
    if [[ -z "${configPath}" ]]; then
        echoContent red " ---> 未安装，请使用脚本安装"
        return
    fi
    ensureRelayStateV2 || return
    local relayType profileCount selectorCount
    while true; do
        ensureRelayStateV2 || return
        profileCount=$(jq '.profiles | length' "${relayStateFile}")
        selectorCount=$(jq '[.profiles[]?.selectors[]?] | length' "${relayStateFile}")
        echoContent skyBlue "\n功能 1/${totalProgress} : 多规则中转管理"
        echoContent red "\n=============================================================="
        echoContent yellow "# 当前上游: ${profileCount} 个 / 入口规则: ${selectorCount} 条"
        echoContent yellow "1.新增入口规则"
        echoContent yellow "2.查看全部上游与入口"
        echoContent yellow "3.立即更新所有订阅规则"
        echoContent yellow "4.删除一条入口规则"
        echoContent yellow "5.删除一个上游"
        echoContent yellow "6.停用全部中转"
        echoContent yellow "0.返回主菜单"
        echoContent red "=============================================================="
        read -r -p "请选择:" relayType
        case ${relayType} in
            1) withRelayLock setupRelay ;;
            2) showRelayConfig ;;
            3) updateRelaySubscription ;;
            4) withRelayLock removeRelaySelector ;;
            5) withRelayLock removeRelayProfile ;;
            6) withRelayLock removeRelay ;;
            0) return ;;
            *) echoContent red " ---> 请输入 0-6" ;;
        esac
        read -r -p "按回车键继续..."
    done
}
