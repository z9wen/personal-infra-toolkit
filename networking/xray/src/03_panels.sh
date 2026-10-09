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
check1Panel() {
    if [[ -n $(pgrep -f "1panel") ]]; then
        # Read the domain
        if [[ -d '/opt/1panel/apps/openresty/openresty/www/sites/' && -n $(find /opt/1panel/apps/openresty/openresty/www/sites/*/ssl/fullchain.pem) ]]; then
            # If the user declines the previous config or currentHost is empty, prompt the user to choose
            if [[ "${forceSelectDomain}" == "true" ]] || [[ -z "${currentHost}" ]]; then
                echoContent skyBlue "\n读取1Panel配置\n"

                find /opt/1panel/apps/openresty/openresty/www/sites/*/ssl/fullchain.pem | awk -F "[/]" '{print $9}' | awk '{print NR""":"$0}'

                read -r -p "请输入编号选择:" selectBTDomain
                # Clear the flag once the selection is done
                forceSelectDomain=false
            else
                selectBTDomain=$(find /opt/1panel/apps/openresty/openresty/www/sites/*/ssl/fullchain.pem | awk -F "[/]" '{print $9}' | awk '{print NR""":"$0}' | grep "${currentHost}" | cut -d ":" -f 1)
            fi

            if [[ -n "${selectBTDomain}" ]]; then
                btDomain=$(find /opt/1panel/apps/openresty/openresty/www/sites/*/ssl/fullchain.pem | awk -F "[/]" '{print $9}' | awk '{print NR""":"$0}' | grep "${selectBTDomain}:" | cut -d ":" -f 2)

                if [[ -z "${btDomain}" ]]; then
                    echoContent red " ---> 选择错误，请重新选择"
                    check1Panel
                else
                    domain=${btDomain}
                    if [[ ! -f "/opt/xray-agent/tls/${btDomain}.crt" && ! -f "/opt/xray-agent/tls/${btDomain}.key" ]]; then
                        ln -s "/opt/1panel/apps/openresty/openresty/www/sites/${btDomain}/ssl/fullchain.pem" "/opt/xray-agent/tls/${btDomain}.crt"
                        ln -s "/opt/1panel/apps/openresty/openresty/www/sites/${btDomain}/ssl/privkey.pem" "/opt/xray-agent/tls/${btDomain}.key"
                    fi

                    nginxStaticPath="/opt/1panel/apps/openresty/openresty/www/sites/${btDomain}/index/"
                fi
            else
                echoContent red " ---> 选择错误，请重新选择"
                check1Panel
            fi
        fi
    fi
}
