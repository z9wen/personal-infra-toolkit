# Nginx environment detection
checkNginxEnvironment() {
    local nginxBin="nginx"
    # Prefer the nginx bundled with the panel
    if [[ -f "/www/server/nginx/sbin/nginx" ]]; then
        nginxBin="/www/server/nginx/sbin/nginx"
    fi

    if command -v nginx &>/dev/null || [[ -f "/www/server/nginx/sbin/nginx" ]]; then
        echoContent skyBlue "\n========== Nginx 环境检测 ==========\n"

        # Nginx version
        local nginxVer
        nginxVer=$(${nginxBin} -v 2>&1 | awk -F'/' '{print $2}')
        echoContent green "Nginx 版本: ${nginxVer}"

        # Number of config files - uses nginxConfigPath
        local confCount
        confCount=$(find "${nginxConfigPath}" /etc/nginx/sites-enabled -name "*.conf" 2>/dev/null | wc -l)
        echoContent yellow "现有配置文件: ${confCount} 个"

        # Listening ports
        local ports
        ports=$(netstat -tlnp 2>/dev/null | grep nginx | awk '{print $4}' | awk -F':' '{print $NF}' | sort -u | tr '\n' ',' | sed 's/,$//')
        if [[ -n "${ports}" ]]; then
            echoContent yellow "监听端口: ${ports}"
        fi

        # Configured domains - uses nginxConfigPath
        local domains
        domains=$(grep -rh "server_name" "${nginxConfigPath}" /etc/nginx/sites-enabled 2>/dev/null | grep -v "server_name _" | awk '{for(i=2;i<=NF;i++)print $i}' | sed 's/;//g' | sort -u | head -5)
        if [[ -n "${domains}" ]]; then
            echoContent yellow "已配置域名:"
            echo "${domains}" | while read -r d; do
                echoContent skyBlue "  - ${d}"
            done
        fi

        echoContent skyBlue "\n====================================\n"
    fi
}

# Early panel path detection (no user input; only sets nginxConfigPath)
detectPanelNginxPath() {
    # The aaPanel/BT Panel process may not be running or may have a different name; Nginx and the vhost directory
    # are the reliable indicators of the config location.
    if [[ -x "/www/server/nginx/sbin/nginx" ]] && [[ -d "/www/server/panel/vhost/nginx" ]]; then
        nginxConfigPath="/www/server/panel/vhost/nginx/"
    elif [[ -d "/opt/1panel/apps/openresty/openresty/conf/conf.d" ]]; then
        nginxConfigPath="/opt/1panel/apps/openresty/openresty/conf/conf.d/"
    fi
}

# Run the nginx that serves this host: aaPanel ships its own binary and
# config outside PATH.
hostNginx() {
    if [[ -x /www/server/nginx/sbin/nginx ]]; then
        /www/server/nginx/sbin/nginx -c /www/server/nginx/conf/nginx.conf "$@"
    else
        nginx "$@"
    fi
}

# TCP ports the host nginx config listens on, one per line. Read from
# "nginx -T", so it also works while the install has nginx stopped. QUIC
# (UDP) and unix sockets are skipped, and so is a port-check config left
# behind by an interrupted run.
nginxListenPorts() {
    hostNginx -T 2>/dev/null | awk '
        /^# configuration file / {skip = ($4 ~ /checkPortOpen\.conf:$/); next}
        skip {next}
        {
            sub(/#.*/, "")
            gsub(/;/, " ; ")
            for (i = 1; i <= NF; i++) {
                if ($i != "listen") continue
                spec = $(i + 1)
                quic = 0
                for (j = i + 2; j <= NF && $j != ";"; j++) if ($j == "quic") quic = 1
                if (quic || spec ~ /^unix:/) continue
                if (spec ~ /^[0-9]+$/) port = spec
                else if (spec ~ /:[0-9]+$/) {port = spec; sub(/.*:/, "", port)}
                else port = 80
                print port
            }
        }' | sort -un
}

# True when a site of the host nginx already listens on TCP port $1. Our own
# config only listens on loopback ports, so this means another site.
nginxListensOnPort() {
    nginxListenPorts | grep -qx "$1"
}

# Fail when the host nginx does not load a config file we wrote, e.g. a
# custom nginx.conf without an include for the conf.d directory. A config
# that does not test cleanly is left to handleNginx to report.
checkNginxLoadsConf() {
    local file=$1 dump
    dump=$(hostNginx -T 2>/dev/null) || return 0
    grep -qxF "# configuration file ${file}:" <<<"${dump}" && return 0
    echoContent red " ---> Nginx 没有加载 ${file}，回落和 XHTTP 将无法工作"
    echoContent yellow " ---> 请在 nginx.conf 的 http 块中加入 include ${nginxConfigPath}*.conf; 后重新安装"
    return 1
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
    # Native nginx only; the panels include their vhost directory themselves.
    if [[ "${nginxConfigPath}" == /etc/nginx/* ]]; then
        checkNginxLoadsConf "${nginxConfFile}" || return 1
    fi
}

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

# Modify the http_port_t port
updateSELinuxHTTPPortT() {

    $(find /usr/bin /usr/sbin | grep -w journalctl) -xe >/opt/xray-agent/nginx_error.log 2>&1

    if find /usr/bin /usr/sbin | grep -q -w semanage && find /usr/bin /usr/sbin | grep -q -w getenforce && grep -E "31300|31302" </opt/xray-agent/nginx_error.log | grep -q "Permission denied"; then
        echoContent red " ---> 检查SELinux端口是否开放"
        if ! $(find /usr/bin /usr/sbin | grep -w semanage) port -l | grep http_port | grep -q 31300; then
            $(find /usr/bin /usr/sbin | grep -w semanage) port -a -t http_port_t -p tcp 31300
            echoContent green " ---> http_port_t 31300 端口开放成功"
        fi

        if ! $(find /usr/bin /usr/sbin | grep -w semanage) port -l | grep http_port | grep -q 31302; then
            $(find /usr/bin /usr/sbin | grep -w semanage) port -a -t http_port_t -p tcp 31302
            echoContent green " ---> http_port_t 31302 端口开放成功"
        fi
        handleNginx start

    else
        exit 0
    fi
}

# True when nginx runs on this host. nginx inside a container (another PID
# namespace) also shows up in pgrep here and must not count, or a Docker
# nginx would keep the host nginx from being started or seem to never stop.
hostNginxRunning() {
    local pid namespace ownNamespace
    ownNamespace=$(readlink /proc/self/ns/pid 2>/dev/null)
    for pid in $(pgrep -x nginx); do
        namespace=$(readlink "/proc/${pid}/ns/pid" 2>/dev/null)
        [[ -z "${namespace}" || "${namespace}" == "${ownNamespace}" ]] && return 0
    done
    return 1
}

# Start nginx again when this run stopped it and is about to exit without
# having started it (an install that stopped half-way, uninstall), so other
# sites on a shared nginx are not left down.
restoreStoppedNginx() {
    [[ "${nginxStoppedByAgent}" == "true" ]] || return 0
    handleNginx start
}

# Manage Nginx
handleNginx() {
    # Detect how Nginx is managed
    local nginxCtl=""
    local errorLog=/opt/xray-agent/nginx_error.log
    # Uninstall removes /opt/xray-agent before nginx is started again
    [[ -d /opt/xray-agent ]] || errorLog=/dev/null

    # Check for BT Panel/1Panel first
    if [[ -n "${btDomain}" ]] || [[ -n $(pgrep -f "BT-Panel") ]] || [[ -f "/etc/init.d/nginx" ]]; then
        if [[ -f "/etc/init.d/nginx" ]]; then
            nginxCtl="/etc/init.d/nginx"
        elif [[ -f "/www/server/nginx/sbin/nginx" ]]; then
            nginxCtl="/www/server/nginx/sbin/nginx"
        fi
    fi

    # If not BT Panel, check systemd
    if [[ -z "${nginxCtl}" ]] && systemctl list-unit-files | grep -q "nginx.service"; then
        nginxCtl="systemctl"
    fi

    # Start Nginx. Installs that need no certificate leave nginx alone,
    # unless this run stopped it.
    if { [[ -z "${selectCustomInstallType}" ]] || selectionNeedsTLS "${selectCustomInstallType}" \
        || [[ "${nginxStoppedByAgent}" == "true" ]]; } \
        && ! hostNginxRunning && [[ "$1" == "start" ]]; then
        # Validate the config syntax
        local nginxTestResult=
        if [[ "${nginxCtl}" == "/www/server/nginx/sbin/nginx" ]]; then
            nginxTestResult=$(/www/server/nginx/sbin/nginx -t -c /www/server/nginx/conf/nginx.conf 2>&1)
        else
            nginxTestResult=$(nginx -t 2>&1)
        fi
        if ! echo "${nginxTestResult}" | grep -q "successful"; then
            echoContent red " ---> Nginx配置验证失败，请检查配置"
            echo "${nginxTestResult}" | tee "${errorLog}"
            return 1
        fi
        if [[ "${nginxCtl}" == "systemctl" ]]; then
            systemctl start nginx 2>"${errorLog}"
        elif [[ "${nginxCtl}" == "/etc/init.d/nginx" ]]; then
            /etc/init.d/nginx start 2>"${errorLog}"
        elif [[ "${nginxCtl}" == "/www/server/nginx/sbin/nginx" ]]; then
            /www/server/nginx/sbin/nginx -c /www/server/nginx/conf/nginx.conf 2>"${errorLog}"
        else
            nginx 2>"${errorLog}"
        fi

        sleep 0.5

        if ! hostNginxRunning; then
            echoContent red " ---> Nginx启动失败"
            echoContent red " ---> 请将下方日志反馈给开发者"
            cat "${errorLog}" 2>/dev/null
            if grep -q "journalctl -xe" <"${errorLog}"; then
                updateSELinuxHTTPPortT
            fi
        else
            nginxStoppedByAgent=
            echoContent green " ---> Nginx启动成功"
        fi

    # Stop Nginx
    elif hostNginxRunning && [[ "$1" == "stop" ]]; then
        if [[ "${nginxCtl}" == "systemctl" ]]; then
            systemctl stop nginx 2>/dev/null
        elif [[ "${nginxCtl}" == "/etc/init.d/nginx" ]]; then
            /etc/init.d/nginx stop 2>/dev/null
        elif [[ "${nginxCtl}" == "/www/server/nginx/sbin/nginx" ]]; then
            /www/server/nginx/sbin/nginx -s stop 2>/dev/null
        else
            # Started by hand, without a service manager
            nginx -s stop 2>/dev/null
        fi

        local nginxStopWait=0
        while hostNginxRunning && ((nginxStopWait < 10)); do
            sleep 1
            ((nginxStopWait++)) || true
        done

        if ! hostNginxRunning; then
            nginxStoppedByAgent=true
            echoContent green " ---> Nginx关闭成功"
        elif [[ -z ${btDomain} ]]; then
            echoContent red " ---> Nginx未能正常停止，已保留进程以免强制中断现有网站"
            return 1
        else
            echoContent yellow " ---> Nginx关闭完成（宝塔/1Panel管理）"
        fi
    fi
}
