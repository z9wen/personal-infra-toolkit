# Hysteria management

# quicParams.bbrProfile exists since Xray v26.4.13 (XTLS/Xray-core#5869).
# Stable v26.3.27 silently ignores it, so the profile would have no effect.
hysteria2BbrProfileMinVersion=v26.4.13

bbrProfileSupported() {
    xrayVersionAtLeast "$(installedXrayVersion)" "${hysteria2BbrProfileMinVersion}"
}

writeHysteria2BbrProfile() {
    local profile=$1 file="${configPath}05_hysteria2_inbounds.json" updated
    updated=$(jq --arg profile "${profile}" '
        .inbounds[0].streamSettings.finalmask.quicParams.congestion = "bbr" |
        .inbounds[0].streamSettings.finalmask.quicParams.bbrProfile = $profile
    ' "${file}") || return 1
    echo "${updated}" >"${file}"
}

setHysteria2BbrProfile() {
    local profile=$1
    [[ "${profile}" =~ ^(conservative|standard|aggressive)$ ]] || return 1
    if [[ ! -f "${configPath}05_hysteria2_inbounds.json" ]]; then
        echoContent red " ---> 未安装Hysteria2"
        return 1
    fi
    if ! bbrProfileSupported; then
        echoContent red " ---> 当前 Xray $(installedXrayVersion) 不支持 bbrProfile，设置不会生效"
        echoContent yellow " ---> 需要 ${hysteria2BbrProfileMinVersion} 或更新版本，可在「Xray版本管理」中升级到预览版"
        return 1
    fi
    applyXrayConfigChange "切换Hysteria2拥塞控制" writeHysteria2BbrProfile "${profile}" || return 1
    restartXray || return 1
    hysteria2BbrProfile=${profile}
    echoContent green " ---> Hysteria2 QUIC拥塞控制已切换为: BBR/${profile}"
}

# Short description of the current HTTP/3 masquerade.
describeHysteria2Masquerade() {
    jq -r '.inbounds[0].streamSettings.hysteriaSettings.masquerade |
        if . == null then "未启用"
        elif .type == "file" then "本地静态网站 " + .dir
        elif .type == "proxy" then "反向代理 " + .url
        elif .type == "string" then "跳转 " + (.headers.Location // "")
        else .type end' "${configPath}05_hysteria2_inbounds.json"
}

writeHysteria2Masquerade() {
    local file="${configPath}05_hysteria2_inbounds.json" updated
    updated=$(jq --argjson masquerade "${hysteria2MasqueradeConfig}" '
        if $masquerade == null then del(.inbounds[0].streamSettings.hysteriaSettings.masquerade)
        else .inbounds[0].streamSettings.hysteriaSettings.masquerade = $masquerade end
    ' "${file}") || return 1
    echo "${updated}" >"${file}"
}

setHysteria2Masquerade() {
    local currentDir
    # Keep the directory a local-site masquerade already uses (e.g. a panel site).
    currentDir=$(jq -r '.inbounds[0].streamSettings.hysteriaSettings.masquerade | select(.type == "file") | .dir // empty' \
        "${configPath}05_hysteria2_inbounds.json")
    # Always show the menu here; the install-time panel shortcut (btDomain)
    # would otherwise pick the panel site without asking.
    local btDomain=
    nginxStaticPath=${currentDir:-${nginxStaticPath}}
    initHysteria2Masquerade || return 1
    applyXrayConfigChange "修改Hysteria2伪装" writeHysteria2Masquerade || return 1
    restartXray || return 1
    echoContent green " ---> HTTP/3伪装: $(describeHysteria2Masquerade)"
}

manageHysteria2() {
    local hysteriaConfig="${configPath}05_hysteria2_inbounds.json"
    if [[ ! -f "${hysteriaConfig}" ]]; then
        echoContent red " ---> 当前未安装Hysteria2，请先通过任意组合安装"
        return
    fi

    while true; do
        local currentCongestion=
        local currentProfile=
        local manageChoice=
        currentCongestion=$(jq -r '.inbounds[0].streamSettings.finalmask.quicParams.congestion // "默认"' "${hysteriaConfig}")
        currentProfile=$(jq -r '.inbounds[0].streamSettings.finalmask.quicParams.bbrProfile // "standard"' "${hysteriaConfig}")

        echoContent skyBlue "\n===================== Hysteria2管理 ====================="
        echoContent yellow "当前QUIC拥塞控制: ${currentCongestion}/${currentProfile}"
        if ! bbrProfileSupported; then
            echoContent red "注意: 当前 Xray $(installedXrayVersion) 不支持 bbrProfile（${hysteria2BbrProfileMinVersion} 起支持），以下档位不会生效"
        fi
        echoContent green "# 此处调整本机Hysteria2入站；链式上游在中转管理中单独设置"
        echoContent yellow "1.切换为 conservative [低抖动/保守]"
        echoContent yellow "2.切换为 standard [均衡/推荐]"
        echoContent yellow "3.切换为 aggressive [吞吐优先]"
        echoContent yellow "4.端口跳跃[当前: $(currentPortHopRange || echo 未启用)]"
        echoContent yellow "5.HTTP/3伪装[当前: $(describeHysteria2Masquerade)]"
        echoContent yellow "0.返回主菜单"
        echoContent red "========================================================="
        read -r -p "请选择:" manageChoice

        case ${manageChoice} in
            1) setHysteria2BbrProfile conservative ;;
            2) setHysteria2BbrProfile standard ;;
            3) setHysteria2BbrProfile aggressive ;;
            4) managePortHopping ;;
            5) setHysteria2Masquerade ;;
            0) return ;;
            *) echoContent red " ---> 请输入 0-5" ;;
        esac
    done
}

# ==================== Hysteria2 port hopping ====================
#
# Xray's Hysteria2 inbound listens on one port. Port hopping redirects a UDP
# port range to it with nftables, so clients can hop between ports when an
# ISP throttles a single UDP port. (It does not help when UDP as a whole is
# restricted.) The range is stored in hysteria2PortHopFile; on systemd hosts
# a oneshot unit re-applies the rules at boot.

hysteria2PortHopFile=/opt/xray-agent/hysteria2_port_hopping
hysteria2PortHopNftFile=/opt/xray-agent/hysteria2-port-hopping.nft
hysteria2PortHopUnit=/etc/systemd/system/xray-agent-port-hopping.service
hysteria2PortHopTable=xray_agent_port_hopping
hysteria2PortHopDefaultRange=20000-50000
# Client hop interval in seconds (Hysteria's default; minimum 5).
hysteria2PortHopInterval=30

# Usage: isValidPortRange <start-end>
isValidPortRange() {
    [[ "$1" =~ ^([0-9]+)-([0-9]+)$ ]] || return 1
    local start=${BASH_REMATCH[1]} end=${BASH_REMATCH[2]}
    isValidPort "${start}" && isValidPort "${end}" && ((start < end))
}

# Print UDP ports used by other inbounds (extra-port forwarders for
# Hysteria2) that fall inside the range: the redirect would swallow them.
portHopConflicts() {
    local start=${1%-*} end=${1#*-} file port
    for file in "${configPath}"02_dokodemodoor_inbounds_hysteria_*.json; do
        [[ -f "${file}" ]] || continue
        port=$(jq -r '.inbounds[0].port' "${file}")
        if isValidPort "${port}" && ((port >= start && port <= end)); then
            echo "${port}"
        fi
    done
}

currentPortHopRange() {
    local range
    range=$(cat "${hysteria2PortHopFile}" 2>/dev/null)
    isValidPortRange "${range}" && echo "${range}"
}

writePortHopRules() {
    local range=$1
    cat >"${hysteria2PortHopNftFile}" <<NFT
# Managed by xray-agent: Hysteria2 port hopping.
table inet ${hysteria2PortHopTable} {
    chain prerouting {
        type nat hook prerouting priority dstnat; policy accept;
        udp dport ${range} counter redirect to :${hysteria2Port}
    }
}
NFT
}

# True when systemd is the running init, not merely installed (e.g. containers).
hasSystemd() {
    command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]
}

# (Re)load the rules now, and make them survive reboots where systemd exists.
loadPortHopRules() {
    local nftBin
    nftBin=$(command -v nft) || return 1
    "${nftBin}" delete table inet "${hysteria2PortHopTable}" >/dev/null 2>&1
    if hasSystemd; then
        cat >"${hysteria2PortHopUnit}" <<UNIT
[Unit]
Description=xray-agent Hysteria2 port hopping (UDP redirect)
After=network-pre.target nftables.service
Wants=network-pre.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=-${nftBin} delete table inet ${hysteria2PortHopTable}
ExecStart=${nftBin} -f ${hysteria2PortHopNftFile}
ExecStop=${nftBin} delete table inet ${hysteria2PortHopTable}

[Install]
WantedBy=multi-user.target
UNIT
        systemctl daemon-reload && systemctl enable xray-agent-port-hopping.service >/dev/null 2>&1 \
            && systemctl restart xray-agent-port-hopping.service
    else
        "${nftBin}" -f "${hysteria2PortHopNftFile}"
    fi
    "${nftBin}" list table inet "${hysteria2PortHopTable}" >/dev/null 2>&1
}

# Usage: enablePortHopping <start-end>
enablePortHopping() {
    local range=$1 conflicts
    if ! isValidPortRange "${range}"; then
        echoContent red " ---> 端口范围无效，格式为 起始-结束，例如 ${hysteria2PortHopDefaultRange}"
        return 1
    fi
    if [[ ! -f "${configPath}05_hysteria2_inbounds.json" ]]; then
        echoContent red " ---> 未安装Hysteria2"
        return 1
    fi
    hysteria2Port=${hysteria2Port:-$(jq -r '.inbounds[0].port' "${configPath}05_hysteria2_inbounds.json")}
    conflicts=$(portHopConflicts "${range}" | tr '\n' ' ')
    if [[ -n "${conflicts}" ]]; then
        echoContent red " ---> 端口范围包含额外端口的 UDP 转发: ${conflicts}，请换一个范围"
        return 1
    fi
    if ! command -v nft >/dev/null 2>&1; then
        echoContent yellow " ---> 安装 nftables"
        ${installType:-apt -y install} nftables >/dev/null 2>&1
    fi

    local previousRules=
    [[ -f "${hysteria2PortHopNftFile}" ]] && previousRules=$(cat "${hysteria2PortHopNftFile}")
    writePortHopRules "${range}"
    if ! loadPortHopRules; then
        echoContent red " ---> 端口跳跃规则加载失败，已撤销"
        if [[ -n "${previousRules}" ]]; then
            echo "${previousRules}" >"${hysteria2PortHopNftFile}"
            loadPortHopRules
        else
            disablePortHopping >/dev/null
        fi
        return 1
    fi
    echo "${range}" >"${hysteria2PortHopFile}"
    allowPort "${range/-/:}" udp
    echoContent green " ---> 端口跳跃已启用: UDP ${range} -> ${hysteria2Port}"
    echoContent yellow " ---> 云服务器的安全组也需要放行 UDP ${range}"
}

disablePortHopping() {
    if command -v systemctl >/dev/null 2>&1 && [[ -f "${hysteria2PortHopUnit}" ]]; then
        systemctl disable --now xray-agent-port-hopping.service >/dev/null 2>&1
        rm -f "${hysteria2PortHopUnit}"
        systemctl daemon-reload
    fi
    command -v nft >/dev/null 2>&1 && nft delete table inet "${hysteria2PortHopTable}" >/dev/null 2>&1
    rm -f "${hysteria2PortHopNftFile}" "${hysteria2PortHopFile}"
    echoContent green " ---> 端口跳跃已关闭"
}

# Asked while configuring Hysteria2 during installation. Sets
# hysteria2PortHopRange (empty = disabled); the rules are applied after the
# config is written, see syncPortHopping.
initHysteria2PortHopping() {
    local current answer range
    current=$(currentPortHopRange)
    hysteria2PortHopRange=
    if [[ -n "${current}" ]]; then
        read -r -p "检测到端口跳跃 UDP ${current}，是否继续使用？[Y/n]:" answer
        [[ "${answer}" =~ ^[Nn]$ ]] || hysteria2PortHopRange=${current}
        return 0
    fi
    echoContent yellow "端口跳跃: 运营商对单个UDP端口限速/阻断时有用，需要云安全组放行整个UDP范围"
    read -r -p "是否启用 Hysteria2 端口跳跃？[y/N]:" answer
    [[ "${answer}" =~ ^[Yy]$ ]] || return 0
    while true; do
        read -r -p "请输入UDP端口范围[回车默认 ${hysteria2PortHopDefaultRange}]:" range
        range=${range:-${hysteria2PortHopDefaultRange}}
        isValidPortRange "${range}" && break
        echoContent red " ---> 格式为 起始-结束，例如 ${hysteria2PortHopDefaultRange}"
    done
    hysteria2PortHopRange=${range}
}

# Apply the choice made during installation.
syncPortHopping() {
    if [[ -n "${hysteria2PortHopRange}" ]]; then
        enablePortHopping "${hysteria2PortHopRange}"
    elif [[ -n "$(currentPortHopRange)" ]]; then
        disablePortHopping
    fi
}

managePortHopping() {
    local current answer range
    current=$(currentPortHopRange)
    echoContent skyBlue "\n--------------------- 端口跳跃 ---------------------"
    if [[ -n "${current}" ]]; then
        echoContent yellow "当前状态: 已启用 UDP ${current} -> ${hysteria2Port}"
    else
        echoContent yellow "当前状态: 未启用"
    fi
    echoContent yellow "1.启用/修改端口范围"
    echoContent yellow "2.关闭端口跳跃"
    echoContent yellow "0.返回"
    read -r -p "请选择:" answer
    case ${answer} in
        1)
            read -r -p "请输入UDP端口范围[回车默认 ${current:-${hysteria2PortHopDefaultRange}}]:" range
            enablePortHopping "${range:-${current:-${hysteria2PortHopDefaultRange}}}" || return 1
            echoContent yellow " ---> 请重新获取订阅/分享链接，客户端才会开始跳跃"
            ;;
        2)
            disablePortHopping
            echoContent yellow " ---> 请重新获取订阅/分享链接"
            ;;
    esac
}
