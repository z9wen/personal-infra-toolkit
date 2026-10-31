# Read the nginx subscription port
readNginxSubscribe() {
    subscribeType="https"
    if [[ -f "${nginxConfigPath}subscribe.conf" ]]; then
        subscribePort=$(grep "listen" "${nginxConfigPath}subscribe.conf" | awk '{print $2}')
        subscribeDomain=$(grep "server_name" "${nginxConfigPath}subscribe.conf" | awk '{print $2}')
        subscribeDomain=${subscribeDomain//;/}
        if [[ -n "${currentHost}" && "${subscribeDomain}" != "${currentHost}" ]]; then
            subscribePort=
            subscribeType=
        else
            if ! grep "listen" "${nginxConfigPath}subscribe.conf" | grep -q "ssl"; then
                subscribeType="http"
            fi
        fi
    fi
}
# Install the subscription service
installSubscribe() {
    readNginxSubscribe
    local nginxSubscribeListen=
    local nginxSubscribeSSL=
    local serverName=
    local SSLType=
    local listenIPv6=
    if [[ -z "${subscribePort}" ]]; then

        local nginxBin="nginx"
        if [[ -f "/www/server/nginx/sbin/nginx" ]]; then
            nginxBin="/www/server/nginx/sbin/nginx"
        fi
        nginxVersion=$("${nginxBin}" -v 2>&1)

        if echo "${nginxVersion}" | grep -q "not found" || [[ -z "${nginxVersion}" ]]; then
            echoContent yellow "未检测到nginx，无法使用订阅服务\n"
            read -r -p "是否安装[y/n]？" installNginxStatus
            if [[ "${installNginxStatus}" == "y" ]]; then
                installNginxTools
            else
                echoContent red " ---> 放弃安装nginx\n"
                exit 0
            fi
        fi
        echoContent yellow "开始配置订阅，请输入订阅的端口[默认443]\n"

        local subscribePortInput="${subscribePort}"
        if [[ -z "${subscribePortInput}" ]]; then
            read -r -p "端口:" subscribePortInput
            if [[ -z "${subscribePortInput}" ]]; then
                subscribePortInput=443
            fi
        fi
        result=("${subscribePortInput}")
        echo
        echoContent yellow " ---> 开始配置订阅的伪装站点\n"
        nginxBlog
        echo
        local httpSubscribeStatus=

        if ! echo "${selectCustomInstallType}" | grep -qE ",(0|1|3|6|12|14)," && ! echo "${currentInstallProtocolType}" | grep -qE ",(0|1|3|6|12|14)," && [[ -z "${domain}" ]]; then
            httpSubscribeStatus=true
        fi

        if [[ "${httpSubscribeStatus}" == "true" ]]; then

            echoContent yellow "未发现tls证书，使用无加密订阅，可能被运营商拦截，请注意风险。"
            echo
            read -r -p "是否使用http订阅[y/n]？" addNginxSubscribeStatus
            echo
            if [[ "${addNginxSubscribeStatus}" != "y" ]]; then
                echoContent yellow " ---> 退出安装"
                exit
            fi
        else
            local subscribeServerName=
            if [[ -n "${currentHost}" ]]; then
                subscribeServerName="${currentHost}"
            else
                subscribeServerName="${domain}"
            fi

            SSLType="ssl"
            serverName="server_name ${subscribeServerName};"
            nginxSubscribeSSL="ssl_certificate /opt/xray-agent/tls/${subscribeServerName}.crt;ssl_certificate_key /opt/xray-agent/tls/${subscribeServerName}.key;"
        fi
        if [[ -n "$(curl --connect-timeout 2 -s -6 http://www.cloudflare.com/cdn-cgi/trace | grep "ip" | cut -d "=" -f 2)" ]]; then
            listenIPv6="listen [::]:${result[-1]} ${SSLType};"
        fi
        if echo "${nginxVersion}" | grep -q "1.25" && [[ $(echo "${nginxVersion}" | awk -F "[.]" '{print $3}') -gt 0 ]] || [[ $(echo "${nginxVersion}" | awk -F "[.]" '{print $2}') -gt 25 ]]; then
            nginxSubscribeListen="listen ${result[-1]} ${SSLType} so_keepalive=on;http2 on;${listenIPv6}"
        else
            nginxSubscribeListen="listen ${result[-1]} ${SSLType} so_keepalive=on;${listenIPv6}"
        fi

        cat <<EOF >${nginxConfigPath}subscribe.conf
server {
    ${nginxSubscribeListen}
    ${serverName}
    ${nginxSubscribeSSL}
    ssl_protocols              TLSv1.2 TLSv1.3;
    ssl_ciphers                TLS13_AES_128_GCM_SHA256:TLS13_AES_256_GCM_SHA384:TLS13_CHACHA20_POLY1305_SHA256:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305;
    ssl_prefer_server_ciphers  on;

    resolver                   1.1.1.1 valid=60s;
    resolver_timeout           2s;
    client_max_body_size 100m;
    root ${nginxStaticPath};
    location ~ ^/s/(clashMeta|default|clashMetaProfiles)/(.*) {
        default_type 'text/plain; charset=utf-8';
        alias /opt/xray-agent/subscribe/\$1/\$2;
    }
    location / {
    }
}
EOF
        bootStartup nginx
        handleNginx stop
        handleNginx start
    fi
    if [[ -z $(pgrep -f "nginx") ]]; then
        handleNginx start
    fi
}
# Uninstall the subscription service
unInstallSubscribe() {
    rm -rf ${nginxConfigPath}subscribe.conf >/dev/null 2>&1
}

# Add a subscription
addSubscribeMenu() {
    echoContent skyBlue "\n===================== 添加其他机器订阅 ======================="
    echoContent yellow "1.添加"
    echoContent yellow "2.移除"
    echoContent red "=============================================================="
    read -r -p "请选择:" addSubscribeStatus
    if [[ "${addSubscribeStatus}" == "1" ]]; then
        addOtherSubscribe
    elif [[ "${addSubscribeStatus}" == "2" ]]; then
        if [[ ! -f "/opt/xray-agent/subscribe_remote/remoteSubscribeUrl" ]]; then
            echoContent green " ---> 未安装其他订阅"
            exit 0
        fi
        grep -v '^$' "/opt/xray-agent/subscribe_remote/remoteSubscribeUrl" | awk '{print NR""":"$0}'
        read -r -p "请选择要删除的订阅编号[仅支持单个删除]:" delSubscribeIndex
        if [[ -z "${delSubscribeIndex}" ]]; then
            echoContent green " ---> 不可以为空"
            exit 0
        fi

        sed -i "$((delSubscribeIndex))d" "/opt/xray-agent/subscribe_remote/remoteSubscribeUrl" >/dev/null 2>&1

        echoContent green " ---> 其他机器订阅删除成功"
        subscribe
    fi
}

manageSubscriptions() {
    if [[ -z "${configPath}" ]]; then
        echoContent red " ---> 未安装"
        return
    fi

    local subscriptionManageStatus
    while true; do
        echoContent skyBlue "\n订阅管理"
        echoContent red "\n=============================================================="
        echoContent yellow "1.查看或重新生成本机订阅"
        echoContent yellow "2.管理其他机器订阅"
        echoContent yellow "0.返回主菜单"
        echoContent red "=============================================================="
        read -r -p "请选择:" subscriptionManageStatus
        case ${subscriptionManageStatus} in
            1) subscribe ;;
            2) addSubscribeMenu ;;
            0) return ;;
            *) echoContent red " ---> 请输入 0-2" ;;
        esac
        read -r -p "按回车键继续..."
    done
}

# Add a clashMeta subscription from another machine
addOtherSubscribe() {
    echoContent yellow "#注意事项:"
    echoContent skyBlue "录入示例：example.com:443:vps1\n"
    read -r -p "请输入域名 端口 机器别名:" remoteSubscribeUrl
    if [[ -z "${remoteSubscribeUrl}" ]]; then
        echoContent red " ---> 不可为空"
        addOtherSubscribe
    elif ! echo "${remoteSubscribeUrl}" | grep -q ":"; then
        echoContent red " ---> 规则不合法"
    else

        if [[ -f "/opt/xray-agent/subscribe_remote/remoteSubscribeUrl" ]] && grep -q "${remoteSubscribeUrl}" /opt/xray-agent/subscribe_remote/remoteSubscribeUrl; then
            echoContent red " ---> 此订阅已添加"
            exit 0
        fi
        echo
        read -r -p "是否是HTTP订阅？[y/n]" httpSubscribeStatus
        if [[ "${httpSubscribeStatus}" == "y" ]]; then
            remoteSubscribeUrl="${remoteSubscribeUrl}:http"
        fi
        echo "${remoteSubscribeUrl}" >>/opt/xray-agent/subscribe_remote/remoteSubscribeUrl
        subscribe
    fi
}
# Random salt
initRandomSalt() {
    local chars="abcdefghijklmnopqrtuxyz"
    local initCustomPath=
    for i in {1..10}; do
        echo "${i}" >/dev/null
        initCustomPath+="${chars:RANDOM%${#chars}:1}"
    done
    echo "${initCustomPath}"
}
# Subscription
subscribe() {
    readInstallProtocolType
    installSubscribe

    readNginxSubscribe
    local renewSalt=$1
    local showStatus=$2
    if [[ "${coreInstallType}" == "1" ]]; then

        echoContent skyBlue "-------------------------备注---------------------------------"
        echoContent yellow "# 查看订阅会重新生成本地账号的订阅"
        echoContent red "# 需要手动输入md5加密的salt值，如果不了解使用随机即可"
        echoContent yellow "# 不影响已添加的远程订阅的内容\n"

        if [[ -f "/opt/xray-agent/subscribe_local/subscribeSalt" && -n $(cat "/opt/xray-agent/subscribe_local/subscribeSalt") ]]; then
            if [[ -z "${renewSalt}" ]]; then
                read -r -p "读取到上次安装设置的Salt，是否使用上次生成的Salt ？[y/n]:" historySaltStatus
                if [[ "${historySaltStatus}" == "y" ]]; then
                    subscribeSalt=$(cat /opt/xray-agent/subscribe_local/subscribeSalt)
                else
                    read -r -p "请输入salt值, [回车]使用随机:" subscribeSalt
                fi
            else
                subscribeSalt=$(cat /opt/xray-agent/subscribe_local/subscribeSalt)
            fi
        else
            read -r -p "请输入salt值, [回车]使用随机:" subscribeSalt
            showStatus=
        fi

        if [[ -z "${subscribeSalt}" ]]; then
            subscribeSalt=$(initRandomSalt)
        fi
        echoContent yellow "\n ---> Salt: ${subscribeSalt}"

        echo "${subscribeSalt}" >/opt/xray-agent/subscribe_local/subscribeSalt

        rm -rf /opt/xray-agent/subscribe/default/*
        rm -rf /opt/xray-agent/subscribe/clashMeta/*
        rm -rf /opt/xray-agent/subscribe_local/default/*
        rm -rf /opt/xray-agent/subscribe_local/clashMeta/*
        showAccounts >/dev/null
        if [[ -n $(ls /opt/xray-agent/subscribe_local/default/) ]]; then
            if [[ -f "/opt/xray-agent/subscribe_remote/remoteSubscribeUrl" && -n $(cat "/opt/xray-agent/subscribe_remote/remoteSubscribeUrl") ]]; then
                if [[ -z "${renewSalt}" ]]; then
                    read -r -p "读取到其他订阅，是否更新？[y/n]" updateOtherSubscribeStatus
                else
                    updateOtherSubscribeStatus=y
                fi
            fi
            local subscribePortLocal="${subscribePort}"
            find /opt/xray-agent/subscribe_local/default/* | while read -r email; do
                email=$(echo "${email}" | awk -F "[d][e][f][a][u][l][t][/]" '{print $2}')

                local emailMd5=
                emailMd5=$(echo -n "${email}${subscribeSalt}"$'\n' | md5sum | awk '{print $1}')

                cat "/opt/xray-agent/subscribe_local/default/${email}" >>"/opt/xray-agent/subscribe/default/${emailMd5}"
                if [[ "${updateOtherSubscribeStatus}" == "y" ]]; then
                    updateRemoteSubscribe "${emailMd5}" "${email}"
                fi
                local base64Result
                base64Result=$(base64 -w 0 "/opt/xray-agent/subscribe/default/${emailMd5}")
                echo "${base64Result}" >"/opt/xray-agent/subscribe/default/${emailMd5}"
                echoContent yellow "--------------------------------------------------------------"
                local currentDomain=${currentHost}

                if [[ -n "${currentDefaultPort}" && "${currentDefaultPort}" != "443" ]]; then
                    currentDomain="${currentHost}:${currentDefaultPort}"
                fi
                if [[ -n "${subscribePortLocal}" ]]; then
                    if [[ "${subscribeType}" == "http" ]]; then
                        currentDomain="$(getPublicIP):${subscribePort}"
                    else
                        currentDomain="${currentHost}:${subscribePort}"
                    fi
                fi
                if [[ -z "${showStatus}" ]]; then
                    echoContent skyBlue "\n----------默认订阅----------\n"
                    echoContent green "email:${email}\n"
                    echoContent yellow "url:${subscribeType}://${currentDomain}/s/default/${emailMd5}\n"
                    echoContent yellow "在线二维码:https://api-qr-server.zwen.cc/v1/create-qr-code/?size=400x400&data=${subscribeType}://${currentDomain}/s/default/${emailMd5}\n"
                    echo "${subscribeType}://${currentDomain}/s/default/${emailMd5}" | qrencode -s 10 -m 1 -t UTF8

                    # clashMeta
                    if [[ -f "/opt/xray-agent/subscribe_local/clashMeta/${email}" ]]; then

                        cat "/opt/xray-agent/subscribe_local/clashMeta/${email}" >>"/opt/xray-agent/subscribe/clashMeta/${emailMd5}"

                        sed -i '1i\proxies:' "/opt/xray-agent/subscribe/clashMeta/${emailMd5}"

                        local clashProxyUrl="${subscribeType}://${currentDomain}/s/clashMeta/${emailMd5}"
                        clashMetaConfig "${clashProxyUrl}" "${emailMd5}"
                        echoContent skyBlue "\n----------clashMeta订阅----------\n"
                        echoContent yellow "url:${subscribeType}://${currentDomain}/s/clashMetaProfiles/${emailMd5}\n"
                        echoContent yellow "在线二维码:https://api-qr-server.zwen.cc/v1/create-qr-code/?size=400x400&data=${subscribeType}://${currentDomain}/s/clashMetaProfiles/${emailMd5}\n"
                        echo "${subscribeType}://${currentDomain}/s/clashMetaProfiles/${emailMd5}" | qrencode -s 10 -m 1 -t UTF8

                    fi
                    echoContent skyBlue "--------------------------------------------------------------"
                else
                    echoContent green " ---> email:${email}，订阅已更新，请使用客户端重新拉取"
                fi

            done
        fi
    else
        echoContent red " ---> 未安装伪装站点，无法使用订阅服务"
    fi
}

# Update remote subscriptions
updateRemoteSubscribe() {

    local emailMD5=$1
    local email=$2
    while read -r line; do
        local subscribeType=
        subscribeType="https"

        local serverAlias=
        serverAlias=$(echo "${line}" | awk -F "[:]" '{print $3}')

        local remoteUrl=
        remoteUrl=$(echo "${line}" | awk -F "[:]" '{print $1":"$2}')

        local subscribeTypeRemote=
        subscribeTypeRemote=$(echo "${line}" | awk -F "[:]" '{print $4}')

        if [[ -n "${subscribeTypeRemote}" ]]; then
            subscribeType="${subscribeTypeRemote}"
        fi
        local clashMetaProxies=

        clashMetaProxies=$(curl --fail --silent --show-error --connect-timeout 10 --max-time 30 "${subscribeType}://${remoteUrl}/s/clashMeta/${emailMD5}" | sed '/proxies:/d' | sed "s/\"${email}/\"${email}_${serverAlias}/g")

        if ! echo "${clashMetaProxies}" | grep -q "nginx" && [[ -n "${clashMetaProxies}" ]]; then
            echo "${clashMetaProxies}" >>"/opt/xray-agent/subscribe/clashMeta/${emailMD5}"
            echoContent green " ---> clashMeta订阅 ${remoteUrl}:${email} 更新成功"
        else
            echoContent red " ---> clashMeta订阅 ${remoteUrl}:${email}不存在"
        fi

        local default=
        default=$(curl --fail --silent --show-error --connect-timeout 10 --max-time 30 "${subscribeType}://${remoteUrl}/s/default/${emailMD5}")

        if ! echo "${default}" | grep -q "nginx" && [[ -n "${default}" ]]; then
            default=$(echo "${default}" | base64 -d | sed "s/#${email}/#${email}_${serverAlias}/g")
            echo "${default}" >>"/opt/xray-agent/subscribe/default/${emailMD5}"

            echoContent green " ---> 通用订阅 ${remoteUrl}:${email} 更新成功"
        else
            echoContent red " ---> 通用订阅 ${remoteUrl}:${email} 不存在"
        fi

    done < <(grep -v '^$' <"/opt/xray-agent/subscribe_remote/remoteSubscribeUrl")
}
