# 检查是否安装宝塔/aaPanel。面板进程名在不同版本中并不固定，
# 因此同时依据 Nginx、vhost 目录和面板进程判断。
isBTPanelEnvironment() {
    [[ -d "/www/server/panel/vhost/nginx" ]] || return 1
    [[ -x "/www/server/nginx/sbin/nginx" ]] || pgrep -f "BT-Panel|aaPanel" >/dev/null 2>&1
}

# 仅保留具有合法域名文件名并已配置可用 TLS 证书的面板站点。
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
        # 读取域名
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

            # 如果用户选择不使用上次配置或currentHost为空，则提示用户选择
            if [[ "${forceSelectDomain}" == "true" ]] || [[ -z "${currentHost}" ]]; then
                echoContent skyBlue "\n读取宝塔/aaPanel配置\n"

                local displayIndex
                for ((displayIndex = 0; displayIndex < btDomainCount; displayIndex++)); do
                    local printIndex=$((displayIndex + 1))
                    echo "${printIndex}:${btDomains[displayIndex]}"
                done

                read -r -p "请输入编号选择:" selectBTDomain
                # 选择完成后清除标志
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
        # 读取域名
        if [[ -d '/opt/1panel/apps/openresty/openresty/www/sites/' && -n $(find /opt/1panel/apps/openresty/openresty/www/sites/*/ssl/fullchain.pem) ]]; then
            # 如果用户选择不使用上次配置或currentHost为空，则提示用户选择
            if [[ "${forceSelectDomain}" == "true" ]] || [[ -z "${currentHost}" ]]; then
                echoContent skyBlue "\n读取1Panel配置\n"

                find /opt/1panel/apps/openresty/openresty/www/sites/*/ssl/fullchain.pem | awk -F "[/]" '{print $9}' | awk '{print NR""":"$0}'

                read -r -p "请输入编号选择:" selectBTDomain
                # 选择完成后清除标志
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
checkHestiaPanel() {
    if [[ -d "/usr/local/hestia" ]]; then
        local -a hestiaDomains=()
        local -a hestiaUsers=()
        while IFS= read -r certDir; do
            if [[ -z "${certDir}" ]]; then
                continue
            fi
            local hUser hDomain
            hUser=$(echo "${certDir}" | cut -d'/' -f3)
            hDomain=$(echo "${certDir}" | cut -d'/' -f6)
            if [[ -n "${hUser}" && -n "${hDomain}" ]]; then
                hestiaUsers+=("${hUser}")
                hestiaDomains+=("${hDomain}")
            fi
        done < <(find /home -path "*/conf/web/*/ssl" -type d 2>/dev/null | sort)

        local domainCount=${#hestiaDomains[@]}
        if ((domainCount == 0)); then
            return
        fi

        local selectHestiaDomain=
        # 如果用户选择不使用上次配置或currentHost为空，则提示用户选择
        if [[ "${forceSelectDomain}" == "true" ]] || [[ -z "${currentHost}" ]]; then
            echoContent skyBlue "\n读取HestiaCP配置\n"
            local displayIndex
            for ((displayIndex = 0; displayIndex < domainCount; displayIndex++)); do
                local printIndex=$((displayIndex + 1))
                echo "${printIndex}:${hestiaDomains[displayIndex]} (user:${hestiaUsers[displayIndex]})"
            done
            read -r -p "请输入编号选择:" selectHestiaDomain
            # 选择完成后清除标志
            forceSelectDomain=false
        else
            for ((displayIndex = 0; displayIndex < domainCount; displayIndex++)); do
                if [[ "${hestiaDomains[displayIndex]}" == "${currentHost}" ]]; then
                    selectHestiaDomain=$((displayIndex + 1))
                    break
                fi
            done
        fi

        if [[ -n "${selectHestiaDomain}" && "${selectHestiaDomain}" =~ ^[0-9]+$ ]]; then
            local selectedIndex=$((selectHestiaDomain - 1))
            if ((selectedIndex < 0 || selectedIndex >= domainCount)); then
                echoContent red " ---> 选择错误，请重新选择"
                checkHestiaPanel
                return
            fi

            local hestiaDomain=${hestiaDomains[selectedIndex]}
            local hestiaUser=${hestiaUsers[selectedIndex]}
            local certDir="/home/${hestiaUser}/conf/web/${hestiaDomain}/ssl"
            local certFile=
            local keyFile=

            if [[ -f "${certDir}/${hestiaDomain}.crt" ]]; then
                certFile="${certDir}/${hestiaDomain}.crt"
            elif [[ -f "${certDir}/fullchain.pem" ]]; then
                certFile="${certDir}/fullchain.pem"
            elif [[ -f "${certDir}/cert.pem" ]]; then
                certFile="${certDir}/cert.pem"
            fi

            if [[ -f "${certDir}/${hestiaDomain}.key" ]]; then
                keyFile="${certDir}/${hestiaDomain}.key"
            elif [[ -f "${certDir}/privkey.pem" ]]; then
                keyFile="${certDir}/privkey.pem"
            elif [[ -f "${certDir}/key.pem" ]]; then
                keyFile="${certDir}/key.pem"
            fi

            if [[ -z "${certFile}" || -z "${keyFile}" ]]; then
                echoContent red " ---> 未找到 HestiaCP 证书文件，请先在面板中申请"
                return
            fi

            btDomain=${hestiaDomain}
            domain=${hestiaDomain}

            mkdir -p /opt/xray-agent/tls
            if [[ ! -f "/opt/xray-agent/tls/${hestiaDomain}.crt" && ! -f "/opt/xray-agent/tls/${hestiaDomain}.key" ]]; then
                ln -s "${certFile}" "/opt/xray-agent/tls/${hestiaDomain}.crt"
                ln -s "${keyFile}" "/opt/xray-agent/tls/${hestiaDomain}.key"
            fi

            nginxStaticPath="/home/${hestiaUser}/web/${hestiaDomain}/public_html/"
            mkdir -p "${nginxStaticPath}"
        else
            echoContent red " ---> 选择错误，请重新选择"
            checkHestiaPanel
            return
        fi
    fi
}
