
normalizeXrayEmail() {
    local value=$1 suffix
    for suffix in VLESS_TCP/TLS_Vision VLESS_WS vless_reality_vision Hysteria2; do
        if [[ "${value}" == *-"${suffix}" ]]; then
            printf '%s\n' "${value%-${suffix}}"
            return 0
        fi
    done
    printf '%s\n' "${value}"
}

initXrayClients() {
    local clientType=$1
    local newUUID=$2
    local newEmail=$3
    case "${clientType}" in
    0 | 1 | 3) ;;
    *)
        echoContent red "不支持的 Xray 客户端类型: ${clientType}" >&2
        return 1
        ;;
    esac

    # 检查 currentClients 是否为空或 null，避免 jq 操作错误
    if [[ -z "${currentClients}" ]] || [[ "${currentClients}" == "null" ]] || ! jq -e 'type == "array"' >/dev/null 2>&1 <<<"${currentClients}"; then
        currentClients="[]"
    fi

    local users='[]'
    local existingUUID existingEmail currentUser
    while read -r user; do
        existingUUID=$(jq -r '.id // .uuid // empty' <<<"${user}")
        existingEmail=$(normalizeXrayEmail "$(jq -r '.email // .name // "user"' <<<"${user}")")
        [[ -z "${existingUUID}" ]] && continue
        currentUser=$(buildXrayClient "${clientType}" "${existingUUID}" "${existingEmail}") || return 1
        users=$(jq --argjson user "${currentUser}" '. + [$user]' <<<"${users}")
    done < <(echo "${currentClients}" | jq -c '.[]')

    if [[ -n "${newUUID}" ]]; then
        currentUser=$(buildXrayClient "${clientType}" "${newUUID}" "${newEmail}") || return 1
        users=$(jq --argjson user "${currentUser}" '. + [$user]' <<<"${users}")
    fi
    echo "${users}"
}

buildXrayClient() {
    local clientType=$1 userUUID=$2 userEmail=$3
    case "${clientType}" in
    0) jq -nc --arg id "${userUUID}" --arg email "${userEmail}-VLESS_TCP/TLS_Vision" '{id:$id,flow:"xtls-rprx-vision",email:$email}' ;;
    1) jq -nc --arg id "${userUUID}" --arg email "${userEmail}-VLESS_WS" '{id:$id,email:$email}' ;;
    3) jq -nc --arg id "${userUUID}" --arg email "${userEmail}-vless_reality_vision" '{id:$id,email:$email,flow:"xtls-rprx-vision"}' ;;
    *) return 1 ;;
    esac
}

# 将脚本现有的 UUID 用户转换为 Xray-core Hysteria2 认证客户端。
# UUID 作为 auth 使用，便于所有已安装协议共用同一套账号。
initXrayHysteria2Clients() {
    local users='[]'
    local user userId userEmail

    while read -r user; do
        userId=$(echo "${user}" | jq -r '.id // .uuid // .auth // empty')
        userEmail=$(normalizeXrayEmail "$(echo "${user}" | jq -r '.email // .name // "user"')")
        if [[ -n "${userId}" ]]; then
            users=$(echo "${users}" | jq -c --arg auth "${userId}" --arg email "${userEmail}-Hysteria2" '. += [{auth: $auth, level: 0, email: $email}]')
        fi
    done < <(echo "${currentClients:-[]}" | jq -c '.[]')

    echo "${users}"
}
# 添加Xray-core 出站
addXrayOutbound() {
    local tag=$1
    local domainStrategy=

    if echo "${tag}" | grep -q "IPv4"; then
        domainStrategy="ForceIPv4"
    elif echo "${tag}" | grep -q "IPv6"; then
        domainStrategy="ForceIPv6"
    fi

    if [[ -n "${domainStrategy}" ]]; then
        cat <<EOF >"/opt/xray-agent/xray/conf/${tag}.json"
{
    "outbounds":[
        {
            "protocol":"freedom",
            "settings":{
                "domainStrategy":"${domainStrategy}"
            },
            "tag":"${tag}"
        }
    ]
}
EOF
    fi
    # direct
    if echo "${tag}" | grep -q "direct"; then
        cat <<EOF >"/opt/xray-agent/xray/conf/${tag}.json"
{
    "outbounds":[
        {
            "protocol":"freedom",
            "settings": {
                "domainStrategy":"UseIP"
            },
            "tag":"${tag}"
        }
    ]
}
EOF
    fi
    # blackhole
    if echo "${tag}" | grep -q "blackhole"; then
        cat <<EOF >"/opt/xray-agent/xray/conf/${tag}.json"
{
    "outbounds":[
        {
            "protocol":"blackhole",
            "tag":"${tag}"
        }
    ]
}
EOF
    fi
    # socks5 outbound
    if echo "${tag}" | grep -q "socks5"; then
        cat <<EOF >"/opt/xray-agent/xray/conf/${tag}.json"
{
  "outbounds": [
    {
      "protocol": "socks",
      "tag": "${tag}",
      "settings": {
        "servers": [
          {
            "address": "${socks5RoutingOutboundIP}",
            "port": ${socks5RoutingOutboundPort},
            "users": [
              {
                "user": "${socks5RoutingOutboundUserName}",
                "pass": "${socks5RoutingOutboundPassword}"
              }
            ]
          }
        ]
      }
    }
  ]
}
EOF
    fi
    if echo "${tag}" | grep -q "wireguard_out_IPv4"; then
        cat <<EOF >"/opt/xray-agent/xray/conf/${tag}.json"
{
  "outbounds": [
    {
      "protocol": "wireguard",
      "settings": {
        "secretKey": "${secretKeyWarpReg}",
        "address": [
          "${address}"
        ],
        "peers": [
          {
            "publicKey": "${publicKeyWarpReg}",
            "allowedIPs": [
              "0.0.0.0/0",
              "::/0"
            ],
            "endpoint": "162.159.192.1:2408"
          }
        ],
        "reserved": ${reservedWarpReg},
        "mtu": 1280
      },
      "tag": "${tag}"
    }
  ]
}
EOF
    fi
    if echo "${tag}" | grep -q "wireguard_out_IPv6"; then
        cat <<EOF >"/opt/xray-agent/xray/conf/${tag}.json"
{
  "outbounds": [
    {
      "protocol": "wireguard",
      "settings": {
        "secretKey": "${secretKeyWarpReg}",
        "address": [
          "${address}"
        ],
        "peers": [
          {
            "publicKey": "${publicKeyWarpReg}",
            "allowedIPs": [
              "0.0.0.0/0",
              "::/0"
            ],
            "endpoint": "162.159.192.1:2408"
          }
        ],
        "reserved": ${reservedWarpReg},
        "mtu": 1280
      },
      "tag": "${tag}"
    }
  ]
}
EOF
    fi
}

# 删除 Xray-core出站
removeXrayOutbound() {
    local tag=$1
    if [[ -f "/opt/xray-agent/xray/conf/${tag}.json" ]]; then
        rm "/opt/xray-agent/xray/conf/${tag}.json" >/dev/null 2>&1
    fi
}
# 初始化Xray 配置文件

initXrayConfig() {
    echoContent skyBlue "\n进度 $2/${totalProgress} : 初始化Xray配置"
    echo
    # 仅保留 Vision、WebSocket、Reality Vision 与 Hysteria2。
    # 重新安装/升级时删除旧版本遗留的其他协议入站，避免 Xray 继续加载。
    find /opt/xray-agent/xray/conf -maxdepth 1 -type f \( \
        -name '*trojan*inbounds.json' -o \
        -name '*VLESS_gRPC_inbounds.json' -o \
        -name '*VLESS_vision_gRPC_inbounds.json' -o \
        -name '*VLESS_XHTTP_inbounds.json' -o \
        -name '*tuic_inbounds.json' -o \
        -name '*naive_inbounds.json' -o \
        -name '*VMess_HTTPUpgrade_inbounds.json' -o \
        -name '*anytls_inbounds.json' \
    \) -delete 2>/dev/null

    local uuid=
    local addClientsStatus=
    # 总是询问是否使用上次用户配置，不管lastInstallationConfig的值
    if [[ -n "${currentUUID}" ]]; then
        read -r -p "读取到上次用户配置，是否使用上次安装的配置 ？[y/n]:" historyUUIDStatus
        if [[ "${historyUUIDStatus}" == "y" ]]; then
            addClientsStatus=true
            echoContent green "\n ---> 使用成功"
        fi
    fi

    if [[ -z "${addClientsStatus}" ]]; then
        echoContent yellow "请输入自定义UUID[需合法]，[回车]随机UUID"
        read -r -p 'UUID:' customUUID

        if [[ -n ${customUUID} ]]; then
            uuid=${customUUID}
        else
            uuid=$(/opt/xray-agent/xray/xray uuid)
        fi

        echoContent yellow "\n请输入自定义用户名[需合法]，[回车]随机用户名"
        read -r -p '用户名:' customEmail
        if [[ -z ${customEmail} ]]; then
            customEmail="$(echo "${uuid}" | cut -d "-" -f 1)-VLESS_TCP/TLS_Vision"
        fi
    fi

    if [[ -z "${addClientsStatus}" && -z "${uuid}" ]]; then
        addClientsStatus=
        echoContent red "\n ---> uuid读取错误，随机生成"
        uuid=$(/opt/xray-agent/xray/xray uuid)
    fi

    if [[ -n "${uuid}" ]]; then
        currentClients='[{"id":"'${uuid}'","add":"'${add}'","flow":"xtls-rprx-vision","email":"'${customEmail}'"}]'
        echoContent green "\n ${customEmail}:${uuid}"
        echo
    fi

    # log
    if [[ ! -f "/opt/xray-agent/xray/conf/00_log.json" ]]; then

        cat <<EOF >/opt/xray-agent/xray/conf/00_log.json
{
  "log": {
    "error": "/opt/xray-agent/xray/error.log",
    "loglevel": "warning",
    "dnsLog": false
  }
}
EOF
    fi

    if [[ ! -f "/opt/xray-agent/xray/conf/12_policy.json" ]]; then

        cat <<EOF >/opt/xray-agent/xray/conf/12_policy.json
{
  "policy": {
      "levels": {
          "0": {
              "handshake": $((1 + RANDOM % 4)),
              "connIdle": $((250 + RANDOM % 51))
          }
      }
  }
}
EOF
    fi

    addXrayOutbound "z_direct_outbound"
    # dns
    if [[ ! -f "/opt/xray-agent/xray/conf/11_dns.json" ]]; then
        cat <<EOF >/opt/xray-agent/xray/conf/11_dns.json
{
    "dns": {
        "servers": [
          "localhost"
        ]
  }
}
EOF
    fi
    # routing
    cat <<EOF >/opt/xray-agent/xray/conf/09_routing.json
{
  "routing": {
    "rules": [
      {
        "type": "field",
        "domain": [
          "domain:gstatic.com",
          "domain:googleapis.com",
	  "domain:googleapis.cn"
        ],
        "outboundTag": "z_direct_outbound"
      }
    ]
  }
}
EOF
    # VLESS_TCP_TLS_Vision
    # 回落nginx
    local fallbacksList='{"dest":31300,"xver":1},{"alpn":"h2","dest":31302,"xver":1}'

    # VLESS_WS_TLS
    if echo "${selectCustomInstallType}" | grep -q ",1," || [[ "$1" == "all" ]]; then
        fallbacksList=${fallbacksList}',{"path":"/'${customPath}'","dest":31297,"xver":1}'
        cat <<EOF >/opt/xray-agent/xray/conf/03_VLESS_WS_inbounds.json
{
"inbounds":[
    {
      "port": 31297,
      "listen": "127.0.0.1",
      "protocol": "vless",
      "tag":"VLESSWS",
      "settings": {
        "clients": $(initXrayClients 1),
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "security": "none",
        "wsSettings": {
          "acceptProxyProtocol": true,
          "path": "/${customPath}"
        }
      }
    }
]
}
EOF
    elif [[ -z "$3" ]]; then
        rm /opt/xray-agent/xray/conf/03_VLESS_WS_inbounds.json >/dev/null 2>&1
    fi

    # Hysteria2 over QUIC/UDP, implemented directly by Xray-core.
    if echo "${selectCustomInstallType}" | grep -q ",6," || [[ "$1" == "all" ]]; then
        echoContent skyBlue "\n===================== 配置Hysteria2+TLS =====================\n"
        initHysteria2Port
        initHysteria2BbrProfile
        initHysteria2Masquerade
        local hysteria2UserField="clients"
        local installedXrayVersion=
        installedXrayVersion=$(/opt/xray-agent/xray/xray --version 2>/dev/null | awk 'NR == 1 {print $2}')
        if xrayVersionAtLeast "${installedXrayVersion}" "26.5.9"; then
            hysteria2UserField="users"
        fi
        cat <<EOF >/opt/xray-agent/xray/conf/05_hysteria2_inbounds.json
{
  "inbounds": [
    {
      "port": ${hysteria2Port},
      "listen": "0.0.0.0",
      "protocol": "hysteria",
      "tag": "Hysteria2",
      "settings": {
        "version": 2,
        "${hysteria2UserField}": $(initXrayHysteria2Clients)
      },
      "streamSettings": {
        "network": "hysteria",
        "security": "tls",
        "tlsSettings": {
          "rejectUnknownSni": true,
          "minVersion": "1.3",
          "alpn": ["h3"],
          "certificates": [
            {
              "certificateFile": "/opt/xray-agent/tls/${domain}.crt",
              "keyFile": "/opt/xray-agent/tls/${domain}.key",
              "ocspStapling": 3600
            }
          ]
        },
        "hysteriaSettings": {
          "version": 2,
          "udpIdleTimeout": 60,
          "masquerade": ${hysteria2MasqueradeConfig}
        },
        "finalmask": {
          "quicParams": {
            "congestion": "bbr",
            "bbrProfile": "${hysteria2BbrProfile}"
          }
        }
      }
    }
  ]
}
EOF
    elif [[ -z "$3" ]]; then
        rm /opt/xray-agent/xray/conf/05_hysteria2_inbounds.json >/dev/null 2>&1
    fi
    # VLESS Vision
    if echo "${selectCustomInstallType}" | grep -q ",0," || [[ "$1" == "all" ]]; then

        cat <<EOF >/opt/xray-agent/xray/conf/02_VLESS_TCP_inbounds.json
{
    "inbounds":[
        {
          "port": ${port},
          "protocol": "vless",
          "tag":"VLESSTCP",
          "settings": {
            "clients":$(initXrayClients 0),
            "decryption": "none",
            "fallbacks": [
                ${fallbacksList}
            ]
          },
          "add": "${add}",
          "streamSettings": {
            "network": "tcp",
            "security": "tls",
            "tlsSettings": {
              "rejectUnknownSni": true,
              "minVersion": "1.2",
              "certificates": [
                {
                  "certificateFile": "/opt/xray-agent/tls/${domain}.crt",
                  "keyFile": "/opt/xray-agent/tls/${domain}.key",
                  "ocspStapling": 3600
                }
              ]
            }
          }
        }
    ]
}
EOF
    elif [[ -z "$3" ]]; then
        rm /opt/xray-agent/xray/conf/02_VLESS_TCP_inbounds.json >/dev/null 2>&1
    fi

    # VLESS_TCP/reality
    if echo "${selectCustomInstallType}" | grep -q ",3," || [[ "$1" == "all" ]]; then
        echoContent skyBlue "\n===================== 配置VLESS+Reality =====================\n"

        initXrayRealityPort
        initRealityClientServersName
        initRealityKey
        initRealityMldsa65

        cat <<EOF >/opt/xray-agent/xray/conf/07_VLESS_vision_reality_inbounds.json
{
  "inbounds": [
    {
      "port": ${realityPort},
      "protocol": "vless",
      "tag": "VLESSReality",
      "settings": {
        "clients": $(initXrayClients 3),
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
            "show": false,
            "dest": "${realityServerName}:${realityDomainPort}",
            "xver": 0,
            "serverNames": [
                "${realityServerName}"
            ],
            "privateKey": "${realityPrivateKey}",
            "publicKey": "${realityPublicKey}",
            "mldsa65Seed": "${realityMldsa65Seed}",
            "mldsa65Verify": "${realityMldsa65Verify}",
            "maxTimeDiff": 70000,
            "shortIds": [
                "",
                "6ba85179e30d4fc2"
            ]
        }
      }
    }
  ]
}
EOF
    elif [[ -z "$3" ]]; then
        rm /opt/xray-agent/xray/conf/07_VLESS_vision_reality_inbounds.json >/dev/null 2>&1
    fi
    installSniffing
    if [[ -z "$3" ]]; then
        removeXrayOutbound wireguard_out_IPv4_route
        removeXrayOutbound wireguard_out_IPv6_route
        removeXrayOutbound wireguard_outbound
        removeXrayOutbound IPv4_out
        removeXrayOutbound IPv6_out
        removeXrayOutbound socks5_outbound
        removeXrayOutbound blackhole_out
        removeXrayOutbound wireguard_out_IPv6
        removeXrayOutbound wireguard_out_IPv4
        addXrayOutbound z_direct_outbound
    fi
}

