# Read a key from `xray x25519` output. The public key line changed from
# "Password: <key>" to "Password (PublicKey): <key>" in Xray 26.x, so take
# whatever follows ": " instead of the second whitespace field.
# Usage: parseX25519Field <output> private|public
parseX25519Field() {
    local pattern='^(PrivateKey|Private key)'
    [[ "$2" == "public" ]] && pattern='^(Password|Public key)'
    awk -F': ' -v pattern="${pattern}" '$0 ~ pattern {print $2; exit}' <<<"$1"
}

isValidRealityKey() {
    [[ "$1" =~ ^[A-Za-z0-9_-]{43}$ ]]
}

# Installs made with Xray 26.x before the parsing fix stored the literal
# "(PublicKey):" as the public key. The server only needs the private key,
# so recover the public key from it.
repairRealityPublicKey() {
    isValidRealityKey "${currentRealityPublicKey}" && return 0
    isValidRealityKey "${currentRealityPrivateKey}" || return 0
    [[ -x "${xrayBinary}" ]] || return 0
    local derived
    derived=$(parseX25519Field "$("${xrayBinary}" x25519 -i "${currentRealityPrivateKey}")" public)
    isValidRealityKey "${derived}" && currentRealityPublicKey=${derived}
}

# Initialize the Reality key
initRealityKey() {
    echoContent skyBlue "\n================ 生成 Reality 密钥对 ===============\n"
    echoContent yellow "📌 Reality 密钥说明："
    echoContent white "   • Private Key (私钥): 服务器端使用，必须保密"
    echoContent white "   • Public Key (公钥):  客户端使用，可以公开"
    echoContent white "   • 基于 X25519 椭圆曲线算法\n"

    # Always ask whether to reuse the previous key pair, regardless of lastInstallationConfig
    if [[ -n "${currentRealityPublicKey}" ]]; then
        echoContent yellow "检测到上次安装的密钥对"
        echoContent green "Public Key:  ${currentRealityPublicKey}"
        echoContent green "Private Key: ${currentRealityPrivateKey}\n"
        read -r -p "是否使用上次的密钥对？[y/n]:" historyKeyStatus
        if [[ "${historyKeyStatus}" == "y" ]]; then
            realityPrivateKey=${currentRealityPrivateKey}
            realityPublicKey=${currentRealityPublicKey}
        fi
    fi
    if [[ -z "${realityPrivateKey}" ]]; then
        echoContent yellow "💡 通常选择："
        echoContent green "   • 回车 - 自动生成（推荐⭐）"
        echoContent green "   • 手动输入 - 使用已有私钥（高级）\n"
        read -r -p "请输入 Private Key [回车自动生成]:" historyPrivateKey
        if [[ -n "${historyPrivateKey}" ]]; then
            realityX25519Key=$(/opt/xray-agent/xray/xray x25519 -i "${historyPrivateKey}")
        else
            echoContent green "正在生成密钥对...\n"
            realityX25519Key=$(/opt/xray-agent/xray/xray x25519)
        fi
        realityPrivateKey=$(parseX25519Field "${realityX25519Key}" private)
        realityPublicKey=$(parseX25519Field "${realityX25519Key}" public)
        if [[ -z "${realityPrivateKey}" ]]; then
            echoContent red "❌ 输入的 Private Key 不合法"
            initRealityKey
        else
            echoContent green "\n✅ 密钥对生成成功："
            echoContent green "   Private Key: ${realityPrivateKey}"
            echoContent green "   Public Key:  ${realityPublicKey}\n"
        fi
    fi
}
# Initialize mldsa65Seed
initRealityMldsa65() {
    echoContent skyBlue "\n生成Reality mldsa65\n"
    if /opt/xray-agent/xray/xray tls ping "${realityServerName}:${realityDomainPort}" 2>/dev/null | grep -q "X25519MLKEM768"; then
        length=$(/opt/xray-agent/xray/xray tls ping "${realityServerName}:${realityDomainPort}" | grep "Certificate chain's total length:" | awk '{print $5}' | head -1)

        if [ "$length" -gt 3500 ]; then
            if [[ -n "${currentRealityMldsa65}" && -z "${lastInstallationConfig}" ]]; then
                read -r -p "读取到上次安装记录，是否使用上次安装时的Seed/Verify ？[y/n]:" historyMldsa65Status
                if [[ "${historyMldsa65Status}" == "y" ]]; then
                    realityMldsa65Seed=${currentRealityMldsa65Seed}
                    realityMldsa65Verify=${currentRealityMldsa65Verify}
                fi
            elif [[ -n "${currentRealityMldsa65Seed}" && -n "${lastInstallationConfig}" ]]; then
                realityMldsa65Seed=${currentRealityMldsa65Seed}
                realityMldsa65Verify=${currentRealityMldsa65Verify}
            fi
            if [[ -z "${realityMldsa65Seed}" ]]; then
                realityMldsa65=$(/opt/xray-agent/xray/xray mldsa65)
                realityMldsa65Seed=$(echo "${realityMldsa65}" | head -1 | awk '{print $2}')
                realityMldsa65Verify=$(echo "${realityMldsa65}" | tail -n 1 | awk '{print $2}')
            fi
        else
            echoContent green " 目标域名支持X25519MLKEM768，但是证书的长度不足，忽略ML-DSA-65。"
        fi
    else
        echoContent green " 目标域名不支持X25519MLKEM768，忽略ML-DSA-65。"
    fi
}

# Initialize the client-usable serverNames
initRealityClientServersName() {
    local realityDestDomainList="gateway.icloud.com,itunes.apple.com,swdist.apple.com,swcdn.apple.com,updates.cdn-apple.com,mensura.cdn-apple.com,osxapps.itunes.apple.com,aod.itunes.apple.com,download-installer.cdn.mozilla.net,addons.mozilla.org,s0.awsstatic.com,d1.awsstatic.com,images-na.ssl-images-amazon.com,m.media-amazon.com,player.live-video.net,one-piece.com,lol.secure.dyn.riotcdn.net,www.swift.com,academy.nvidia.com,www.cisco.com,www.asus.com,www.samsung.com,www.amd.com,cdn-dynmedia-1.microsoft.com,software.download.prss.microsoft.com,dl.google.com,www.google-analytics.com"
    # Always ask whether to reuse the previous domain, regardless of lastInstallationConfig
    if [[ -n "${realityServerName}" ]]; then
        if echo ${realityDestDomainList} | grep -q "${realityServerName}"; then
            read -r -p "读取到上次安装设置的Reality域名，是否使用？[y/n]:" realityServerNameStatus
            if [[ "${realityServerNameStatus}" != "y" ]]; then
                realityServerName=
                realityDomainPort=
            fi
        else
            realityServerName=
            realityDomainPort=
        fi
    fi

    if [[ -z "${realityServerName}" ]]; then
        if [[ -n "${domain}" ]]; then
            echo
            read -r -p "是否使用 ${domain} 此域名作为Reality目标域名 ？[y/n]:" realityServerNameCurrentDomainStatus
            if [[ "${realityServerNameCurrentDomainStatus}" == "y" ]]; then
                realityServerName="${domain}"
                if [[ -z "${subscribePort}" ]]; then
                    echo
                    installSubscribe
                    readNginxSubscribe
                    realityDomainPort="${subscribePort}"
                else
                    realityDomainPort="${subscribePort}"
                fi
            fi
        fi
        if [[ -z "${realityServerName}" ]]; then
            realityDomainPort=443
            echoContent skyBlue "\n================ 配置 Reality 伪装目标网站 ===============\n"
            echoContent yellow "📌 Reality 工作原理："
            echoContent white "   客户端访问 → 假装访问目标网站 → 实际连接你的代理服务器"
            echoContent white "   如果被检测，流量看起来像在访问正常的 HTTPS 网站\n"

            echoContent yellow "💡 推荐的伪装目标（可直接使用）："
            echoContent green "   • addons.mozilla.org        (Mozilla 插件商店)"
            echoContent green "   • gateway.icloud.com        (Apple iCloud)"
            echoContent green "   • download-installer.cdn.mozilla.net"
            echoContent green "   • www.cisco.com             (思科官网)"
            echoContent green "   • www.samsung.com           (三星官网)\n"

            echoContent yellow "⚠️  选择要求："
            echoContent white "   1. 必须支持 TLSv1.3"
            echoContent white "   2. 证书链长度适中（<3500字节）"
            echoContent white "   3. 最好是知名网站（不易被墙）"
            echoContent white "   4. 默认端口 443，可自定义其他端口\n"

            echoContent yellow "📝 输入格式："
            echoContent white "   • 仅域名:     addons.mozilla.org       (使用 443 端口)"
            echoContent white "   • 域名+端口:  www.cisco.com:443        (自定义端口)"
            echoContent white "   • 回车:       随机选择推荐域名\n"

            read -r -p "请输入目标网站域名[回车随机选择]:" realityServerName
            if [[ -z "${realityServerName}" ]]; then
                randomNum=$(randomNum 1 27)
                realityServerName=$(echo "${realityDestDomainList}" | awk -F ',' -v randomNum="$randomNum" '{print $randomNum}')
            fi
            if echo "${realityServerName}" | grep -q ":"; then
                realityDomainPort=$(echo "${realityServerName}" | awk -F "[:]" '{print $2}')
                realityServerName=$(echo "${realityServerName}" | awk -F "[:]" '{print $1}')
            fi
        fi
    fi

    echoContent yellow "\n ---> 客户端可用域名: ${realityServerName}:${realityDomainPort}\n"
}
# Initialize the Reality port
initXrayRealityPort() {
    # Always ask whether to reuse the previous port, regardless of lastInstallationConfig
    if [[ -n "${xrayVLESSRealityPort}" ]]; then
        read -r -p "读取到上次安装记录，是否使用上次安装时的端口 ？[y/n]:" historyRealityPortStatus
        if [[ "${historyRealityPortStatus}" == "y" ]]; then
            realityPort=${xrayVLESSRealityPort}
        fi
    fi

    if [[ -z "${realityPort}" ]]; then
        echoContent skyBlue "\n================ 配置 Reality 监听端口 ===============\n"
        echoContent yellow "📌 这是你的服务器对外开放的端口"
        echoContent white "   • 客户端连接时使用此端口"
        echoContent white "   • 建议使用非标准端口（避免端口扫描）"
        echoContent white "   • 端口范围：1-65535\n"

        echoContent yellow "💡 推荐配置："
        echoContent green "   • 常用端口：443、8443、2053"
        echoContent green "   • 随机端口（回车自动生成 10000-30000)"
        echoContent green "   • 自定义端口：如 12345\n"

        read -r -p "请输入端口[回车随机10000-30000]:" realityPort
        if [[ -z "${realityPort}" ]]; then
            realityPort=$((RANDOM % 20001 + 10000))
        fi
        if [[ -n "${realityPort}" && "${xrayVLESSRealityPort}" != "${realityPort}" ]]; then
            checkPort "${realityPort}"
        fi
    fi
    if [[ -z "${realityPort}" ]]; then
        initXrayRealityPort
    else
        allowPort "${realityPort}"
        echoContent yellow "\n ---> 端口: ${realityPort}"
    fi

}
# Port for VLESS + XHTTP + REALITY. Sets xhttpRealityPort; it must differ
# from the Vision + REALITY port because both are separate inbounds.
initXrayXhttpRealityPort() {
    xhttpRealityPort=
    if [[ -n "${xrayXhttpRealityPort}" ]]; then
        local historyStatus
        read -r -p "读取到上次 XHTTP+Reality 端口 ${xrayXhttpRealityPort}，是否继续使用？[y/n]:" historyStatus
        [[ "${historyStatus}" == "y" ]] && xhttpRealityPort=${xrayXhttpRealityPort}
    fi
    while [[ -z "${xhttpRealityPort}" ]]; do
        echoContent skyBlue "\n============= 配置 XHTTP+Reality 监听端口 =============\n"
        read -r -p "请输入端口[回车随机10000-30000]:" xhttpRealityPort
        xhttpRealityPort=${xhttpRealityPort:-$((RANDOM % 20001 + 10000))}
        if ! isValidPort "${xhttpRealityPort}"; then
            echoContent red " ---> 端口无效"
            xhttpRealityPort=
        elif [[ -n "${realityPort}" && "${xhttpRealityPort}" == "${realityPort}" ]]; then
            echoContent red " ---> 不能与 Vision+Reality 使用同一端口"
            xhttpRealityPort=
        elif [[ "${xhttpRealityPort}" != "${xrayXhttpRealityPort}" ]]; then
            checkPort "${xhttpRealityPort}"
        fi
    done
    allowPort "${xhttpRealityPort}"
    echoContent yellow "\n ---> XHTTP+Reality 端口: ${xhttpRealityPort}"
}

# Reality management
manageReality() {
    readInstallProtocolType
    readConfigHostPathUUID
    readCustomPort

    if [[ -z "${coreInstallType}" ]] \
        || { ! hasProtocol "${currentInstallProtocolType}" 3 && ! hasProtocol "${currentInstallProtocolType}" 12; }; then
        echoContent red "\n ---> 请先安装Reality协议"
        return 1
    fi

    selectCustomInstallType=","
    hasProtocol "${currentInstallProtocolType}" 3 && selectCustomInstallType+="3,"
    hasProtocol "${currentInstallProtocolType}" 12 && selectCustomInstallType+="12,"
    initXrayConfig custom 1 true || return 1
    syncRelayRouting || return 1

    restartXray || return 1
    subscribe false
}
