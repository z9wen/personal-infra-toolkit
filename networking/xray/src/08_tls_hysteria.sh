
checkIP() {
    echoContent skyBlue "\n ---> 检查域名ip中"
    local localIP=$1

    if [[ -z ${localIP} ]] || ! echo "${localIP}" | sed '1{s/[^(]*(//;s/).*//;q}' | grep -q '\.' && ! echo "${localIP}" | sed '1{s/[^(]*(//;s/).*//;q}' | grep -q ':'; then
        echoContent red "\n ---> 未检测到当前域名的ip"
        echoContent skyBlue " ---> 请依次进行下列检查"
        echoContent yellow " --->  1.检查域名是否书写正确"
        echoContent yellow " --->  2.检查域名dns解析是否正确"
        echoContent yellow " --->  3.如解析正确，请等待dns生效，预计三分钟内生效"
        echoContent yellow " --->  4.如报Nginx启动问题，请手动启动nginx查看错误，如自己无法处理请提issues"
        echo
        echoContent skyBlue " ---> 如以上设置都正确，请重新安装纯净系统后再次尝试"

        if [[ -n ${localIP} ]]; then
            echoContent yellow " ---> 检测返回值异常，建议手动卸载nginx后重新执行脚本"
            echoContent red " ---> 异常结果：${localIP}"
        fi
        exit 0
    else
        if echo "${localIP}" | awk -F "[,]" '{print $2}' | grep -q "." || echo "${localIP}" | awk -F "[,]" '{print $2}' | grep -q ":"; then
            echoContent red "\n ---> 检测到多个ip，请确认是否关闭cloudflare的云朵"
            echoContent yellow " ---> 关闭云朵后等待三分钟后重试"
            echoContent yellow " ---> 检测到的ip如下:[${localIP}]"
            exit 0
        fi
        echoContent green " ---> 检查当前域名IP正确"
    fi
}
# 自定义email
customSSLEmail() {
    if echo "$1" | grep -q "validate email"; then
        read -r -p "是否重新输入邮箱地址[y/n]:" sslEmailStatus
        if [[ "${sslEmailStatus}" == "y" ]]; then
            sed '/ACCOUNT_EMAIL/d' /root/.acme.sh/account.conf >/root/.acme.sh/account.conf_tmp && mv /root/.acme.sh/account.conf_tmp /root/.acme.sh/account.conf
        else
            exit 0
        fi
    fi

    if [[ -d "/root/.acme.sh" && -f "/root/.acme.sh/account.conf" ]]; then
        if ! grep -q "ACCOUNT_EMAIL" <"/root/.acme.sh/account.conf" && ! echo "${sslType}" | grep -q "letsencrypt"; then
            read -r -p "请输入邮箱地址:" sslEmail
            if echo "${sslEmail}" | grep -q "@"; then
                echo "ACCOUNT_EMAIL='${sslEmail}'" >>/root/.acme.sh/account.conf
                echoContent green " ---> 添加完毕"
            else
                echoContent yellow "请重新输入正确的邮箱格式[例: username@example.com]"
                customSSLEmail
            fi
        fi
    fi

}

# 查找 acme_manage.sh 默认安装的 acme.sh，也兼容 ACME_HOME 和 PATH。
detectLocalAcmeHome() {
    local candidate=
    local -a candidates=("${ACME_HOME:-}" "$HOME/.acme.sh" "/root/.acme.sh")
    for candidate in "${candidates[@]}"; do
        if [[ -n "${candidate}" && -x "${candidate}/acme.sh" ]]; then
            echo "${candidate}"
            return 0
        fi
    done

    if command -v acme.sh >/dev/null 2>&1; then
        candidate=$(dirname "$(readlink -f "$(command -v acme.sh)")")
        if [[ -x "${candidate}/acme.sh" ]]; then
            echo "${candidate}"
            return 0
        fi
    fi
    return 1
}

# 从 acme.sh 的证书配置目录中选择 RSA/ECC 证书。
selectLocalAcmeCertificate() {
    local acmeHome=
    acmeHome=$(detectLocalAcmeHome) || return 1

    local -a certDomains=()
    local -a certDirs=()
    local -a certEcc=()
    local conf certDir certDomain eccLabel
    while read -r conf; do
        certDir=$(dirname "${conf}")
        certDomain=$(basename "${conf}" .conf)
        [[ -f "${certDir}/fullchain.cer" && -f "${certDir}/${certDomain}.key" ]] || continue

        if [[ "$(basename "${certDir}")" == *_ecc ]]; then
            certEcc+=(true)
        else
            certEcc+=(false)
        fi
        certDomains+=("${certDomain}")
        certDirs+=("${certDir}")
    done < <(find "${acmeHome}" -mindepth 2 -maxdepth 2 -type f -name '*.conf' 2>/dev/null | sort)

    if ((${#certDomains[@]} == 0)); then
        return 1
    fi

    echoContent skyBlue "\n---------- acme.sh 已签发证书 ----------"
    local i
    for i in "${!certDomains[@]}"; do
        eccLabel=RSA
        [[ "${certEcc[$i]}" == "true" ]] && eccLabel=ECC
        echoContent yellow "$((i + 1)). ${certDomains[$i]} [${eccLabel}]"
    done
    echoContent skyBlue "----------------------------------------"
    read -r -p "是否使用以上 acme.sh 证书？[y/n]:" useAcmeManagedCert
    [[ "${useAcmeManagedCert}" == "y" ]] || return 1

    local selectedIndex=
    read -r -p "请选择证书编号:" selectedIndex
    if [[ ! "${selectedIndex}" =~ ^[0-9]+$ ]] || ((selectedIndex < 1 || selectedIndex > ${#certDomains[@]})); then
        echoContent red " ---> 证书编号无效"
        return 1
    fi
    selectedIndex=$((selectedIndex - 1))

    acmeManagedHome=${acmeHome}
    acmeManagedSourceDomain=${certDomains[$selectedIndex]}
    acmeManagedEcc=${certEcc[$selectedIndex]}

    local serviceDomain=
    read -r -p "请输入 Xray 使用的域名[默认:${acmeManagedSourceDomain}，通配符证书可填子域名]:" serviceDomain
    serviceDomain=${serviceDomain:-${acmeManagedSourceDomain}}

    while ! openssl x509 -in "${certDirs[$selectedIndex]}/fullchain.cer" -noout -checkhost "${serviceDomain}" >/dev/null 2>&1; do
        echoContent red " ---> 所选证书不包含域名 ${serviceDomain}"
        read -r -p "请重新输入证书覆盖的域名，输入 q 取消:" serviceDomain
        [[ "${serviceDomain}" == "q" ]] && return 1
    done

    acmeManagedServiceDomain=${serviceDomain}
    acmeManagedCertSelected=true
    domain=${serviceDomain}
    echoContent green " ---> 已选择 ${acmeManagedSourceDomain} 证书，Xray域名: ${domain}"
    return 0
}

# 使用 acme.sh 官方部署接口复制证书，并让后续续期自动更新 Xray 文件。
deployLocalAcmeCertificate() {
    local certFile="/opt/xray-agent/tls/${domain}.crt"
    local keyFile="/opt/xray-agent/tls/${domain}.key"
    local -a installArgs=(
        "${acmeManagedHome}/acme.sh" --install-cert
        -d "${acmeManagedSourceDomain}"
        --fullchain-file "${certFile}"
        --key-file "${keyFile}"
        --reloadcmd "systemctl try-restart xray.service >/dev/null 2>&1 || true"
    )
    [[ "${acmeManagedEcc}" == "true" ]] && installArgs+=(--ecc)

    mkdir -p /opt/xray-agent/tls
    if ! "${installArgs[@]}"; then
        echoContent red " ---> 从 acme.sh 部署证书失败"
        return 1
    fi
    chmod 600 "${keyFile}"

    if [[ ! -s "${certFile}" || ! -s "${keyFile}" ]] || ! openssl x509 -in "${certFile}" -noout -checkhost "${domain}" >/dev/null 2>&1; then
        echoContent red " ---> 部署后的证书无效或不包含 ${domain}"
        return 1
    fi

    cat <<EOF >/opt/xray-agent/tls/acme_managed.conf
ACME_HOME=${acmeManagedHome}
SOURCE_DOMAIN=${acmeManagedSourceDomain}
SERVICE_DOMAIN=${domain}
ECC=${acmeManagedEcc}
EOF
    echoContent green " ---> 已从 acme.sh 部署证书到 ${certFile}"
    echoContent green " ---> acme.sh 续期后会自动更新证书并重载 Xray"
}

# 兼容原有调用：显示本机可被选择的 acme.sh 证书。
listLocalAcmeCertificates() {
    local acmeHome=
    acmeHome=$(detectLocalAcmeHome) || return 1
    echoContent skyBlue "\n---------- 本地 acme.sh 证书 ----------"
    find "${acmeHome}" -mindepth 2 -maxdepth 2 -type f -name '*.conf' 2>/dev/null | while read -r conf; do
        local certDir certName certType
        certDir=$(dirname "${conf}")
        certName=$(basename "${conf}" .conf)
        [[ -f "${certDir}/fullchain.cer" && -f "${certDir}/${certName}.key" ]] || continue
        certType=RSA
        [[ "$(basename "${certDir}")" == *_ecc ]] && certType=ECC
        echoContent yellow " - ${certName} [${certType}]"
    done
    echoContent skyBlue "--------------------------------------"
}

# 选择ssl安装类型
switchSSLType() {
    if [[ -z "${sslType}" ]]; then
        echoContent red "\n=============================================================="
        echoContent skyBlue "请选择 SSL 证书提供商"
        echoContent red "=============================================================="
        echoContent yellow "1. Let's Encrypt [推荐，默认]"
        echoContent green "   - 免费、稳定、广泛使用"
        echoContent yellow "2. Google Trust Services (GTS)"
        echoContent green "   - 需要 EAB 凭证 (External Account Binding)"
        echoContent red "=============================================================="
        read -r -p "请选择 [1-2，回车默认使用 Let's Encrypt]:" selectSSLType
        case ${selectSSLType} in
        2)
            sslType="google"
            echoContent green "\n ---> 已选择: Google Trust Services (GTS)"
            echoContent red "\n=============================================================="
            echoContent skyBlue "⚠️  GTS 需要 External Account Binding (EAB) 凭证"
            echoContent red "=============================================================="
            read -r -p "请输入 EAB Key ID (KID): " googleEabKid
            read -r -p "请输入 EAB HMAC Key: " googleEabHmac
            if [[ -z "${googleEabKid}" || -z "${googleEabHmac}" ]]; then
                echoContent red "\n ---> EAB 凭证不能为空，退出安装"
                echoContent yellow " ---> 建议使用 Let's Encrypt (无需额外注册)"
                exit 0
            fi
            echo "${googleEabKid}" > /opt/xray-agent/tls/google_eab_kid
            echo "${googleEabHmac}" > /opt/xray-agent/tls/google_eab_hmac
            echoContent green "\n ---> EAB 凭证已保存"
            ;;
        *)
            sslType="letsencrypt"
            echoContent green "\n ---> 已选择: Let's Encrypt (默认)"
            ;;
        esac
        echo "${sslType}" >/opt/xray-agent/tls/ssl_type
    fi
}

# 选择acme安装证书方式
selectAcmeInstallSSL() {
    #    local sslIPv6=
    #    local currentIPType=
    if [[ "${ipType}" == "6" ]]; then
        sslIPv6="--listen-v6"
    fi
    #    currentIPType=$(curl -s "-${ipType}" http://www.cloudflare.com/cdn-cgi/trace | grep "ip" | cut -d "=" -f 2)

    #    if [[ -z "${currentIPType}" ]]; then
    #                currentIPType=$(curl -s -6 http://www.cloudflare.com/cdn-cgi/trace | grep "ip" | cut -d "=" -f 2)
    #        if [[ -n "${currentIPType}" ]]; then
    #            sslIPv6="--listen-v6"
    #        fi
    #    fi

    acmeInstallSSL

    readAcmeTLS
}

# 安装SSL证书
acmeInstallSSL() {
    # Google GTS 需要先注册 EAB 账号
    if [[ "${sslType}" == "google" ]]; then
        local googleEabKid=""
        local googleEabHmac=""
        
        # 读取保存的 EAB 凭证
        if [[ -f /opt/xray-agent/tls/google_eab_kid ]]; then
            googleEabKid=$(cat /opt/xray-agent/tls/google_eab_kid)
            googleEabHmac=$(cat /opt/xray-agent/tls/google_eab_hmac)
        fi
        
        if [[ -n "${googleEabKid}" && -n "${googleEabHmac}" ]]; then
            echoContent skyBlue " ---> 检测到 Google EAB 凭证，正在注册账号..."
            
            # 注册 Google GTS 账号
            if ! "$HOME/.acme.sh/acme.sh" --register-account \
                --server google \
                --eab-kid "${googleEabKid}" \
                --eab-hmac-key "${googleEabHmac}" 2>&1 | tee -a /opt/xray-agent/tls/acme.log; then
                
                echoContent red "\n ---> Google GTS 账号注册失败"
                echoContent yellow " ---> 请检查 EAB 凭证是否正确"
                echoContent yellow " ---> 或选择其他证书提供商 (Let's Encrypt)"
                exit 0
            fi
            
            echoContent green " ---> Google GTS 账号注册成功"
        fi
    fi
    
    echoContent green " ---> 生成证书中"
    
    # Standalone 模式需要停止 Nginx 以释放 80 端口
    handleNginx stop
    
    sudo "$HOME/.acme.sh/acme.sh" --issue -d "${tlsDomain}" --standalone -k ec-256 --server "${sslType}" ${sslIPv6} 2>&1 | tee -a /opt/xray-agent/tls/acme.log >/dev/null
    
    # 证书申请完成后重启 Nginx
    handleNginx start
}
# 自定义端口
customPortFunction() {
    local historyCustomPortStatus=
    if [[ -n "${customPort}" || -n "${currentPort}" ]]; then
        echo
        # 总是询问是否使用上次端口，不管lastInstallationConfig的值
        read -r -p "读取到上次安装时的端口，是否使用上次安装时的端口？[y/n]:" historyCustomPortStatus
        if [[ "${historyCustomPortStatus}" == "y" ]]; then
            port=${currentPort}
            echoContent yellow "\n ---> 端口: ${port}"
        fi
    fi
    if [[ -z "${currentPort}" ]] || [[ "${historyCustomPortStatus}" == "n" ]]; then
        echo

        if [[ -n "${btDomain}" ]]; then
            echoContent yellow "请输入端口[不可与BT Panel/1Panel/HestiaCP端口相同，回车随机]"
            read -r -p "端口:" port
            if [[ -z "${port}" ]]; then
                port=$((RANDOM % 20001 + 10000))
            fi
        else
            echo
            echoContent yellow "请输入端口[默认: 443]，可自定义端口[回车使用默认]"
            read -r -p "端口:" port
            if [[ -z "${port}" ]]; then
                port=443
            fi
            if [[ "${port}" == "${xrayVLESSRealityPort}" ]]; then
                handleXray stop
            fi
        fi

        if [[ -n "${port}" ]]; then
            if ((port >= 1 && port <= 65535)); then
                allowPort "${port}"
                echoContent yellow "\n ---> 端口: ${port}"
                if [[ -z "${btDomain}" ]]; then
                    checkDNSIP "${domain}"
                    removeNginxDefaultConf
                    checkPortOpen "${port}" "${domain}"
                fi
            else
                echoContent red " ---> 端口输入错误"
                exit 0
            fi
        else
            echoContent red " ---> 端口不可为空"
            exit 0
        fi
    fi
}

# 初始化 Xray-core Hysteria2 UDP 监听端口。
# TCP/443 与 UDP/443 可以同时监听，因此默认复用主 TLS 端口。
initHysteria2Port() {
    local defaultPort=${port:-443}
    local selectedPort=

    if [[ -n "${hysteria2Port}" && "${hysteria2Port}" != "null" ]]; then
        read -r -p "读取到上次 Hysteria2 UDP 端口 ${hysteria2Port}，是否继续使用？[y/n]:" historyHysteria2PortStatus
        if [[ "${historyHysteria2PortStatus}" == "y" ]]; then
            selectedPort=${hysteria2Port}
        fi
    fi

    if [[ -z "${selectedPort}" ]]; then
        read -r -p "请输入 Hysteria2 UDP 端口[默认:${defaultPort}]:" selectedPort
        selectedPort=${selectedPort:-${defaultPort}}
    fi

    if [[ ! "${selectedPort}" =~ ^[0-9]+$ ]] || ((selectedPort < 1 || selectedPort > 65535)); then
        echoContent red " ---> Hysteria2 UDP端口输入错误"
        exit 1
    fi

    hysteria2Port=${selectedPort}
    allowPort "${hysteria2Port}" udp
    echoContent yellow "\n ---> Hysteria2 UDP端口: ${hysteria2Port}"
}

# 选择 Xray QUIC BBR 的行为档位，结果写入 selectedHysteria2BbrProfile。
selectHysteria2BbrProfile() {
    local defaultProfile=${1:-standard}
    local contextLabel=${2:-Hysteria2}
    local defaultChoice=2
    local profileChoice=

    case ${defaultProfile} in
    conservative) defaultChoice=1 ;;
    aggressive) defaultChoice=3 ;;
    *) defaultProfile=standard ;;
    esac

    echoContent skyBlue "\n---------- ${contextLabel} QUIC BBR Profile ----------"
    echoContent yellow "1.conservative [低抖动/保守]"
    echoContent yellow "2.standard [均衡/推荐]"
    echoContent yellow "3.aggressive [吞吐优先]"
    echoContent skyBlue "------------------------------------------------------"
    read -r -p "请选择[默认:${defaultChoice}]：" profileChoice
    profileChoice=${profileChoice:-${defaultChoice}}

    case ${profileChoice} in
    1) selectedHysteria2BbrProfile=conservative ;;
    2) selectedHysteria2BbrProfile=standard ;;
    3) selectedHysteria2BbrProfile=aggressive ;;
    *)
        echoContent red " ---> 请选择 1-3"
        selectHysteria2BbrProfile "${defaultProfile}" "${contextLabel}"
        return
        ;;
    esac
    echoContent green " ---> ${contextLabel} QUIC拥塞控制: BBR/${selectedHysteria2BbrProfile}"
}

initHysteria2BbrProfile() {
    selectHysteria2BbrProfile "${hysteria2BbrProfile:-standard}" "Hysteria2"
    hysteria2BbrProfile=${selectedHysteria2BbrProfile}
}

# 将裸域名补全为 HTTPS URL，同时拒绝非 HTTP(S) 协议和空白字符。
normalizeHTTPURL() {
    local inputURL=$1

    [[ -n "${inputURL}" && "${inputURL}" != *[[:space:]]* ]] || return 1
    case "${inputURL}" in
    http://* | https://*) ;;
    *://*) return 1 ;;
    *) inputURL="https://${inputURL}" ;;
    esac

    [[ "${inputURL}" =~ ^https?://[^/[:space:]]+(/[^[:space:]]*)?$ ]] || return 1
    if [[ "${inputURL#*://}" != */* ]]; then
        inputURL="${inputURL}/"
    fi
    printf '%s\n' "${inputURL}"
}

# 选择 Hysteria2 未认证 HTTP/3 请求的伪装方式。
initHysteria2Masquerade() {
    # 面板站点已提供完整网站和有效 TLS，直接作为 Hysteria2 伪装目标。
    # Hysteria2 使用 UDP 入站，目标网站使用 TCP/443，不会产生端口冲突。
    if [[ -n "${btDomain}" ]]; then
        local panelProxyURL=
        if panelProxyURL=$(normalizeHTTPURL "${btDomain}"); then
            hysteria2MasqueradeConfig=$(jq -nc --arg url "${panelProxyURL}" '{type:"proxy",url:$url,rewriteHost:true,insecure:false}')
            echoContent skyBlue "\n---------- Hysteria2 HTTP/3伪装 ----------"
            echoContent green " ---> 检测到宝塔/aaPanel站点，自动反向代理到: ${panelProxyURL}"
            return
        fi
        echoContent yellow " ---> 面板站点域名无效，改为手动选择Hysteria2伪装"
    fi

    echoContent skyBlue "\n---------- Hysteria2 HTTP/3伪装 ----------"
    echoContent yellow "1.本地静态网站"
    echoContent yellow "2.301跳转"
    echoContent yellow "3.反向代理现有网站"
    echoContent skyBlue "------------------------------------------"

    local masqueradeType=
    read -r -p "请选择[默认:1]:" masqueradeType
    masqueradeType=${masqueradeType:-1}

    case ${masqueradeType} in
    1)
        hysteria2MasqueradeConfig=$(jq -nc --arg dir "${nginxStaticPath}" '{type:"file",dir:$dir}')
        echoContent green " ---> 使用本地静态网站: ${nginxStaticPath}"
    ;;
    2)
        local redirectURL=
        read -r -p "请输入跳转域名[例:v.domain.com]:" redirectURL
        if ! redirectURL=$(normalizeHTTPURL "${redirectURL}"); then
            echoContent red " ---> 跳转域名格式错误"
            initHysteria2Masquerade
            return
        fi
        hysteria2MasqueradeConfig=$(jq -nc --arg url "${redirectURL}" '{type:"string",content:"",headers:{Location:$url},statusCode:301}')
        echoContent green " ---> HTTP/3未认证访问将301跳转到: ${redirectURL}"
        ;;
    3)
        local proxyURL=
        local defaultProxyURL=
        read -r -p "请输入反向代理地址${defaultProxyURL:+[默认:${defaultProxyURL}]}:" proxyURL
        proxyURL=${proxyURL:-${defaultProxyURL}}
        if ! proxyURL=$(normalizeHTTPURL "${proxyURL}"); then
            echoContent red " ---> 反向代理地址格式错误，请输入域名或完整的 http(s) URL"
            initHysteria2Masquerade
            return
        fi
        hysteria2MasqueradeConfig=$(jq -nc --arg url "${proxyURL}" '{type:"proxy",url:$url,rewriteHost:true,insecure:false}')
        echoContent green " ---> HTTP/3未认证访问将反向代理到: ${proxyURL}"
        ;;
    *)
        echoContent red " ---> 选择错误"
        initHysteria2Masquerade
        return
        ;;
    esac
}

# 检测端口是否占用
checkPort() {
    if [[ -n "$1" ]] && lsof -i "tcp:$1" | grep -q LISTEN; then
        echoContent red "\n=============================================================="
        echoContent yellow "端口 $1 已被占用"
        echoContent skyBlue "\n占用进程信息："
        lsof -i "tcp:$1" | grep LISTEN
        
        # 检查是否是 Nginx 占用
        if lsof -i "tcp:$1" | grep -q nginx; then
            echoContent yellow "\n检测到端口被 Nginx 占用，这可能是现有业务"
            echoContent red "警告：强制使用此端口可能影响现有服务！"
        fi
        echoContent red "==============================================================\n"
        
        read -r -p "是否继续（可能导致冲突）？[y/n]:" continueWithConflict
        if [[ "${continueWithConflict}" != "y" ]]; then
            echoContent yellow "请更换端口或关闭占用进程后重试"
            exit 0
        fi
    fi
}

# 安装TLS
installTLS() {
    echoContent skyBlue "\n进度  $1/${totalProgress} : 申请TLS证书\n"
    
    # 检查是否使用 Native ACME 证书
    if [[ "${nativeACMEEnabled}" == "true" ]]; then
        echoContent green " ---> 使用 Native ACME 证书"
        echoContent green " ---> 证书路径: ${nativeCertPath}"
        echoContent green " ---> 密钥路径: ${nativeKeyPath}"
        
        # 验证证书文件存在
        if [[ -f "/opt/xray-agent/tls/${domain}.crt" && -f "/opt/xray-agent/tls/${domain}.key" ]]; then
            echoContent green " ---> Native ACME 证书已就绪"
            return 0
        else
            echoContent red " ---> Native ACME 证书软链接创建失败"
            exit 0
        fi
    fi
    
    readAcmeTLS
    local tlsDomain=${domain}

    if [[ "${acmeManagedCertSelected}" == "true" ]]; then
        echoContent green " ---> 使用 acme_manage.sh / acme.sh 已签发证书"
        if ! deployLocalAcmeCertificate; then
            exit 1
        fi
        return 0
    fi

    if [[ -d "$HOME/.acme.sh" ]]; then
        listLocalAcmeCertificates
    fi

    # 安装tls
    if [[ -f "/opt/xray-agent/tls/${tlsDomain}.crt" && -f "/opt/xray-agent/tls/${tlsDomain}.key" && -n $(cat "/opt/xray-agent/tls/${tlsDomain}.crt") ]] || [[ -d "$HOME/.acme.sh/${tlsDomain}_ecc" && -f "$HOME/.acme.sh/${tlsDomain}_ecc/${tlsDomain}.key" && -f "$HOME/.acme.sh/${tlsDomain}_ecc/${tlsDomain}.cer" ]] || [[ "${installedDNSAPIStatus}" == "true" ]]; then
        echoContent green " ---> 检测到证书"
        renewalTLS

        if [[ -z $(find /opt/xray-agent/tls/ -name "${tlsDomain}.crt") ]] || [[ -z $(find /opt/xray-agent/tls/ -name "${tlsDomain}.key") ]] || [[ -z $(cat "/opt/xray-agent/tls/${tlsDomain}.crt") ]]; then
            if [[ "${installedDNSAPIStatus}" == "true" ]]; then
                sudo "$HOME/.acme.sh/acme.sh" --installcert -d "*.${dnsTLSDomain}" --fullchain-file "/opt/xray-agent/tls/${tlsDomain}.crt" --key-file "/opt/xray-agent/tls/${tlsDomain}.key" --ecc >/dev/null
            else
                sudo "$HOME/.acme.sh/acme.sh" --installcert -d "${tlsDomain}" --fullchain-file "/opt/xray-agent/tls/${tlsDomain}.crt" --key-file "/opt/xray-agent/tls/${tlsDomain}.key" --ecc >/dev/null
            fi

        else
            if [[ -d "$HOME/.acme.sh/${tlsDomain}_ecc" && -f "$HOME/.acme.sh/${tlsDomain}_ecc/${tlsDomain}.key" && -f "$HOME/.acme.sh/${tlsDomain}_ecc/${tlsDomain}.cer" ]] || [[ "${installedDNSAPIStatus}" == "true" ]]; then
                if [[ -z "${lastInstallationConfig}" ]]; then
                    echoContent yellow " ---> 如未过期或者自定义证书请选择[n]\n"
                    read -r -p "是否重新安装？[y/n]:" reInstallStatus
                    if [[ "${reInstallStatus}" == "y" ]]; then
                        rm -rf /opt/xray-agent/tls/*
                        installTLS "$1"
                    fi
                fi
            fi
        fi

    elif [[ -d "$HOME/.acme.sh" ]] && [[ ! -f "$HOME/.acme.sh/${tlsDomain}_ecc/${tlsDomain}.cer" || ! -f "$HOME/.acme.sh/${tlsDomain}_ecc/${tlsDomain}.key" ]]; then
        local -a localAcmeDirs=()
        mapfile -t localAcmeDirs < <(find "$HOME/.acme.sh" -maxdepth 1 -type d -name "*_ecc" 2>/dev/null)
        if (( ${#localAcmeDirs[@]} > 0 )); then
            echoContent red " ---> 未检测到 ${tlsDomain} 或 *.${dnsTLSDomain} 证书，脚本不会代为申请"
            echoContent yellow " ---> 请使用本地 acme.sh 或面板自行申请后再次运行"
            exit 0
        fi

        echoContent green " ---> 本地 acme.sh 尚无证书，开始申请"
        echoContent green " ---> 申请过程需要开放 80 端口"
        allowPort 80

        switchSSLType
        customSSLEmail
        selectAcmeInstallSSL

        sudo "$HOME/.acme.sh/acme.sh" --installcert -d "${tlsDomain}" --fullchainpath "/opt/xray-agent/tls/${tlsDomain}.crt" --keypath "/opt/xray-agent/tls/${tlsDomain}.key" --ecc >/dev/null

        if [[ ! -f "/opt/xray-agent/tls/${tlsDomain}.crt" || ! -f "/opt/xray-agent/tls/${tlsDomain}.key" ]] || [[ -z $(cat "/opt/xray-agent/tls/${tlsDomain}.key") || -z $(cat "/opt/xray-agent/tls/${tlsDomain}.crt") ]]; then
            tail -n 10 /opt/xray-agent/tls/acme.log
            if [[ ${installTLSCount} == "1" ]]; then
                echoContent red " ---> TLS安装失败，请检查acme日志"
                exit 0
            fi

            echo

            if tail -n 10 /opt/xray-agent/tls/acme.log | grep -q "Could not validate email address as valid"; then
                echoContent red " ---> 邮箱无法通过SSL厂商验证，请重新输入"
                echo
                customSSLEmail "validate email"
                installTLSCount=1
                installTLS "$1"
            else
                installTLSCount=1
                installTLS "$1"
            fi
        fi

        echoContent green " ---> TLS生成成功"
    else
        echoContent yellow " ---> 未安装acme.sh"
        exit 0
    fi
}

# 初始化随机字符串

