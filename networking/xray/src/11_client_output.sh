# Accounts
showAccounts() {
    readInstallType
    readInstallProtocolType
    readConfigHostPathUUID

    echo
    echoContent skyBlue "\n进度 $1/${totalProgress} : 账号"

    initSubscribeLocalConfig
    # VLESS TCP
    if echo ${currentInstallProtocolType} | grep -q ",0,"; then

        echoContent skyBlue "============================= VLESS TCP TLS_Vision [推荐] ==============================\n"
        jq -c '.inbounds[0].settings.clients//.inbounds[0].users//[] | .[]' ${configPath}02_VLESS_TCP_inbounds.json | while read -r user; do
            local email=
            email=$(echo "${user}" | jq -r .email//.name)

            echoContent skyBlue "\n ---> 账号:${email}"
            echo
            defaultBase64Code vlesstcp "${currentDefaultPort}" "${email}" "$(echo "${user}" | jq -r .id//.uuid)"
        done
    fi

    # VLESS WS
    if echo ${currentInstallProtocolType} | grep -q ",1,"; then
        echoContent skyBlue "\n================================ VLESS WS TLS [仅CDN推荐] ================================\n"

        jq -c '.inbounds[0].settings.clients//.inbounds[0].users//[] | .[]' ${configPath}03_VLESS_WS_inbounds.json | while read -r user; do
            local email=
            email=$(echo "${user}" | jq -r .email//.name)

            local vlessWSPort=${currentDefaultPort}
            echo
            local path="/${currentPath}"

            local count=
            while read -r line; do
                echoContent skyBlue "\n ---> 账号:${email}${count}"
                if [[ -n "${line}" ]]; then
                    defaultBase64Code vlessws "${vlessWSPort}" "${email}${count}" "$(echo "${user}" | jq -r .id//.uuid)" "${line}" "${path}"
                    count=$((count + 1))
                    echo
                fi
            done < <(echo "${currentCDNAddress}" | tr ',' '\n')
        done
    fi

    # VLESS XHTTP TLS (nginx: Vision fallback or the panel site on 443)
    if hasProtocol "${currentInstallProtocolType}" 14; then
        echoContent skyBlue "\n============================= VLESS XHTTP TLS [443/CDN推荐] =============================\n"
        local xhttpPort
        xhttpPort=$(cat "${xhttpStateFile}" 2>/dev/null)
        xhttpPort=${xhttpPort:-${currentDefaultPort}}
        jq -c '.inbounds[0].settings.clients//.inbounds[0].users//[] | .[]' "${configPath}14_VLESS_XHTTP_TLS_inbounds.json" | while read -r user; do
            local email count=
            email=$(echo "${user}" | jq -r .email//.name)
            while read -r line; do
                [[ -n "${line}" ]] || continue
                echoContent skyBlue "\n ---> 账号:${email}${count}"
                defaultBase64Code vlessXhttp "${xhttpPort}" "${email}${count}" "$(echo "${user}" | jq -r .id//.uuid)" "${line}" "${currentXhttpPath}"
                count=$((count + 1))
            done < <(echo "${currentCDNAddress}" | tr ',' '\n')
        done
    fi

    # Hysteria2
    if echo ${currentInstallProtocolType} | grep -q ",6,"; then
        echoContent skyBlue "\n================================ Hysteria2 TLS/QUIC [游戏推荐] ================================\n"
        jq -c '(.inbounds[0].settings.clients // .inbounds[0].settings.users // [])[]' "${configPath}05_hysteria2_inbounds.json" | while read -r user; do
            local email=
            email=$(echo "${user}" | jq -r '.email')
            echoContent skyBlue "\n ---> 账号:${email}"
            echo
            defaultBase64Code hysteria "${hysteria2Port}" "${email}" "$(echo "${user}" | jq -r '.auth')"
        done
    fi
    # VLESS reality vision
    if echo ${currentInstallProtocolType} | grep -q ",3,"; then
        echoContent skyBlue "============================= VLESS reality_vision [推荐]  ==============================\n"
        jq -c '.inbounds[0].settings.clients//.inbounds[0].users//[] | .[]' ${configPath}07_VLESS_vision_reality_inbounds.json | while read -r user; do
            local email=
            email=$(echo "${user}" | jq -r .email//.name)

            echoContent skyBlue "\n ---> 账号:${email}"
            echo
            defaultBase64Code vlessReality "${xrayVLESSRealityVisionPort}" "${email}" "$(echo "${user}" | jq -r .id//.uuid)"
        done
    fi

    # VLESS XHTTP REALITY
    if hasProtocol "${currentInstallProtocolType}" 12; then
        echoContent skyBlue "\n============================ VLESS XHTTP Reality [无需域名] ============================\n"
        jq -c '.inbounds[0].settings.clients//.inbounds[0].users//[] | .[]' "${configPath}12_VLESS_XHTTP_inbounds.json" | while read -r user; do
            local email=
            email=$(echo "${user}" | jq -r .email//.name)
            echoContent skyBlue "\n ---> 账号:${email}"
            echo
            defaultBase64Code vlessXhttpReality "${xrayXhttpRealityPort}" "${email}" "$(echo "${user}" | jq -r .id//.uuid)" "" "${currentXhttpPath}"
        done
    fi
}

# Percent-encode a string for URLs (share links, QR codes).
urlEncode() {
    jq -rn --arg value "$1" '$value | @uri'
}
initSubscribeLocalConfig() {
    rm -rf /opt/xray-agent/subscribe_local/sing-box/*
}
# Common
defaultBase64Code() {
    local type=$1
    local port=$2
    local email=$3
    local id=$4
    local add=$5
    local path=$6
    case "${type}" in
        vlesstcp | vlessws | vlessReality | hysteria | vlessXhttp | vlessXhttpReality) ;;
        *)
            echoContent red " ---> 当前脚本不再支持该协议: ${type}"
            return 1
            ;;
    esac
    local user=
    user=$(normalizeXrayEmail "${email}")
    if [[ ! -f "/opt/xray-agent/subscribe_local/sing-box/${user}" ]]; then
        echo [] >"/opt/xray-agent/subscribe_local/sing-box/${user}"
    fi
    local singBoxSubscribeLocalConfig=
    if [[ "${type}" == "vlesstcp" ]]; then

        echoContent yellow " ---> 通用格式(VLESS+TCP+TLS_Vision)"
        echoContent green "    vless://${id}@${currentHost}:${port}?encryption=none&security=tls&fp=chrome&type=tcp&host=${currentHost}&headerType=none&sni=${currentHost}&flow=xtls-rprx-vision#${email}\n"

        echoContent yellow " ---> 格式化明文(VLESS+TCP+TLS_Vision)"
        echoContent green "协议类型:VLESS，地址:${currentHost}，端口:${port}，用户ID:${id}，安全:tls，client-fingerprint: chrome，传输方式:tcp，flow:xtls-rprx-vision，账户名:${email}\n"
        cat <<EOF >>"/opt/xray-agent/subscribe_local/default/${user}"
vless://${id}@${currentHost}:${port}?encryption=none&security=tls&type=tcp&host=${currentHost}&fp=chrome&headerType=none&sni=${currentHost}&flow=xtls-rprx-vision#${email}
EOF
        cat <<EOF >>"/opt/xray-agent/subscribe_local/clashMeta/${user}"
  - name: "${email}"
    type: vless
    server: ${currentHost}
    port: ${port}
    uuid: ${id}
    network: tcp
    tls: true
    udp: true
    flow: xtls-rprx-vision
    client-fingerprint: chrome
EOF
        singBoxSubscribeLocalConfig=$(jq -r --arg email "${email}" --arg host "${currentHost}" --arg id "${id}" --argjson port "${port}" '. += [{tag:$email,type:"vless",server:$host,server_port:$port,uuid:$id,flow:"xtls-rprx-vision",tls:{enabled:true,server_name:$host,utls:{enabled:true,fingerprint:"chrome"}},packet_encoding:"xudp"}]' "/opt/xray-agent/subscribe_local/sing-box/${user}")
        echo "${singBoxSubscribeLocalConfig}" | jq . >"/opt/xray-agent/subscribe_local/sing-box/${user}"

        echoContent yellow " ---> 二维码 VLESS(VLESS+TCP+TLS_Vision)"
        echoContent green "    https://api-qr-server.zwen.cc/v1/create-qr-code/?size=400x400&data=vless%3A%2F%2F${id}%40${currentHost}%3A${port}%3Fencryption%3Dnone%26fp%3Dchrome%26security%3Dtls%26type%3Dtcp%26${currentHost}%3D${currentHost}%26headerType%3Dnone%26sni%3D${currentHost}%26flow%3Dxtls-rprx-vision%23${email}\n"

    elif [[ "${type}" == "vlessws" ]]; then

        echoContent yellow " ---> 通用格式(VLESS+WS+TLS)"
        echoContent green "    vless://${id}@${add}:${port}?encryption=none&security=tls&type=ws&host=${currentHost}&sni=${currentHost}&fp=chrome&path=${path}#${email}\n"

        echoContent yellow " ---> 格式化明文(VLESS+WS+TLS)"
        echoContent green "    协议类型:VLESS，地址:${add}，伪装域名/SNI:${currentHost}，端口:${port}，client-fingerprint: chrome,用户ID:${id}，安全:tls，传输方式:ws，路径:${path}，账户名:${email}\n"

        cat <<EOF >>"/opt/xray-agent/subscribe_local/default/${user}"
vless://${id}@${add}:${port}?encryption=none&security=tls&type=ws&host=${currentHost}&sni=${currentHost}&fp=chrome&path=${path}#${email}
EOF
        cat <<EOF >>"/opt/xray-agent/subscribe_local/clashMeta/${user}"
  - name: "${email}"
    type: vless
    server: ${add}
    port: ${port}
    uuid: ${id}
    udp: true
    tls: true
    network: ws
    client-fingerprint: chrome
    servername: ${currentHost}
    ws-opts:
      path: ${path}
      headers:
        Host: ${currentHost}
EOF

        singBoxSubscribeLocalConfig=$(jq -r --arg email "${email}" --arg server "${add}" --arg host "${currentHost}" --arg id "${id}" --arg path "${path}" --argjson port "${port}" '. += [{tag:$email,type:"vless",server:$server,server_port:$port,uuid:$id,tls:{enabled:true,server_name:$host,utls:{enabled:true,fingerprint:"chrome"}},multiplex:{enabled:false,protocol:"smux",max_streams:32},packet_encoding:"xudp",transport:{type:"ws",path:$path,headers:{Host:$host}}}]' "/opt/xray-agent/subscribe_local/sing-box/${user}")
        echo "${singBoxSubscribeLocalConfig}" | jq . >"/opt/xray-agent/subscribe_local/sing-box/${user}"

        echoContent yellow " ---> 二维码 VLESS(VLESS+WS+TLS)"
        echoContent green "    https://api-qr-server.zwen.cc/v1/create-qr-code/?size=400x400&data=vless%3A%2F%2F${id}%40${add}%3A${port}%3Fencryption%3Dnone%26security%3Dtls%26type%3Dws%26host%3D${currentHost}%26fp%3Dchrome%26sni%3D${currentHost}%26path%3D${path}%23${email}"

    elif [[ "${type}" == "vlessXhttp" ]]; then
        # Xray-first: sing-box has no XHTTP, so no sing-box entry is written.
        local link
        link="vless://${id}@${add}:${port}?encryption=none&security=tls&type=xhttp&sni=${currentHost}&host=${currentHost}&fp=chrome&alpn=h2&path=$(urlEncode "${path}")&mode=auto#${email}"
        echoContent yellow " ---> 通用格式(VLESS+XHTTP+TLS)"
        echoContent green "    ${link}\n"
        echoContent yellow " ---> 格式化明文(VLESS+XHTTP+TLS)"
        echoContent green "    协议类型:VLESS，地址:${add}，SNI/Host:${currentHost}，端口:${port}，用户ID:${id}，安全:tls，传输方式:xhttp，路径:${path}，mode:auto，账户名:${email}\n"
        echo "${link}" >>"/opt/xray-agent/subscribe_local/default/${user}"
        cat <<EOF >>"/opt/xray-agent/subscribe_local/clashMeta/${user}"
  - name: "${email}"
    type: vless
    server: ${add}
    port: ${port}
    uuid: ${id}
    udp: true
    tls: true
    network: xhttp
    packet-encoding: xudp
    client-fingerprint: chrome
    alpn: [h2]
    servername: ${currentHost}
    xhttp-opts:
      path: ${path}
      host: ${currentHost}
      mode: auto
EOF
        echoContent yellow " ---> 二维码 VLESS(VLESS+XHTTP+TLS)"
        echoContent green "    https://api-qr-server.zwen.cc/v1/create-qr-code/?size=400x400&data=$(urlEncode "${link}")\n"

    elif [[ "${type}" == "vlessXhttpReality" ]]; then
        local link pqvParam=
        [[ -n "${currentRealityMldsa65Verify}" && "${currentRealityMldsa65Verify}" != "null" ]] && pqvParam="&pqv=${currentRealityMldsa65Verify}"
        link="vless://${id}@$(getPublicIP):${port}?encryption=none&security=reality&type=xhttp&sni=${xrayVLESSRealityServerName}&fp=chrome&pbk=${currentRealityPublicKey}&sid=6ba85179e30d4fc2${pqvParam}&path=$(urlEncode "${path}")&mode=auto#${email}"
        echoContent yellow " ---> 通用格式(VLESS+XHTTP+Reality)"
        echoContent green "    ${link}\n"
        echoContent yellow " ---> 格式化明文(VLESS+XHTTP+Reality)"
        echoContent green "    协议类型:VLESS reality，地址:$(getPublicIP)，端口:${port}，publicKey:${currentRealityPublicKey}，shortId:6ba85179e30d4fc2，serverName:${xrayVLESSRealityServerName}，传输方式:xhttp，路径:${path}，用户ID:${id}，账户名:${email}\n"
        echo "${link}" >>"/opt/xray-agent/subscribe_local/default/${user}"
        cat <<EOF >>"/opt/xray-agent/subscribe_local/clashMeta/${user}"
  - name: "${email}"
    type: vless
    server: $(getPublicIP)
    port: ${port}
    uuid: ${id}
    udp: true
    tls: true
    network: xhttp
    client-fingerprint: chrome
    servername: ${xrayVLESSRealityServerName}
    xhttp-opts:
      path: ${path}
      mode: auto
    reality-opts:
      public-key: ${currentRealityPublicKey}
      short-id: 6ba85179e30d4fc2
EOF
        echoContent yellow " ---> 二维码 VLESS(VLESS+XHTTP+Reality)"
        echoContent green "    https://api-qr-server.zwen.cc/v1/create-qr-code/?size=400x400&data=$(urlEncode "${link}")\n"

    elif [[ "${type}" == "hysteria" ]]; then
        # Port hopping, in each client's own format: v2rayN/v2rayNG read the
        # "mport" query parameter (they cannot parse the official
        # "host:20000-50000" form), Clash Meta uses "ports", sing-box uses
        # "server_ports" with a colon range.
        local link portHop
        portHop=$(currentPortHopRange || true)
        link="hysteria2://${id}@${currentHost}:${port}/?sni=${currentHost}&alpn=h3&insecure=0${portHop:+&mport=${portHop}}#${email}"
        echoContent yellow " ---> 通用格式(Hysteria2+TLS+QUIC)"
        echoContent green "    ${link}\n"
        if [[ -n "${portHop}" ]]; then
            echoContent yellow "    端口跳跃: UDP ${portHop}，间隔 ${hysteria2PortHopInterval}s\n"
        fi
        echo "${link}" >>"/opt/xray-agent/subscribe_local/default/${user}"

        {
            echo "  - name: \"${email}\""
            echo "    type: hysteria2"
            echo "    server: ${currentHost}"
            echo "    port: ${port}"
            if [[ -n "${portHop}" ]]; then
                echo "    ports: ${portHop}"
                echo "    hop-interval: ${hysteria2PortHopInterval}"
            fi
            echo "    password: ${id}"
            echo "    sni: ${currentHost}"
            echo "    alpn:"
            echo "      - h3"
            echo "    skip-cert-verify: false"
        } >>"/opt/xray-agent/subscribe_local/clashMeta/${user}"

        singBoxSubscribeLocalConfig=$(jq --arg tag "${email}" --arg server "${currentHost}" --argjson port "${port}" --arg password "${id}" \
            --arg portHop "${portHop}" --arg interval "${hysteria2PortHopInterval}s" '
            . += [{tag:$tag,type:"hysteria2",server:$server,server_port:$port,password:$password,
                   tls:{enabled:true,server_name:$server,alpn:["h3"],insecure:false}}
                  + (if $portHop == "" then {} else {server_ports:[$portHop | sub("-"; ":")], hop_interval:$interval} end)]' \
            "/opt/xray-agent/subscribe_local/sing-box/${user}")
        echo "${singBoxSubscribeLocalConfig}" | jq . >"/opt/xray-agent/subscribe_local/sing-box/${user}"

        echoContent yellow " ---> 二维码 Hysteria2(TLS)"
        echoContent green "    https://api-qr-server.zwen.cc/v1/create-qr-code/?size=400x400&data=$(urlEncode "${link}")\n"

    elif [[ "${type}" == "vlessReality" ]]; then
        local realityServerName=${xrayVLESSRealityServerName}
        local publicKey=${currentRealityPublicKey}
        local realityMldsa65Verify=${currentRealityMldsa65Verify}

        echoContent yellow " ---> 通用格式(VLESS+reality+uTLS+Vision)"
        echoContent green "    vless://${id}@$(getPublicIP):${port}?encryption=none&security=reality&pqv=${realityMldsa65Verify}&type=tcp&sni=${realityServerName}&fp=chrome&pbk=${publicKey}&sid=6ba85179e30d4fc2&flow=xtls-rprx-vision#${email}\n"

        echoContent yellow " ---> 格式化明文(VLESS+reality+uTLS+Vision)"
        echoContent green "协议类型:VLESS reality，地址:$(getPublicIP)，publicKey:${publicKey}，shortId: 6ba85179e30d4fc2，pqv=${realityMldsa65Verify}，serverNames：${realityServerName}，端口:${port}，用户ID:${id}，传输方式:tcp，账户名:${email}\n"
        cat <<EOF >>"/opt/xray-agent/subscribe_local/default/${user}"
vless://${id}@$(getPublicIP):${port}?encryption=none&security=reality&pqv=${realityMldsa65Verify}&type=tcp&sni=${realityServerName}&fp=chrome&pbk=${publicKey}&sid=6ba85179e30d4fc2&flow=xtls-rprx-vision#${email}
EOF
        cat <<EOF >>"/opt/xray-agent/subscribe_local/clashMeta/${user}"
  - name: "${email}"
    type: vless
    server: $(getPublicIP)
    port: ${port}
    uuid: ${id}
    network: tcp
    tls: true
    udp: true
    flow: xtls-rprx-vision
    servername: ${realityServerName}
    reality-opts:
      public-key: ${publicKey}
      short-id: 6ba85179e30d4fc2
    client-fingerprint: chrome
EOF

        singBoxSubscribeLocalConfig=$(jq --arg tag "${email}" --arg server "$(getPublicIP)" --argjson port "${port}" --arg uuid "${id}" \
            --arg serverName "${realityServerName}" --arg publicKey "${publicKey}" \
            '. += [{tag:$tag,type:"vless",server:$server,server_port:$port,uuid:$uuid,flow:"xtls-rprx-vision",
                    tls:{enabled:true,server_name:$serverName,utls:{enabled:true,fingerprint:"chrome"},
                         reality:{enabled:true,public_key:$publicKey,short_id:"6ba85179e30d4fc2"}},
                    packet_encoding:"xudp"}]' \
            "/opt/xray-agent/subscribe_local/sing-box/${user}")
        echo "${singBoxSubscribeLocalConfig}" | jq . >"/opt/xray-agent/subscribe_local/sing-box/${user}"

        echoContent yellow " ---> 二维码 VLESS(VLESS+reality+uTLS+Vision)"
        echoContent green "    https://api-qr-server.zwen.cc/v1/create-qr-code/?size=400x400&data=vless%3A%2F%2F${id}%40$(getPublicIP)%3A${port}%3Fencryption%3Dnone%26security%3Dreality%26type%3Dtcp%26sni%3D${realityServerName}%26fp%3Dchrome%26pbk%3D${publicKey}%26sid%3D6ba85179e30d4fc2%26flow%3Dxtls-rprx-vision%23${email}\n"

    fi

}

# Remove the nginx 302 config
