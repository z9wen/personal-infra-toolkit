removeNginx302() {
    # Check that the config file exists
    if [[ ! -f "${nginxConfigPath}xray-agent.conf" ]]; then
        echoContent red " ---> 配置文件不存在: ${nginxConfigPath}xray-agent.conf"
        echoContent yellow " ---> 请先完成 Xray 安装后再使用此功能"
        return 1
    fi

    # Use a temp file to avoid modifying the original file inside the loop
    local tmpFile="${nginxConfigPath}xray-agent.conf.tmp"
    cp "${nginxConfigPath}xray-agent.conf" "${tmpFile}"

    # Delete all return 302/301 lines (excluding those containing request_uri)
    sed -i '/return 30[12]/!b; /request_uri/b; d' "${tmpFile}"

    # Replace the original file
    mv "${tmpFile}" "${nginxConfigPath}xray-agent.conf"
}

# Check whether the 302 redirect succeeded
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

# Back up/restore the nginx file
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
# Add the 302 config
addNginx302() {
    local redirectUrl="$1"
    local redirectCode="302" # Always use 302

    # Check that the config file exists
    if [[ ! -f "${nginxConfigPath}xray-agent.conf" ]]; then
        echoContent red " ---> 配置文件不存在: ${nginxConfigPath}xray-agent.conf"
        echoContent yellow " ---> 请先完成 Xray 安装后再使用此功能"
        backupNginxConfig restoreBackup
        return 1
    fi

    # Validate the URL format
    if [[ ! "${redirectUrl}" =~ ^https?:// ]]; then
        echoContent red " ---> URL 格式错误，必须以 http:// 或 https:// 开头"
        backupNginxConfig restoreBackup
        return 1
    fi

    # Escape special characters (single quotes)
    redirectUrl="${redirectUrl//\'/\'\\\'\'}"

    # Read the line numbers of all `location / {` into an array
    local lineNumbers=()
    while IFS= read -r line; do
        lineNumbers+=("$(echo "${line}" | awk -F ":" '{print $1}')")
    done < <(grep -n "location / {" "${nginxConfigPath}xray-agent.conf")

    # Insert from back to front so line numbers do not shift
    local count=${#lineNumbers[@]}
    for ((i = count - 1; i >= 0; i--)); do
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

# Update the masquerade site
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

# Extra ports are dokodemo-door inbounds that forward to the main TLS port.
# Files: 02_dokodemodoor_inbounds_<port>[_default].json, plus
# 02_dokodemodoor_inbounds_hysteria_<port>.json when Hysteria2 is installed.
# The _default marker selects the port used in shared links/subscriptions.

# Print "<port> <file>" for every extra TCP port, sorted by port.
listCorePorts() {
    local file name port
    for file in "${configPath}"02_dokodemodoor_inbounds_*.json; do
        [[ -f "${file}" ]] || continue
        name=${file##*/}
        [[ "${name}" =~ ^02_dokodemodoor_inbounds_([0-9]+)(_default)?\.json$ ]] || continue
        port=${BASH_REMATCH[1]}
        echo "${port} ${file}"
    done | sort -n
}

# Remove exactly the files that belong to one extra port.
removeCorePortFiles() {
    local port=$1
    rm -f "${configPath}02_dokodemodoor_inbounds_${port}.json" \
        "${configPath}02_dokodemodoor_inbounds_${port}_default.json" \
        "${configPath}02_dokodemodoor_inbounds_hysteria_${port}.json"
}

writeCorePortFiles() {
    local port=$1 isDefault=$2 settingsPort=${customPort:-443} fileName
    fileName="${configPath}02_dokodemodoor_inbounds_${port}.json"
    [[ "${isDefault}" == "true" ]] && fileName="${configPath}02_dokodemodoor_inbounds_${port}_default.json"

    jq -n --argjson port "${port}" --argjson target "${settingsPort}" '{inbounds:[{
        listen:"0.0.0.0", port:$port, protocol:"dokodemo-door",
        settings:{address:"127.0.0.1", port:$target, network:"tcp", followRedirect:false},
        tag:("dokodemo-door-newPort-" + ($port | tostring))
    }]}' >"${fileName}" || return 1

    if [[ -n "${hysteria2Port}" ]]; then
        jq -n --argjson port "${port}" --argjson target "${hysteria2Port}" '{inbounds:[{
            listen:"0.0.0.0", port:$port, protocol:"dokodemo-door",
            settings:{address:"127.0.0.1", port:$target, network:"udp", followRedirect:false},
            tag:("dokodemo-door-newPort-hysteria-" + ($port | tostring))
        }]}' >"${configPath}02_dokodemodoor_inbounds_hysteria_${port}.json" || return 1
    fi
}

# Add the given ports; with a default port, move the _default marker to it.
applyCorePorts() {
    local defaultPort=$1 port existing file
    shift
    if [[ -n "${defaultPort}" ]]; then
        # Demote the previous default port instead of deleting it.
        for file in "${configPath}"02_dokodemodoor_inbounds_*_default.json; do
            [[ -f "${file}" ]] && mv "${file}" "${file%_default.json}.json"
        done
    fi
    for port in "$@"; do
        removeCorePortFiles "${port}"
        writeCorePortFiles "${port}" "$([[ "${port}" == "${defaultPort}" ]] && echo true || echo false)" || return 1
    done
}

# Parse "2053,2083 ,2087" into a validated, de-duplicated list in corePortList.
# Empty items (e.g. a trailing comma) are ignored; any invalid item fails.
parseCorePortList() {
    local input=${1//，/,} item
    local -a items=()
    corePortList=()
    IFS=',' read -r -a items <<<"${input}"
    for item in "${items[@]}"; do
        item=${item//[[:space:]]/}
        [[ -z "${item}" ]] && continue
        if ! isValidPort "${item}"; then
            echoContent red " ---> 端口无效: ${item}（需为 1-65535 的数字）"
            return 1
        fi
        [[ " ${corePortList[*]:-} " == *" ${item} "* ]] || corePortList+=("${item}")
    done
    ((${#corePortList[@]} > 0)) || {
        echoContent red " ---> 未输入任何端口"
        return 1
    }
}

# Add a new port
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
    local selectNewPortType newPort defaultPort portIndex selected port
    read -r -p "请选择:" selectNewPortType
    case "${selectNewPortType}" in
        1)
            listCorePorts | awk '{print NR ":" $1}'
            ;;
        2)
            read -r -p "请输入端口号:" newPort
            parseCorePortList "${newPort}" || return 1
            read -r -p "请输入默认的端口号，同时会更改订阅端口以及节点端口，[回车]默认443:" defaultPort
            defaultPort=${defaultPort//[[:space:]]/}
            if [[ -n "${defaultPort}" && " ${corePortList[*]} " != *" ${defaultPort} "* ]]; then
                echoContent red " ---> 默认端口必须是本次输入的端口之一"
                return 1
            fi

            for port in "${corePortList[@]}"; do
                allowPort "${port}"
                allowPort "${port}" "udp"
            done
            applyXrayConfigChange "添加端口" applyCorePorts "${defaultPort}" "${corePortList[@]}" || return 1
            echoContent green " ---> 添加完毕"
            restartXray || return 1
            ;;
        3)
            listCorePorts | awk '{print NR ":" $1}'
            read -r -p "请输入要删除的端口编号:" portIndex
            if [[ "${portIndex}" =~ ^[1-9][0-9]*$ ]]; then
                selected=$(listCorePorts | awk -v n="${portIndex}" 'NR == n {print $1}')
            fi
            if [[ -z "${selected}" ]]; then
                echoContent yellow "\n ---> 编号输入错误，请重新选择"
                return 1
            fi
            applyXrayConfigChange "删除端口" removeCorePortFiles "${selected}" || return 1
            echoContent green " ---> 端口 ${selected} 已删除"
            restartXray || return 1
            ;;
        *)
            echoContent red " ---> 选择错误"
            ;;
    esac
}

# Uninstall the script
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

    removeAllPanelXhttpLocations
    disablePortHopping
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
# Update the script
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
    if ! downloadFile "${scriptUrl}" "${temporaryScript}" --https-only; then
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

# View and check logs
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
            restartXray || return 1
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

# Script shortcut
aliasInstall() {
    # Get the actual path of the current script
    local currentScript
    currentScript="$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")"

    # Make sure the target directory exists
    if [[ ! -d "/opt/xray-agent" ]]; then
        mkdir -p /opt/xray-agent
    fi

    # Copy only on first install or when the file does not exist
    local targetScript="/opt/xray-agent/install.sh"
    local needCopy=false

    if [[ ! -f "$targetScript" ]]; then
        needCopy=true
    elif [[ "$currentScript" != "$targetScript" ]]; then
        # If the current script is not at the target location, copy it (update scenario)
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

    # Check for and create the symlink
    local xrayaType=false
    local symlinkPath=""

    if [[ -d "/usr/bin/" ]]; then
        symlinkPath="/usr/bin/xraya"
    elif [[ -d "/usr/sbin" ]]; then
        symlinkPath="/usr/sbin/xraya"
    fi

    if [[ -n "$symlinkPath" ]]; then
        # Check whether the symlink already exists and is correct
        if [[ -L "$symlinkPath" ]] && [[ "$(readlink "$symlinkPath")" == "$targetScript" ]]; then
            # The symlink already exists and is correct; no need to recreate it
            xrayaType=true
        else
            # Remove the old symlink or file
            rm -f "$symlinkPath"

            # Create a new symlink
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
