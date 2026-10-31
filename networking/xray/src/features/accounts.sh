# Custom UUID
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
            return 1
        fi
    fi
}

# Custom account tag. Xray appends an email suffix per protocol internally, and subscriptions also use it to identify nodes.
customUserEmail() {
    read -r -p "请输入账号标签(tag)，例如 vision_jp_us，[回车]使用 UUID 前缀:" currentCustomEmail
    echo
    if [[ -z "${currentCustomEmail}" ]]; then
        currentCustomEmail=$(echo "${currentCustomUUID}" | cut -d "-" -f 1)
        echoContent yellow "账号标签: ${currentCustomEmail}\n"
    else
        if ! validateXrayUserTag "${currentCustomEmail}"; then
            echoContent red " ---> 标签仅支持字母、数字、点、下划线和连字符，且最长 64 位"
            return 1
        fi
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
            echoContent red " ---> 账号标签不可重复"
            return 1
        fi
    fi
}

# Scan the actual inbound config and return only the protocols that are installed and support account writes.
# Protocols are identified from the JSON content; clientType is only an adapter for each protocol's account structure.
discoverAccountProtocols() {
    accountProtocolFiles=()
    accountProtocolKinds=()
    accountProtocolClientTypes=()
    accountProtocolLabels=()

    local inboundConfig protocol network security version inboundTag port
    local kind clientType label
    while IFS= read -r inboundConfig; do
        protocol=$(jq -r '.inbounds[0].protocol // empty' "${inboundConfig}" 2>/dev/null)
        network=$(jq -r '.inbounds[0].streamSettings.network // empty' "${inboundConfig}" 2>/dev/null)
        security=$(jq -r '.inbounds[0].streamSettings.security // empty' "${inboundConfig}" 2>/dev/null)
        version=$(jq -r '.inbounds[0].settings.version // empty' "${inboundConfig}" 2>/dev/null)
        inboundTag=$(jq -r '.inbounds[0].tag // "untagged"' "${inboundConfig}" 2>/dev/null)
        port=$(jq -r '.inbounds[0].port // "unknown"' "${inboundConfig}" 2>/dev/null)
        kind=
        clientType=
        label=

        case "${protocol}:${network}:${security}" in
            vless:tcp:tls)
                kind=vless
                clientType=0
                label="VLESS + TCP + TLS Vision"
                ;;
            vless:ws:*)
                kind=vless
                clientType=1
                label="VLESS + WebSocket + TLS"
                ;;
            vless:tcp:reality)
                kind=vless
                clientType=3
                label="VLESS + Reality + Vision"
                ;;
            vless:xhttp:reality)
                kind=vless
                clientType=12
                label="VLESS + XHTTP + Reality"
                ;;
            vless:xhttp:*)
                kind=vless
                clientType=14
                label="VLESS + XHTTP + TLS"
                ;;
            hysteria:hysteria:tls)
                [[ "${version}" == "2" ]] || continue
                kind=hysteria2
                clientType=-
                label="Hysteria2"
                ;;
            *) continue ;;
        esac

        accountProtocolFiles+=("${inboundConfig}")
        accountProtocolKinds+=("${kind}")
        accountProtocolClientTypes+=("${clientType}")
        accountProtocolLabels+=("${label} [${inboundTag}, port ${port}]")
    done < <(find "${configPath}" -maxdepth 1 -type f -name '*inbounds.json' -print 2>/dev/null | sort)
}

# Choose which installed protocols the new UUID is added to; press Enter to add it to all of them.
selectUserProtocols() {
    discoverAccountProtocols
    if ((${#accountProtocolFiles[@]} == 0)); then
        echoContent red " ---> 未检测到可添加账号的协议"
        return 1
    fi

    echoContent skyBlue "\n请选择新 UUID 要加入的协议"
    local index
    for ((index = 0; index < ${#accountProtocolFiles[@]}; index++)); do
        echoContent yellow "$((index + 1)).${accountProtocolLabels[index]}"
    done
    local selection
    read -r -p "请选择[可多选，例:1,3；回车=全部]:" selection
    selection=${selection//，/,}

    userSelectedProtocolIndexes=()
    if [[ -z "${selection}" ]]; then
        userSelectedProtocolIndexes=("${!accountProtocolFiles[@]}")
        return 0
    fi

    local -a choices=()
    local choice selectedIndex existing
    IFS=',' read -r -a choices <<<"${selection}"
    for choice in "${choices[@]}"; do
        choice=${choice//[[:space:]]/}
        if [[ ! "${choice}" =~ ^[0-9]+$ ]] || ((choice < 1 || choice > ${#accountProtocolFiles[@]})); then
            echoContent red " ---> 协议选项无效: ${choice}"
            return 1
        fi
        selectedIndex=$((choice - 1))
        existing=false
        for index in "${userSelectedProtocolIndexes[@]}"; do
            [[ "${index}" == "${selectedIndex}" ]] && existing=true
        done
        [[ "${existing}" == "false" ]] && userSelectedProtocolIndexes+=("${selectedIndex}")
    done
}

appendVlessUser() {
    local inboundConfig=$1 clientType=$2 userUUID=$3 userTag=$4
    local client temporaryConfig
    client=$(buildXrayClient "${clientType}" "${userUUID}" "${userTag}") || return 1
    temporaryConfig=$(mktemp "${inboundConfig}.tmp.XXXXXX") || return 1
    if jq --argjson client "${client}" '
        .inbounds[0].settings.clients = ((.inbounds[0].settings.clients // []) + [$client])
    ' "${inboundConfig}" >"${temporaryConfig}"; then
        chmod --reference="${inboundConfig}" "${temporaryConfig}" 2>/dev/null || chmod 600 "${temporaryConfig}"
        mv -f "${temporaryConfig}" "${inboundConfig}"
    else
        rm -f "${temporaryConfig}"
        return 1
    fi
}

appendHysteria2User() {
    local inboundConfig=$1 userUUID=$2 userTag=$3
    local temporaryConfig
    temporaryConfig=$(mktemp "${inboundConfig}.tmp.XXXXXX") || return 1
    # Always write "clients" (see normalizeHysteria2UserField).
    if jq --arg auth "${userUUID}" --arg email "${userTag}-Hysteria2" '
        .inbounds[0].settings |= (
            .clients = ((.clients // .users // []) + [{auth: $auth, level: 0, email: $email}]) | del(.users)
        )
    ' "${inboundConfig}" >"${temporaryConfig}"; then
        chmod --reference="${inboundConfig}" "${temporaryConfig}" 2>/dev/null || chmod 600 "${temporaryConfig}"
        mv -f "${temporaryConfig}" "${inboundConfig}"
    else
        rm -f "${temporaryConfig}"
        return 1
    fi
}

collectAccounts() {
    discoverAccountProtocols
    discoveredAccounts='[]'
    local index protocol inboundConfig user userId userEmail userTag

    for index in "${!accountProtocolFiles[@]}"; do
        protocol=${accountProtocolLabels[index]}
        inboundConfig=${accountProtocolFiles[index]}
        while read -r user; do
            userId=$(jq -r '.id // .uuid // .auth // .password // empty' <<<"${user}")
            userEmail=$(jq -r '.email // .name // .username // empty' <<<"${user}")
            [[ -z "${userId}" ]] && continue
            userTag=$(normalizeXrayEmail "${userEmail}")
            [[ -z "${userTag}" ]] && userTag="${userId}"
            discoveredAccounts=$(jq -c --arg id "${userId}" --arg tag "${userTag}" --arg protocol "${protocol}" '
                if any(.[]; .uuid == $id) then
                    map(if .uuid == $id then
                        .protocols = (if (.protocols | index($protocol)) == null then .protocols + [$protocol] else .protocols end)
                    else . end)
                else
                    . + [{uuid:$id,tag:$tag,protocols:[$protocol]}]
                end
            ' <<<"${discoveredAccounts}")
        done < <(jq -c '(.inbounds[0].settings.clients // .inbounds[0].settings.users // .inbounds[0].users // [])[]' "${inboundConfig}")
    done
}

listAccounts() {
    collectAccounts
    if [[ $(jq 'length' <<<"${discoveredAccounts}") -eq 0 ]]; then
        echoContent yellow " ---> 当前没有账号"
        return
    fi
    echoContent skyBlue "\n当前账号"
    jq -r 'to_entries[] |
        "\(.key + 1). tag: \(.value.tag)\n   UUID/auth: \(.value.uuid)\n   协议: \(.value.protocols | join(", "))"
    ' <<<"${discoveredAccounts}"
}

# Print the share links and QR-code links of one account, or of all of them.
# Only prints: the subscribe_local scratch files showAccounts writes are
# rebuilt from scratch by subscribe(), published subscriptions are untouched.
showAccountShareLinks() {
    local userCount selection userId=
    collectAccounts
    userCount=$(jq 'length' <<<"${discoveredAccounts}")
    if ((userCount == 0)); then
        echoContent yellow " ---> 当前没有账号"
        return
    fi
    if ((userCount > 1)); then
        jq -r 'to_entries[] | "\(.key + 1):\(.value.tag) [\(.value.protocols | join(", "))]"' <<<"${discoveredAccounts}"
        read -r -p "请选择账号编号，[回车]查看全部:" selection
        if [[ -n "${selection}" ]]; then
            if [[ ! "${selection}" =~ ^[0-9]+$ || ${selection} -lt 1 || ${selection} -gt ${userCount} ]]; then
                echoContent red " ---> 选择错误"
                return 1
            fi
            userId=$(jq -r --argjson index "$((selection - 1))" '.[$index].uuid' <<<"${discoveredAccounts}")
        fi
    fi
    showAccounts 1 "${userId}"
}

# Add a user
addUser() {
    read -r -p "请输入要添加的账号数量:" userNum
    echo
    if [[ ! "${userNum}" =~ ^[0-9]+$ ]] || ((userNum <= 0)); then
        echoContent red " ---> 输入有误，请重新输入"
        return 1
    fi
    selectUserProtocols || return 1

    while [[ ${userNum} -gt 0 ]]; do
        readConfigHostPathUUID
        ((userNum--)) || true

        customUUID || return 1
        customUserEmail || return 1

        uuid=${currentCustomUUID}
        email=${currentCustomEmail}

        local selectedIndex
        for selectedIndex in "${userSelectedProtocolIndexes[@]}"; do
            case "${accountProtocolKinds[selectedIndex]}" in
                vless)
                    appendVlessUser "${accountProtocolFiles[selectedIndex]}" "${accountProtocolClientTypes[selectedIndex]}" "${uuid}" "${email}" || return 1
                    ;;
                hysteria2)
                    appendHysteria2User "${accountProtocolFiles[selectedIndex]}" "${uuid}" "${email}" || return 1
                    ;;
            esac
        done

        echoContent green " ---> 已添加 ${email}: ${uuid}"
    done
    restartXray || return 1
    echoContent green " ---> 添加完成"
    echoContent yellow " ---> 如需更新客户端订阅，请前往独立的订阅管理"
}
# Remove a user
removeUser() {
    local candidateConfig userCount delUserIndex userId temporaryConfig index email
    local -a removedEmails=()
    collectAccounts
    userCount=$(jq 'length' <<<"${discoveredAccounts}")
    if ((userCount == 0)); then
        echoContent red " ---> 未找到可删除的用户"
        return 1
    fi

    jq -r 'to_entries[] |
        "\(.key + 1):\(.value.tag) [UUID/auth: \(.value.uuid)]\n   协议: \(.value.protocols | join(", "))"
    ' <<<"${discoveredAccounts}"
    read -r -p "请选择要删除的账号编号[将从所属全部协议删除]:" delUserIndex
    if [[ ! "${delUserIndex}" =~ ^[0-9]+$ || ${delUserIndex} -lt 1 || ${delUserIndex} -gt ${userCount} ]]; then
        echoContent red " ---> 选择错误"
        return 1
    fi

    userId=$(jq -r --argjson index "$((delUserIndex - 1))" '.[$index].uuid // empty' <<<"${discoveredAccounts}")
    if [[ -z "${userId}" ]]; then
        echoContent red " ---> 无法识别该用户的 UUID/auth，未修改配置"
        return 1
    fi

    for index in "${!accountProtocolFiles[@]}"; do
        candidateConfig=${accountProtocolFiles[index]}
        if ! jq -e --arg userId "${userId}" '
            any((.inbounds[]?.settings.clients[]?, .inbounds[]?.settings.users[]?, .inbounds[]?.users[]?);
                (.id // .uuid // .auth // .password // "") == $userId)
        ' "${candidateConfig}" >/dev/null 2>&1; then
            continue
        fi

        while IFS= read -r email; do
            [[ -n "${email}" ]] && removedEmails+=("${email}")
        done < <(jq -r --arg userId "${userId}" '
            (.inbounds[]?.settings.clients[]?, .inbounds[]?.settings.users[]?, .inbounds[]?.users[]?) |
            select((.id // .uuid // .auth // .password // "") == $userId) | .email // empty
        ' "${candidateConfig}")

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
    done

    # Drop relay bindings for the deleted account, so a future account with
    # the same tag does not silently inherit them.
    if ((${#removedEmails[@]} > 0)); then
        withRelayLock removeRelayUsers "${removedEmails[@]}" || return 1
    fi
    restartXray || return 1
    echoContent green " ---> 删除完成"
    echoContent yellow " ---> 如需更新客户端订阅，请前往独立的订阅管理"
}
# Account management
manageAccount() {
    if [[ -z "${configPath}" ]]; then
        echoContent red " ---> 未安装"
        return
    fi

    local manageAccountStatus
    while true; do
        echoContent skyBlue "\n功能 1/${totalProgress} : 账号管理"
        echoContent red "\n=============================================================="
        echoContent yellow "# 这里只管理服务端账号，不生成或修改订阅"
        echoContent yellow "# 添加账号时可自定义 UUID、tag 和目标协议\n"
        echoContent yellow "# 删除账号会从该 UUID 所属的全部协议中移除\n"
        echoContent yellow "1.查看账号"
        echoContent yellow "2.添加账号"
        echoContent yellow "3.删除账号"
        echoContent yellow "4.查看分享链接和二维码"
        echoContent yellow "0.返回主菜单"
        echoContent red "=============================================================="
        read -r -p "请输入:" manageAccountStatus
        case ${manageAccountStatus} in
            1) listAccounts ;;
            2) addUser ;;
            3) removeUser ;;
            4) showAccountShareLinks ;;
            0) return ;;
            *) echoContent red " ---> 选择错误" ;;
        esac
        read -r -p "按回车键继续..."
    done
}
