# Check whether BT Panel/aaPanel is installed. The panel process name is not stable across versions,
# so decide based on Nginx, the vhost directory and the panel process together.
isBTPanelEnvironment() {
    [[ -d "/www/server/panel/vhost/nginx" ]] || return 1
    [[ -x "/www/server/nginx/sbin/nginx" ]] || pgrep -f "BT-Panel|aaPanel" >/dev/null 2>&1
}

# Keep only panel sites that have a valid domain file name and a usable TLS certificate configured.
isBTPanelSiteConfig() {
    local confFile=$1
    local siteDomain=
    local certFile=
    local keyFile=

    siteDomain=$(basename "${confFile}" .conf)
    [[ "${siteDomain}" != 0.* ]] || return 1
    [[ "${siteDomain}" =~ ^([A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?\.)+[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] || return 1

    certFile=$(awk '$1 == "ssl_certificate" {gsub(/[;\"]/, "", $2); print $2; exit}' "${confFile}" 2>/dev/null)
    keyFile=$(awk '$1 == "ssl_certificate_key" {gsub(/[;\"]/, "", $2); print $2; exit}' "${confFile}" 2>/dev/null)
    certFile=${certFile:-/www/server/panel/vhost/cert/${siteDomain}/fullchain.pem}
    keyFile=${keyFile:-/www/server/panel/vhost/cert/${siteDomain}/privkey.pem}

    [[ -f "${certFile}" && -f "${keyFile}" ]]
}

checkBTPanel() {
    if isBTPanelEnvironment; then
        # Read the domain
        if [[ -d '/www/server/panel/vhost/nginx/' ]]; then
            local -a btDomains=()
            local panelConfFile=
            while IFS= read -r panelConfFile; do
                if isBTPanelSiteConfig "${panelConfFile}"; then
                    btDomains+=("$(basename "${panelConfFile}" .conf)")
                fi
            done < <(find /www/server/panel/vhost/nginx -maxdepth 1 -type f -name "*.conf" ! -name "xray-agent.conf" -print 2>/dev/null | sort)
            local btDomainCount=${#btDomains[@]}
            if ((btDomainCount == 0)); then
                echoContent yellow " ---> 未发现配置了有效TLS证书的宝塔/aaPanel网站"
                return
            fi
            local selectBTDomain=

            # If the user declines the previous config or currentHost is empty, prompt the user to choose
            if [[ "${forceSelectDomain}" == "true" ]] || [[ -z "${currentHost}" ]]; then
                echoContent skyBlue "\n读取宝塔/aaPanel配置\n"

                local displayIndex
                for ((displayIndex = 0; displayIndex < btDomainCount; displayIndex++)); do
                    local printIndex=$((displayIndex + 1))
                    echo "${printIndex}:${btDomains[displayIndex]}"
                done

                read -r -p "请输入编号选择:" selectBTDomain
                # Clear the flag once the selection is done
                forceSelectDomain=false
            else
                local displayIndex
                for ((displayIndex = 0; displayIndex < btDomainCount; displayIndex++)); do
                    if [[ "${btDomains[displayIndex]}" == "${currentHost}" ]]; then
                        selectBTDomain=$((displayIndex + 1))
                        break
                    fi
                done
                if [[ -z "${selectBTDomain}" ]]; then
                    echoContent yellow " ---> 上次域名 ${currentHost} 不在面板站点中，请重新选择"
                    for ((displayIndex = 0; displayIndex < btDomainCount; displayIndex++)); do
                        local printIndex=$((displayIndex + 1))
                        echo "${printIndex}:${btDomains[displayIndex]}"
                    done
                    read -r -p "请输入编号选择:" selectBTDomain
                fi
            fi

            if [[ -n "${selectBTDomain}" && "${selectBTDomain}" =~ ^[0-9]+$ ]]; then
                local selectedIndex=$((selectBTDomain - 1))
                if ((selectedIndex < 0 || selectedIndex >= btDomainCount)); then
                    echoContent red " ---> 选择错误，请重新选择"
                    checkBTPanel
                    return
                else
                    local selectedBTDomain=${btDomains[selectedIndex]}
                    local btConfFile="/www/server/panel/vhost/nginx/${selectedBTDomain}.conf"
                    local certFile=
                    local keyFile=
                    certFile=$(awk '$1 == "ssl_certificate" {gsub(/[;\"]/, "", $2); print $2; exit}' "${btConfFile}" 2>/dev/null)
                    keyFile=$(awk '$1 == "ssl_certificate_key" {gsub(/[;\"]/, "", $2); print $2; exit}' "${btConfFile}" 2>/dev/null)

                    if [[ -z "${certFile}" ]]; then
                        certFile="/www/server/panel/vhost/cert/${selectedBTDomain}/fullchain.pem"
                    fi
                    if [[ -z "${keyFile}" ]]; then
                        keyFile="/www/server/panel/vhost/cert/${selectedBTDomain}/privkey.pem"
                    fi

                    if [[ ! -f "${certFile}" || ! -f "${keyFile}" ]]; then
                        echoContent yellow " ---> 未找到 ${selectedBTDomain} 的面板证书，将使用普通TLS证书流程"
                        return
                    fi

                    btDomain=${selectedBTDomain}
                    domain=${btDomain}

                    mkdir -p /opt/xray-agent/tls
                    ln -sfn "${certFile}" "/opt/xray-agent/tls/${btDomain}.crt"
                    ln -sfn "${keyFile}" "/opt/xray-agent/tls/${btDomain}.key"

                    nginxStaticPath="/www/wwwroot/${btDomain}/html/"

                    mkdir -p "/www/wwwroot/${btDomain}/html/"

                    if [[ -f "/www/wwwroot/${btDomain}/.user.ini" ]]; then
                        chattr -i "/www/wwwroot/${btDomain}/.user.ini"
                    fi
                    nginxConfigPath="/www/server/panel/vhost/nginx/"
                fi
            else
                echoContent red " ---> 选择错误，请重新选择"
                checkBTPanel
                return
            fi
        fi
    fi
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
    hostNginx -t
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
