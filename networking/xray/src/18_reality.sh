# 初始化realityKey
initRealityKey() {
    echoContent skyBlue "\n================ 生成 Reality 密钥对 ===============\n"
    echoContent yellow "📌 Reality 密钥说明："
    echoContent white "   • Private Key (私钥): 服务器端使用，必须保密"
    echoContent white "   • Public Key (公钥):  客户端使用，可以公开"
    echoContent white "   • 基于 X25519 椭圆曲线算法\n"
    
    # 总是询问是否使用上次密钥对，不管lastInstallationConfig的值
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
        realityPrivateKey=$(echo "${realityX25519Key}" | grep "PrivateKey" | awk '{print $2}')
        realityPublicKey=$(echo "${realityX25519Key}" | grep "Password" | awk '{print $2}')
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
# 初始化 mldsa65Seed
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
                #        fi
            fi
            #    echoContent green "\n Seed:${realityMldsa65Seed}"
            #    echoContent green "\n Verify:${realityMldsa65Verify}"
        else
            echoContent green " 目标域名支持X25519MLKEM768，但是证书的长度不足，忽略ML-DSA-65。"
        fi
    else
        echoContent green " 目标域名不支持X25519MLKEM768，忽略ML-DSA-65。"
    fi
}
# 检查reality域名是否符合
checkRealityDest() {
    local traceResult=
    traceResult=$(curl -s "https://$(echo "${realityDestDomain}" | cut -d ':' -f 1)/cdn-cgi/trace" | grep "visit_scheme=https")
    if [[ -n "${traceResult}" ]]; then
        echoContent red "\n ---> 检测到使用的域名，托管在cloudflare并开启了代理，使用此类型域名可能导致VPS流量被其他人使用[不建议使用]\n"
        read -r -p "是否继续 ？[y/n]" setRealityDestStatus
        if [[ "${setRealityDestStatus}" != 'y' ]]; then
            exit 0
        fi
        echoContent yellow "\n ---> 忽略风险，继续使用"
    fi
}

# 初始化客户端可用的ServersName
initRealityClientServersName() {
    local realityDestDomainList="gateway.icloud.com,itunes.apple.com,swdist.apple.com,swcdn.apple.com,updates.cdn-apple.com,mensura.cdn-apple.com,osxapps.itunes.apple.com,aod.itunes.apple.com,download-installer.cdn.mozilla.net,addons.mozilla.org,s0.awsstatic.com,d1.awsstatic.com,images-na.ssl-images-amazon.com,m.media-amazon.com,player.live-video.net,one-piece.com,lol.secure.dyn.riotcdn.net,www.swift.com,academy.nvidia.com,www.cisco.com,www.asus.com,www.samsung.com,www.amd.com,cdn-dynmedia-1.microsoft.com,software.download.prss.microsoft.com,dl.google.com,www.google-analytics.com"
    # 总是询问是否使用上次域名，不管lastInstallationConfig的值
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
# 初始化reality端口
initXrayRealityPort() {
    # 总是询问是否使用上次端口，不管lastInstallationConfig的值
    if [[ -n "${xrayVLESSRealityPort}" ]]; then
        read -r -p "读取到上次安装记录，是否使用上次安装时的端口 ？[y/n]:" historyRealityPortStatus
        if [[ "${historyRealityPortStatus}" == "y" ]]; then
            realityPort=${xrayVLESSRealityPort}
        fi
    fi

    if [[ -z "${realityPort}" ]]; then
        #        if [[ -n "${port}" ]]; then
        #            read -r -p "是否使用TLS+Vision端口 ？[y/n]:" realityPortTLSVisionStatus
        #            if [[ "${realityPortTLSVisionStatus}" == "y" ]]; then
        #                realityPort=${port}
        #            fi
        #        fi
        #        if [[ -z "${realityPort}" ]]; then
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
        #        fi
        if [[ -n "${realityPort}" && "${xrayVLESSRealityPort}" == "${realityPort}" ]]; then
            handleXray stop
        else
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
# reality管理
manageReality() {
    readInstallProtocolType
    readConfigHostPathUUID
    readCustomPort

    if ! echo "${currentInstallProtocolType}" | grep -q ",3," || [[ -z "${coreInstallType}" ]]; then
        echoContent red "\n ---> 请先安装Reality协议"
        exit 0
    fi

    selectCustomInstallType=",3,"
    initXrayConfig custom 1 true

    handleXray stop
    handleXray start
    subscribe false
}

# 安装reality scanner
installRealityScanner() {
    if [[ ! -f "/opt/xray-agent/xray/reality_scan/RealiTLScanner-linux-64" ]]; then
        version=$(curl -s https://api.github.com/repos/XTLS/RealiTLScanner/releases?per_page=1 | jq -r '.[]|.tag_name')
        if ! downloadFile "https://github.com/XTLS/RealiTLScanner/releases/download/${version}/RealiTLScanner-linux-64" "/opt/xray-agent/xray/reality_scan/RealiTLScanner-linux-64"; then
            echoContent red " ---> Reality Scanner 下载失败"
            return 1
        fi
        chmod 755 /opt/xray-agent/xray/reality_scan/RealiTLScanner-linux-64
    fi
}
# reality scanner
realityScanner() {
    echoContent skyBlue "\n进度 1/1 : 扫描Reality域名"
    echoContent red "\n=============================================================="
    echoContent yellow "# 注意事项"
    echoContent yellow "扫描完成后，请自行检查扫描网站结果内容是否合规，需个人承担风险"
    echoContent red "某些IDC不允许扫描操作，比如搬瓦工，其中风险请自行承担\n"
    echoContent yellow "1.扫描IPv4"
    echoContent yellow "2.扫描IPv6"
    echoContent red "=============================================================="
    read -r -p "请选择:" realityScannerStatus
    local type=
    if [[ "${realityScannerStatus}" == "1" ]]; then
        type=4
    elif [[ "${realityScannerStatus}" == "2" ]]; then
        type=6
    fi

    read -r -p "某些IDC不允许扫描操作，比如搬瓦工，其中风险请自行承担，是否继续？[y/n]:" scanStatus

    if [[ "${scanStatus}" != "y" ]]; then
        exit 0
    fi

    publicIP=$(getPublicIP "${type}")
    echoContent yellow "IP:${publicIP}"
    if [[ -z "${publicIP}" ]]; then
        echoContent red " ---> 无法获取IP"
        exit 0
    fi

    read -r -p "IP是否正确？[y/n]:" ipStatus
    if [[ "${ipStatus}" == "y" ]]; then
        echoContent yellow "结果存储在 /opt/xray-agent/xray/reality_scan/result.log 文件中\n"
        /opt/xray-agent/xray/reality_scan/RealiTLScanner-linux-64 -addr "${publicIP}" | tee /opt/xray-agent/xray/reality_scan/result.log
    else
        echoContent red " ---> 无法读取正确IP"
    fi
}
