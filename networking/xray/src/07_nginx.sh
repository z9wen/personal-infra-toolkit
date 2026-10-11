# Check the domain's IP via DNS
checkDNSIP() {
    local domain=$1
    local dnsIP=
    ipType=4
    dnsIP=$(dig @1.1.1.1 +time=2 +short "${domain}" | grep -E "^(([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])\.){3}([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])$")
    if [[ -z "${dnsIP}" ]]; then
        dnsIP=$(dig @8.8.8.8 +time=2 +short "${domain}" | grep -E "^(([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])\.){3}([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])$")
    fi
    if echo "${dnsIP}" | grep -q "timed out" || [[ -z "${dnsIP}" ]]; then
        echo
        echoContent red " ---> 无法通过DNS获取域名 IPv4 地址"
        echoContent green " ---> 尝试检查域名 IPv6 地址"
        dnsIP=$(dig @2606:4700:4700::1111 +time=2 aaaa +short "${domain}")
        ipType=6
        if echo "${dnsIP}" | grep -q "network unreachable" || [[ -z "${dnsIP}" ]]; then
            echoContent red " ---> 无法通过DNS获取域名IPv6地址，退出安装"
            exit 0
        fi
    fi
    local publicIP=

    publicIP=$(getPublicIP "${ipType}")
    if [[ "${publicIP}" != "${dnsIP}" ]]; then
        echoContent red " ---> 域名解析IP与当前服务器IP不一致\n"
        echoContent yellow " ---> 请检查域名解析是否生效以及正确"
        echoContent green " ---> 当前VPS IP：${publicIP}"
        echoContent green " ---> DNS解析 IP：${dnsIP}"
        exit 0
    else
        echoContent green " ---> 域名IP校验通过"
    fi
}
# Check the actual port open status
checkPortOpen() {
    local port=$1
    local domain=$2
    local checkPortOpenResult=
    local xrayWasRunning=false
    if pgrep -f "xray/xray" >/dev/null; then
        xrayWasRunning=true
        handleXray stop >/dev/null 2>&1 || return 1
    fi
    allowPort "${port}"

    if [[ -z "${btDomain}" ]]; then

        handleNginx stop
        # Initialize the nginx config
        touch ${nginxConfigPath}checkPortOpen.conf
        local listenIPv6PortConfig=

        if [[ -n $(curl -s -6 -m 4 http://www.cloudflare.com/cdn-cgi/trace | grep "ip" | cut -d "=" -f 2) ]]; then
            listenIPv6PortConfig="listen [::]:${port};"
        fi
        cat <<EOF >${nginxConfigPath}checkPortOpen.conf
server {
    listen ${port};
    ${listenIPv6PortConfig}
    server_name ${domain};
    location /checkPort {
        return 200 'fjkvymb6len';
    }
    location /ip {
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header REMOTE-HOST \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        default_type text/plain;
        return 200 \$proxy_add_x_forwarded_for;
    }
}
EOF
        handleNginx start
        # Check that the domain + port is reachable
        checkPortOpenResult=$(curl -s -m 10 "http://${domain}:${port}/checkPort")
        localIP=$(curl -s -m 10 "http://${domain}:${port}/ip")
        rm "${nginxConfigPath}checkPortOpen.conf"

        handleNginx stop
        if [[ "${checkPortOpenResult}" == "fjkvymb6len" ]]; then
            echoContent green " ---> 检测到${port}端口已开放"
        else
            echoContent green " ---> 未检测到${port}端口开放，退出安装"
            if echo "${checkPortOpenResult}" | grep -q "cloudflare"; then
                echoContent yellow " ---> 请关闭云朵后等待三分钟重新尝试"
            else
                if [[ -z "${checkPortOpenResult}" ]]; then
                    echoContent red " ---> 请检查云服务商是否启用了网页防火墙"
                    echoContent red " ---> 检查是否自己安装过nginx并且有配置冲突，可以尝试DD纯净系统后重新尝试"
                else
                    echoContent red " ---> 错误日志：${checkPortOpenResult}，请将此错误日志通过issues提交反馈"
                fi
            fi
            if [[ "${xrayWasRunning}" == "true" ]]; then
                restartXray || exit 1
            fi
            exit 0
        fi
        if [[ "${xrayWasRunning}" == "true" ]]; then
            restartXray || return 1
        fi
        checkIP "${localIP}"
    fi
}

# Initialize the Nginx config used for certificate issuance
initTLSNginxConfig() {
    handleNginx stop
    echoContent skyBlue "\n进度  $1/${totalProgress} : 初始化Nginx申请证书配置"
    if [[ -n "${currentHost}" && -z "${lastInstallationConfig}" ]]; then
        echo
        read -r -p "读取到上次安装记录，是否使用上次安装时的域名 ？[y/n]:" historyDomainStatus
        if [[ "${historyDomainStatus}" == "y" ]]; then
            domain=${currentHost}
            echoContent yellow "\n ---> 域名: ${domain}"
        else
            if ! selectLocalAcmeCertificate; then
                echo
                echoContent yellow "请输入要配置的域名 例: example.com --->"
                read -r -p "域名:" domain
            fi
        fi
    elif [[ -n "${currentHost}" && -n "${lastInstallationConfig}" ]]; then
        domain=${currentHost}
    else
        if ! selectLocalAcmeCertificate; then
            echo
            echoContent yellow "请输入要配置的域名 例: example.com --->"
            read -r -p "域名:" domain
        fi
    fi

    if [[ -z ${domain} ]]; then
        echoContent red "  域名不可为空--->"
        initTLSNginxConfig 3
    else
        # Check whether the domain is already configured in Nginx
        if grep -r "server_name.*${domain}" "${nginxConfigPath}" /etc/nginx/sites-enabled/ 2>/dev/null | grep -v "xray-agent.conf" | grep -q "${domain}"; then
            echoContent red "\n=============================================================="
            echoContent yellow "警告：检测到域名 ${domain} 已在 Nginx 中配置"
            echoContent yellow "这可能会导致配置冲突！"
            echoContent red "==============================================================\n"
            read -r -p "是否继续使用此域名（可能影响现有业务）？[y/n]:" domainConflictStatus
            if [[ "${domainConflictStatus}" != "y" ]]; then
                echoContent yellow "请使用不同的域名"
                initTLSNginxConfig 3
                return
            fi
        fi

        dnsTLSDomain=$(echo "${domain}" | awk -F "." '{$1="";print $0}' | sed 's/^[[:space:]]*//' | sed 's/ /./g')
        customPortFunction
        # Modify the config
        handleNginx stop
    fi
}

# Remove the default nginx config
removeNginxDefaultConf() {
    if [[ -f ${nginxConfigPath}default.conf ]]; then
        if [[ "$(grep -c "server_name" <${nginxConfigPath}default.conf)" == "1" ]] && [[ "$(grep -c "server_name  localhost;" <${nginxConfigPath}default.conf)" == "1" ]]; then
            echoContent green " ---> 删除Nginx默认配置"
            rm -rf ${nginxConfigPath}default.conf >/dev/null 2>&1
        fi
    fi
}
# Modify the nginx redirect config
updateRedirectNginxConf() {
    local nginxConfFile="${nginxConfigPath}xray-agent.conf"
    local nginxConfTmp="${nginxConfFile}.tmp.$$"

    if [[ ! -d "${nginxConfigPath}" ]]; then
        echoContent red " ---> Nginx配置目录不存在: ${nginxConfigPath}"
        return 1
    fi

    # Back up the existing config
    if [[ -f "${nginxConfFile}" ]]; then
        local backupFile
        backupFile="${nginxConfFile}.bak_$(date +%Y%m%d_%H%M%S)"
        cp "${nginxConfFile}" "${backupFile}"
        echoContent skyBlue " ---> 已备份原配置: ${backupFile}"
    fi

    local redirectDomain=
    redirectDomain=${domain}:${port}

    local nginxH2Conf=
    nginxH2Conf="listen 127.0.0.1:31302 http2 so_keepalive=on proxy_protocol;"
    local nginxBin="nginx"
    if [[ -f "/www/server/nginx/sbin/nginx" ]]; then
        nginxBin="/www/server/nginx/sbin/nginx"
    fi
    nginxVersion=$("${nginxBin}" -v 2>&1)

    if echo "${nginxVersion}" | grep -q "1.25" && [[ $(echo "${nginxVersion}" | awk -F "[.]" '{print $3}') -gt 0 ]] || [[ $(echo "${nginxVersion}" | awk -F "[.]" '{print $2}') -gt 25 ]]; then
        nginxH2Conf="listen 127.0.0.1:31302 so_keepalive=on proxy_protocol;http2 on;"
    fi

    local fallbackLocationConfig=
    if [[ -n "${btDomain}" ]]; then
        fallbackLocationConfig=$(printf '%s\n' \
            '        proxy_pass https://127.0.0.1:443;' \
            '        proxy_http_version 1.1;' \
            "        proxy_set_header Host ${btDomain};" \
            '        proxy_set_header X-Real-IP $remote_addr;' \
            '        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;' \
            '        proxy_set_header X-Forwarded-Proto https;' \
            '        proxy_ssl_server_name on;' \
            "        proxy_ssl_name ${btDomain};" \
            '        proxy_ssl_verify off;')
        echoContent green " ---> Vision普通HTTPS回落将反向代理到面板站点: https://${btDomain}/"
    fi

    local xhttpLocationConfig=
    if xhttpTlsEnabled; then
        xhttpLocationConfig=$(xhttpNginxLocation "$(xhttpPublicPath)" "	")
    fi

    if ! cat <<EOF >"${nginxConfTmp}"; then
    server {
    		listen 127.0.0.1:31300;
    		server_name _;
    		return 403;
    }
server {
	${nginxH2Conf}

	set_real_ip_from 127.0.0.1;
    real_ip_header proxy_protocol;

	server_name ${domain};
	root ${nginxStaticPath};

${xhttpLocationConfig}
	location / {
	${fallbackLocationConfig}
	}
}
server {
	listen 127.0.0.1:31300 proxy_protocol;
	server_name ${domain};

	set_real_ip_from 127.0.0.1;
	real_ip_header proxy_protocol;

	root ${nginxStaticPath};
${xhttpLocationConfig}
	location / {
	${fallbackLocationConfig}
	}
}
EOF
        rm -f "${nginxConfTmp}"
        echoContent red " ---> 写入Nginx配置失败: ${nginxConfFile}"
        return 1
    fi

    if ! mv "${nginxConfTmp}" "${nginxConfFile}"; then
        rm -f "${nginxConfTmp}"
        echoContent red " ---> 保存Nginx配置失败: ${nginxConfFile}"
        return 1
    fi

    echoContent green " ---> Nginx配置已写入: ${nginxConfFile}"
}
# Check the IP

# ==================== XHTTP over nginx ====================

# True when VLESS + XHTTP + TLS is being installed, or is installed and the
# current operation does not select protocols.
xhttpTlsEnabled() {
    if [[ -n "${selectCustomInstallType}" ]]; then
        hasProtocol "${selectCustomInstallType}" 14
    else
        hasProtocol "${currentInstallProtocolType}" 14
    fi
}

xhttpPublicPath() {
    echo "/${customPath:-${currentPath}}xhttp"
}

# nginx location that hands the XHTTP path to the local XHTTP inbound.
# grpc_pass speaks h2c to Xray and also serves HTTP/1.1 clients (CDNs often
# reach the origin over HTTP/1.1). "^~" keeps regex locations in panel site
# configs from taking these requests.
# Usage: xhttpNginxLocation <path> [indent]
xhttpNginxLocation() {
    local path=$1 indent=${2:-    }
    printf '%s\n' \
        "${indent}location ^~ ${path}/ {" \
        "${indent}    client_max_body_size 0;" \
        "${indent}    client_body_timeout 5m;" \
        "${indent}    grpc_read_timeout 315;" \
        "${indent}    grpc_send_timeout 5m;" \
        "${indent}    grpc_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;" \
        "${indent}    grpc_set_header ${xhttpTrustedHeader} 1;" \
        "${indent}    grpc_pass grpc://127.0.0.1:${xhttpInboundPort};" \
        "${indent}}"
}

# Server-level guard that skips the server block's remaining rewrite
# directives for the XHTTP path. Panel redirects ("send the whole site to
# another domain") and rewrite presets are server-level if/return/rewrite;
# they run before a location is chosen, so without the guard the location is
# never reached and every XHTTP request gets the redirect.
# Usage: xhttpNginxRedirectGuard <path> [indent]
xhttpNginxRedirectGuard() {
    local path=$1 indent=${2:-    } pattern
    pattern=$(sed 's/[].*+?^$()|{}[]/\\&/g' <<<"${path}")
    printf '%s\n' \
        "${indent}if (\$uri ~ \"^${pattern}/\") {" \
        "${indent}    break;" \
        "${indent}}"
}

# aaPanel/BT vhost directory (overridable for tests).
panelVhostRoot=/www/server/panel/vhost
xhttpPanelMarkerBegin="# >>> xray-agent XHTTP (managed by xray-agent, do not edit) >>>"
xhttpPanelMarkerEnd="# <<< xray-agent XHTTP <<<"
xhttpStateFile=/opt/xray-agent/xhttp_public_port
# Sorts before the panel's "<md5>_<domain>.conf" redirect files, so the guard
# runs before their rules.
xhttpPanelRedirectFile=0-xray-agent-xhttp.conf

# The marked block added to a panel site: the guard, then the location.
xhttpPanelBlock() {
    echo "${xhttpPanelMarkerBegin}"
    xhttpNginxRedirectGuard "$(xhttpPublicPath)"
    xhttpNginxLocation "$(xhttpPublicPath)"
    echo "${xhttpPanelMarkerEnd}"
}

# Every file that may hold our block for the panel site, as "<file> own"
# (the whole file is ours) or "<file> block" (a marked block inside a
# user-editable file). Earlier versions used the extension or rewrite file.
panelXhttpFiles() {
    echo "${panelVhostRoot}/nginx/redirect/${btDomain}/${xhttpPanelRedirectFile} own"
    echo "${panelVhostRoot}/nginx/extension/${btDomain}/xray-agent-xhttp.conf own"
    echo "${panelVhostRoot}/rewrite/${btDomain}.conf block"
}

# Find a file that the panel site config already includes inside its server
# block, so our block survives the panel rewriting the site config. Prefers
# the redirect directory: it is included before the URL rewrite file, so the
# guard runs before the panel's redirects and the user's rewrite rules.
# Prints a line of panelXhttpFiles.
findPanelXhttpTarget() {
    local siteConf="${panelVhostRoot}/nginx/${btDomain}.conf"
    if [[ -f "${siteConf}" ]]; then
        if grep -qF "${panelVhostRoot}/nginx/redirect/${btDomain}/*.conf" "${siteConf}"; then
            echo "${panelVhostRoot}/nginx/redirect/${btDomain}/${xhttpPanelRedirectFile} own"
            return 0
        fi
        if grep -qF "${panelVhostRoot}/nginx/extension/${btDomain}/*.conf" "${siteConf}"; then
            echo "${panelVhostRoot}/nginx/extension/${btDomain}/xray-agent-xhttp.conf own"
            return 0
        fi
        if grep -qF "${panelVhostRoot}/rewrite/${btDomain}.conf" "${siteConf}"; then
            echo "${panelVhostRoot}/rewrite/${btDomain}.conf block"
            return 0
        fi
    fi
    return 1
}

panelNginxTest() {
    if [[ -x /www/server/nginx/sbin/nginx ]]; then
        /www/server/nginx/sbin/nginx -t -c /www/server/nginx/conf/nginx.conf
    else
        nginx -t
    fi
}

panelNginxReload() {
    if [[ -x /www/server/nginx/sbin/nginx ]]; then
        /www/server/nginx/sbin/nginx -s reload -c /www/server/nginx/conf/nginx.conf
    elif command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet nginx; then
        systemctl reload nginx
    else
        nginx -s reload
    fi
}

# Print a file without our marked XHTTP block.
stripXhttpPanelBlock() {
    awk -v begin="${xhttpPanelMarkerBegin}" -v end="${xhttpPanelMarkerEnd}" '
        $0 == begin {skip = 1; next}
        $0 == end {skip = 0; next}
        !skip {print}
    ' "$1"
}

# Add or remove the XHTTP block in the panel site that serves 443, then test
# and reload nginx. The block is first removed from every file that may hold
# it (an older install may have used another one); a failed test restores
# all of them.
# Usage: syncPanelXhttpLocation install|remove
syncPanelXhttpLocation() {
    local action=$1 target file mode backupDir index=0 output
    [[ -n "${btDomain}" ]] || return 0
    if ! target=$(findPanelXhttpTarget); then
        if [[ "${action}" == "install" ]]; then
            echoContent yellow " ---> 未找到 ${btDomain} 站点配置中可安全写入的位置（面板会覆盖直接修改）"
            echoContent yellow " ---> 请在面板中把以下配置加入 ${btDomain} 的 443 server 块（放在重定向和伪静态规则之前）后重载 Nginx:"
            xhttpPanelBlock
        fi
        return 0
    fi
    backupDir=$(mktemp -d) || return 1

    while read -r file mode; do
        ((++index))
        [[ -f "${file}" ]] || continue
        cp -p "${file}" "${backupDir}/${index}"
        if [[ "${mode}" == "own" ]]; then
            rm -f "${file}"
        else
            stripXhttpPanelBlock "${backupDir}/${index}" >"${file}"
        fi
    done < <(panelXhttpFiles)

    if [[ "${action}" == "install" ]]; then
        # Our block goes first: in a shared rewrite file the guard has to run
        # before the user's own server-level rewrites.
        file=${target% *}
        mkdir -p "$(dirname "${file}")"
        : >"${backupDir}/body"
        [[ -f "${file}" ]] && cat "${file}" >"${backupDir}/body"
        {
            xhttpPanelBlock
            cat "${backupDir}/body"
        } >"${file}"
    fi

    if ! output=$(panelNginxTest 2>&1); then
        index=0
        while read -r file mode; do
            ((++index))
            if [[ -f "${backupDir}/${index}" ]]; then
                cp -p "${backupDir}/${index}" "${file}"
            else
                rm -f "${file}"
            fi
        done < <(panelXhttpFiles)
        rm -rf "${backupDir}"
        echoContent red " ---> 面板 Nginx 配置测试失败，已恢复 ${btDomain} 的站点配置"
        echoContent yellow "$(echo "${output}" | tail -3)"
        return 1
    fi
    rm -rf "${backupDir}"
    panelNginxReload >/dev/null 2>&1
    if [[ "${action}" == "install" ]]; then
        echoContent green " ---> XHTTP 已接入面板站点 https://${btDomain}$(xhttpPublicPath)/ (${file})"
    fi
}

# Remove our XHTTP location from every panel site (used by uninstall).
removeAllPanelXhttpLocations() {
    local file changed=false
    for file in "${panelVhostRoot}"/nginx/redirect/*/"${xhttpPanelRedirectFile}" \
        "${panelVhostRoot}"/nginx/extension/*/xray-agent-xhttp.conf; do
        [[ -f "${file}" ]] && rm -f "${file}" && changed=true
    done
    for file in "${panelVhostRoot}"/rewrite/*.conf; do
        if [[ -f "${file}" ]] && grep -qF "${xhttpPanelMarkerBegin}" "${file}"; then
            stripXhttpPanelBlock "${file}" >"${file}.tmp.$$" && mv "${file}.tmp.$$" "${file}" && changed=true
        fi
    done
    if [[ "${changed}" == "true" ]] && panelNginxTest >/dev/null 2>&1; then
        panelNginxReload >/dev/null 2>&1
    fi
    rm -f "${xhttpStateFile}"
}

# Request the XHTTP path from the panel site the way a client does and warn
# when it does not reach Xray (which answers a bare GET with 400): a redirect
# or the site's own 404 means a rule the guard cannot precede still takes the
# path, e.g. a return/rewrite written directly into the site config.
checkPanelXhttpReachable() {
    local result code
    [[ -n "${btDomain}" ]] || return 0
    command -v curl >/dev/null 2>&1 || return 0
    result=$(curl -sk --max-time 5 --resolve "${btDomain}:443:127.0.0.1" -o /dev/null \
        -w '%{http_code} %{redirect_url}' "https://${btDomain}$(xhttpPublicPath)/") || return 0
    code=${result%% *}
    case ${code} in
        3??) echoContent red " ---> XHTTP 路径被站点 ${btDomain} 重定向 (${code} -> ${result#* })，客户端将无法连接" ;;
        404) echoContent red " ---> XHTTP 路径未到达 Xray（站点 ${btDomain} 返回 404），客户端将无法连接" ;;
        *) return 0 ;;
    esac
    echoContent yellow " ---> 请检查站点配置中的 if/return/rewrite 规则，并在它们之前加入:"
    xhttpNginxRedirectGuard "$(xhttpPublicPath)"
}
