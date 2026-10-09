normalizeXrayEmail() {
    local value=$1 suffix
    for suffix in VLESS_TCP/TLS_Vision VLESS_WS VLESS_XHTTP_Reality VLESS_XHTTP vless_reality_vision Hysteria2; do
        if [[ "${value}" == *-"${suffix}" ]]; then
            printf '%s\n' "${value%-${suffix}}"
            return 0
        fi
    done
    printf '%s\n' "${value}"
}

validateXrayUserTag() {
    [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$ ]]
}

initXrayClients() {
    local clientType=$1
    local newUUID=$2
    local newEmail=$3
    case "${clientType}" in
        0 | 1 | 3 | 12 | 14) ;;
        *)
            echoContent red "不支持的 Xray 客户端类型: ${clientType}" >&2
            return 1
            ;;
    esac

    # Check whether currentClients is empty or null to avoid jq errors
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
        # XHTTP has no XTLS splice; the Vision flow only works there together
        # with VLESS Encryption, so these users carry no flow.
        12) jq -nc --arg id "${userUUID}" --arg email "${userEmail}-VLESS_XHTTP_Reality" '{id:$id,email:$email}' ;;
        14) jq -nc --arg id "${userUUID}" --arg email "${userEmail}-VLESS_XHTTP" '{id:$id,email:$email}' ;;
        *) return 1 ;;
    esac
}

# Convert the script's existing UUID users into Xray-core Hysteria2 auth clients.
# The UUID is used as auth so that all installed protocols share one set of accounts.
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
# Add an Xray-core outbound
addXrayOutbound() {
    local tag=$1
    local domainStrategy=

    if echo "${tag}" | grep -q "IPv4"; then
        domainStrategy="ForceIPv4"
    elif echo "${tag}" | grep -q "IPv6"; then
        domainStrategy="ForceIPv6"
    fi

    # "UseIP" for the plain direct outbound.
    if [[ -z "${domainStrategy}" ]] && echo "${tag}" | grep -q "direct"; then
        domainStrategy="UseIP"
    fi
    if [[ -n "${domainStrategy}" ]]; then
        # freedom.settings.domainStrategy is deprecated since v26.9; the
        # sockopt form works on current stable and pre-releases alike.
        jq -n --arg tag "${tag}" --arg strategy "${domainStrategy}" '{outbounds:[{
            protocol:"freedom", tag:$tag,
            streamSettings:{sockopt:{domainStrategy:$strategy}}
        }]}' >"/opt/xray-agent/xray/conf/${tag}.json"
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

# Remove an Xray-core outbound
removeXrayOutbound() {
    local tag=$1
    if [[ -f "/opt/xray-agent/xray/conf/${tag}.json" ]]; then
        rm "/opt/xray-agent/xray/conf/${tag}.json" >/dev/null 2>&1
    fi
}
# Initialize the Xray config file

initXrayConfig() {
    echoContent skyBlue "\n进度 $2/${totalProgress} : 初始化Xray配置"
    if [[ "$1" == "all" ]]; then
        selectCustomInstallType=${recommendedInstallSelection}
    fi
    # Regenerating only some inbounds (e.g. REALITY management) skips the
    # path prompt; keep the installed path.
    customPath=${customPath:-${currentPath}}
    echo
    # Keep only Vision, WebSocket, Reality Vision and Hysteria2.
    # On reinstall/upgrade, remove leftover inbounds of other protocols from older versions so Xray does not keep loading them.
    find /opt/xray-agent/xray/conf -maxdepth 1 -type f \( \
        -name '*trojan*inbounds.json' -o \
        -name '*VLESS_gRPC_inbounds.json' -o \
        -name '*VLESS_vision_gRPC_inbounds.json' -o \
        -name '*tuic_inbounds.json' -o \
        -name '*naive_inbounds.json' -o \
        -name '*VMess_HTTPUpgrade_inbounds.json' -o \
        -name '*anytls_inbounds.json' \
        \) -delete 2>/dev/null

    local uuid=
    local addClientsStatus=
    # Always ask whether to reuse the previous user config, regardless of lastInstallationConfig
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

        echoContent yellow "\n请输入账号标签(tag)，例如 jp_vision，[回车]使用 UUID 前缀"
        read -r -p '账号标签:' customEmail
        if [[ -z ${customEmail} ]]; then
            customEmail="$(echo "${uuid}" | cut -d "-" -f 1)"
        elif ! validateXrayUserTag "${customEmail}"; then
            echoContent red " ---> 标签仅支持字母、数字、点、下划线和连字符，且最长 64 位"
            return 1
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
    # Fall back to nginx
    local fallbacksList='{"dest":31300,"xver":1},{"alpn":"h2","dest":31302,"xver":1}'

    # VLESS_WS_TLS
    if hasProtocol "${selectCustomInstallType}" 1; then
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
    if hasProtocol "${selectCustomInstallType}" 6; then
        echoContent skyBlue "\n===================== 配置Hysteria2+TLS =====================\n"
        initHysteria2Port
        initHysteria2BbrProfile
        initHysteria2Masquerade
        # "clients" works on every supported core. v26.5.9+ also accepts
        # "users", but stable v26.3.27 silently ignores it (no accounts, every
        # auth fails), which would break a rollback from a pre-release.
        local hysteria2UserField="clients"
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
        # Masquerading turned off: drop the key instead of keeping "null".
        if [[ "${hysteria2MasqueradeConfig}" == "null" ]]; then
            local withoutMasquerade
            withoutMasquerade=$(jq 'del(.inbounds[0].streamSettings.hysteriaSettings.masquerade)' \
                /opt/xray-agent/xray/conf/05_hysteria2_inbounds.json) \
                && echo "${withoutMasquerade}" >/opt/xray-agent/xray/conf/05_hysteria2_inbounds.json
        fi
    elif [[ -z "$3" ]]; then
        rm /opt/xray-agent/xray/conf/05_hysteria2_inbounds.json >/dev/null 2>&1
    fi
    # VLESS Vision
    if hasProtocol "${selectCustomInstallType}" 0; then

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

    # REALITY: one identity (target, keys) shared by both REALITY inbounds.
    if hasProtocol "${selectCustomInstallType}" 3 || hasProtocol "${selectCustomInstallType}" 12; then
        echoContent skyBlue "\n===================== 配置 REALITY =====================\n"
        initRealityClientServersName
        initRealityKey
        initRealityMldsa65
    fi

    # VLESS_TCP/reality
    if hasProtocol "${selectCustomInstallType}" 3; then
        initXrayRealityPort

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

    # VLESS + XHTTP + REALITY: direct, no domain needed, its own port.
    if hasProtocol "${selectCustomInstallType}" 12; then
        initXrayXhttpRealityPort
        jq -n --argjson port "${xhttpRealityPort}" --arg path "/${customPath}xhttp" \
            --argjson clients "$(initXrayClients 12)" --arg sni "${realityServerName}" \
            --arg dest "${realityServerName}:${realityDomainPort}" --arg privateKey "${realityPrivateKey}" \
            --arg publicKey "${realityPublicKey}" --arg seed "${realityMldsa65Seed}" --arg verify "${realityMldsa65Verify}" '
            {inbounds:[{
                port:$port, protocol:"vless", tag:"VLESSRealityXHTTP",
                settings:{clients:$clients, decryption:"none"},
                streamSettings:{
                    network:"xhttp", security:"reality", xhttpSettings:{path:$path},
                    realitySettings:({show:false, dest:$dest, xver:0, serverNames:[$sni],
                        privateKey:$privateKey, publicKey:$publicKey, maxTimeDiff:70000,
                        shortIds:["", "6ba85179e30d4fc2"]}
                        + (if $seed != "" then {mldsa65Seed:$seed, mldsa65Verify:$verify} else {} end))
                }
            }]}' >/opt/xray-agent/xray/conf/12_VLESS_XHTTP_inbounds.json || return 1
    elif [[ -z "$3" ]]; then
        rm -f /opt/xray-agent/xray/conf/12_VLESS_XHTTP_inbounds.json
    fi

    # VLESS + XHTTP + TLS: nginx (the Vision fallback, or a panel site on
    # 443) terminates TLS and grpc_passes the path to this local inbound.
    if hasProtocol "${selectCustomInstallType}" 14; then
        jq -n --argjson port "${xhttpInboundPort}" --arg path "/${customPath}xhttp" \
            --arg trusted "${xhttpTrustedHeader}" --argjson clients "$(initXrayClients 14)" '
            {inbounds:[{
                listen:"127.0.0.1", port:$port, protocol:"vless", tag:"VLESSXHTTP",
                settings:{clients:$clients, decryption:"none"},
                streamSettings:{network:"xhttp", xhttpSettings:{path:$path},
                    sockopt:{trustedXForwardedFor:[$trusted]}}
            }]}' >/opt/xray-agent/xray/conf/14_VLESS_XHTTP_TLS_inbounds.json || return 1
    elif [[ -z "$3" ]]; then
        rm -f /opt/xray-agent/xray/conf/14_VLESS_XHTTP_TLS_inbounds.json
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
