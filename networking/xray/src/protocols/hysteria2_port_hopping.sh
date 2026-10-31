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
