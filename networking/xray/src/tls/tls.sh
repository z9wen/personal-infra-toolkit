# Read TLS certificate details
readAcmeTLS() {
    local readAcmeDomain=
    installedDNSAPIStatus=
    dnsTLSAcmeCertPath=
    if [[ -n "${currentHost}" ]]; then
        readAcmeDomain="${currentHost}"
    fi

    if [[ -n "${domain}" ]]; then
        readAcmeDomain="${domain}"
    fi

    dnsTLSDomain=$(echo "${readAcmeDomain}" | awk -F "." '{$1="";print $0}' | sed 's/^[[:space:]]*//' | sed 's/ /./g')
    [[ -z "${dnsTLSDomain}" || ! -d "$HOME/.acme.sh" ]] && return 0

    local candidateDir candidateCert candidateKey
    while IFS= read -r candidateDir; do
        while IFS= read -r candidateCert; do
            # Directory naming differs between acme.sh versions; rely on the certificate SAN.
            if openssl x509 -in "${candidateCert}" -noout -text 2>/dev/null | grep -Fq "DNS:*.${dnsTLSDomain}"; then
                candidateKey="${candidateCert%.cer}.key"
                if [[ ! -f "${candidateKey}" ]]; then
                    candidateKey=$(find "${candidateDir}" -maxdepth 1 -type f -name '*.key' -print -quit 2>/dev/null)
                fi
                if [[ -f "${candidateKey}" ]]; then
                    installedDNSAPIStatus=true
                    dnsTLSAcmeCertPath="${candidateCert}"
                    return 0
                fi
            fi
        done < <(find "${candidateDir}" -maxdepth 1 -type f -name '*.cer' 2>/dev/null)
    done < <(find "$HOME/.acme.sh" -maxdepth 1 -type d -name "*.${dnsTLSDomain}_ecc" 2>/dev/null)
}

# Detect native ACME clients
checkNativeACME() {
    local nativeACMEType=""

    # Detect certbot
    if command -v certbot &>/dev/null; then
        nativeACMEType="certbot"
        local certbotVersion certCount
        certbotVersion=$(certbot --version 2>&1 | head -1)
        echoContent skyBlue "\n检测到 Native ACME 客户端: ${nativeACMEType}"
        echoContent green "  版本: ${certbotVersion}"

        # Check for existing certificates
        if [[ -d "/etc/letsencrypt/live" ]]; then
            certCount=$(find /etc/letsencrypt/live -mindepth 1 -maxdepth 1 -type d | wc -l)
            if [[ ${certCount} -gt 0 ]]; then
                echoContent yellow "  已有证书数量: ${certCount}"
                echoContent skyBlue "\n可用证书域名:"
                find /etc/letsencrypt/live -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | nl
            fi
        fi
        return 0
    fi

    # Detect other ACME clients
    if command -v lego &>/dev/null; then
        nativeACMEType="lego"
        echoContent skyBlue "\n检测到 Native ACME 客户端: ${nativeACMEType}"
        return 0
    fi

    return 1
}

# Use native ACME certificates (check during initialization)
# Tell the user an existing ACME client was found. Certificate choice happens
# later, in the TLS step.
showNativeACMENotice() {
    if checkNativeACME; then
        echoContent skyBlue "\n=============================================================="
        echoContent yellow "检测到系统已安装 Native ACME 客户端"
        echoContent yellow "在安装过程中将提供使用现有证书的选项"
        echoContent red "==============================================================\n"
    fi
}
# Custom email
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

# Locate the acme.sh installed by default by acme_manage.sh; ACME_HOME and PATH are also supported.
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

# Select an RSA/ECC certificate from the acme.sh certificate config directory.
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

    acmeManagedCertSelected=true
    domain=${serviceDomain}
    echoContent green " ---> 已选择 ${acmeManagedSourceDomain} 证书，Xray域名: ${domain}"
    return 0
}

# Copy the certificate using the official acme.sh deploy interface, so later renewals update the Xray files automatically.
deployLocalAcmeCertificate() {
    local certFile="/opt/xray-agent/tls/${domain}.crt"
    local keyFile="/opt/xray-agent/tls/${domain}.key"
    local -a installArgs=(
        "${acmeManagedHome}/acme.sh" --install-cert
        -d "${acmeManagedSourceDomain}"
        --fullchain-file "${certFile}"
        --key-file "${keyFile}"
        --reloadcmd "if systemctl is-active --quiet xray.service; then systemctl restart xray.service >/dev/null 2>&1 || systemctl start xray.service >/dev/null 2>&1; fi"
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

# Kept for backward compatibility: list the acme.sh certificates available on this host.
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

# Choose the SSL installation type
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
                echo "${googleEabKid}" >/opt/xray-agent/tls/google_eab_kid
                echo "${googleEabHmac}" >/opt/xray-agent/tls/google_eab_hmac
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

# Choose how ACME issues the certificate
selectAcmeInstallSSL() {
    if [[ "${ipType}" == "6" ]]; then
        sslIPv6="--listen-v6"
    fi

    acmeInstallSSL

    readAcmeTLS
}

# Install the SSL certificate
acmeInstallSSL() {
    # Google GTS requires registering an EAB account first
    if [[ "${sslType}" == "google" ]]; then
        local googleEabKid=""
        local googleEabHmac=""

        # Read the saved EAB credentials
        if [[ -f /opt/xray-agent/tls/google_eab_kid ]]; then
            googleEabKid=$(cat /opt/xray-agent/tls/google_eab_kid)
            googleEabHmac=$(cat /opt/xray-agent/tls/google_eab_hmac)
        fi

        if [[ -n "${googleEabKid}" && -n "${googleEabHmac}" ]]; then
            echoContent skyBlue " ---> 检测到 Google EAB 凭证，正在注册账号..."

            # Register a Google GTS account
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

    # Standalone mode needs Nginx stopped to free port 80
    handleNginx stop

    sudo "$HOME/.acme.sh/acme.sh" --issue -d "${tlsDomain}" --standalone -k ec-256 --server "${sslType}" ${sslIPv6} 2>&1 | tee -a /opt/xray-agent/tls/acme.log >/dev/null

    # Restart Nginx after the certificate is issued
    handleNginx start
}

# Install TLS
installTLS() {
    echoContent skyBlue "\n进度  $1/${totalProgress} : 申请TLS证书\n"

    # Check whether a Native ACME certificate is used
    if [[ "${nativeACMEEnabled}" == "true" ]]; then
        echoContent green " ---> 使用 Native ACME 证书"
        echoContent green " ---> 证书路径: ${nativeCertPath}"
        echoContent green " ---> 密钥路径: ${nativeKeyPath}"

        # Verify that the certificate files exist
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

    # Install TLS
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
        if ((${#localAcmeDirs[@]} > 0)); then
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

# Cron job to renew the TLS certificate
installCronTLS() {
    if [[ -z "${btDomain}" ]]; then
        echoContent skyBlue "\n进度 $1/${totalProgress} : 添加定时维护证书"
        if [[ "${acmeManagedCertSelected}" == "true" || -f "/opt/xray-agent/tls/acme_managed.conf" ]]; then
            echoContent green " ---> 证书由 acme.sh 管理，保留 acme.sh 原有续期任务"
            echoContent green " ---> 续期部署完成后会自动重载 Xray"
            return 0
        fi
        crontab -l >/opt/xray-agent/backup_crontab.cron 2>/dev/null || true
        local historyCrontab
        historyCrontab=$(sed '/xray-agent-renew-tls/d;/xray-agent\/install.sh RenewTLS/d' /opt/xray-agent/backup_crontab.cron)
        echo "${historyCrontab}" >/opt/xray-agent/backup_crontab.cron
        echo "30 1 * * * /bin/bash /opt/xray-agent/install.sh RenewTLS >> /opt/xray-agent/crontab_tls.log 2>&1 # xray-agent-renew-tls" >>/opt/xray-agent/backup_crontab.cron
        crontab /opt/xray-agent/backup_crontab.cron
        echoContent green "\n ---> 添加定时维护证书成功"
    fi
}

# Renew the certificate
renewalTLS() {

    if [[ -n $1 ]]; then
        echoContent skyBlue "\n进度  $1/1 : 更新证书"
    fi

    if [[ -f "/opt/xray-agent/tls/acme_managed.conf" ]]; then
        local managedAcmeHome=
        managedAcmeHome=$(awk -F= '$1 == "ACME_HOME" {sub(/^ACME_HOME=/, ""); print; exit}' /opt/xray-agent/tls/acme_managed.conf)
        if [[ -x "${managedAcmeHome}/acme.sh" ]]; then
            echoContent green " ---> 使用 acme.sh 原有配置检查并续期证书"
            "${managedAcmeHome}/acme.sh" --cron --home "${managedAcmeHome}"
            echoContent green " ---> acme.sh 证书维护完成"
            return 0
        fi
        echoContent red " ---> 找不到已登记的 acme.sh: ${managedAcmeHome}/acme.sh"
        return 1
    fi

    readAcmeTLS
    local domain=${currentHost}
    if [[ -z "${currentHost}" && -n "${tlsDomain}" ]]; then
        domain=${tlsDomain}
    fi

    if [[ -d "$HOME/.acme.sh/${domain}_ecc" && -f "$HOME/.acme.sh/${domain}_ecc/${domain}.key" && -f "$HOME/.acme.sh/${domain}_ecc/${domain}.cer" ]] || [[ "${installedDNSAPIStatus}" == "true" ]]; then
        modifyTime=

        if [[ "${installedDNSAPIStatus}" == "true" ]]; then
            modifyTime=$(stat --format=%z "${dnsTLSAcmeCertPath}")
        else
            modifyTime=$(stat --format=%z "$HOME/.acme.sh/${domain}_ecc/${domain}.cer")
        fi

        modifyTime=$(date +%s -d "${modifyTime}")
        currentTime=$(date +%s)
        ((stampDiff = currentTime - modifyTime))
        ((days = stampDiff / 86400))
        ((remainingDays = sslRenewalDays - days))

        tlsStatus=${remainingDays}
        if [[ ${remainingDays} -le 0 ]]; then
            tlsStatus="已过期"
        fi

        echoContent skyBlue " ---> 证书检查日期:$(date "+%F %H:%M:%S")"
        echoContent skyBlue " ---> 证书生成日期:$(date -d @"${modifyTime}" +"%F %H:%M:%S")"
        echoContent skyBlue " ---> 证书生成天数:${days}"
        echoContent skyBlue " ---> 证书剩余天数:"${tlsStatus}
        echoContent skyBlue " ---> 证书过期前最后一天自动更新，如更新失败请手动更新"

        if [[ ${remainingDays} -le 1 ]]; then
            echoContent yellow " ---> 重新生成证书"
            handleNginx stop || return 1

            if [[ "${coreInstallType}" == "1" ]]; then
                handleXray stop
            fi

            sudo "$HOME/.acme.sh/acme.sh" --cron --home "$HOME/.acme.sh"
            local renewalDomain="${domain}"
            if [[ "${installedDNSAPIStatus}" == "true" ]]; then
                renewalDomain="*.${dnsTLSDomain}"
            fi
            sudo "$HOME/.acme.sh/acme.sh" --install-cert -d "${renewalDomain}" --fullchain-file "/opt/xray-agent/tls/${domain}.crt" --key-file "/opt/xray-agent/tls/${domain}.key" --ecc
            # Start nginx regardless of the Xray result so the fallback site,
            # subscriptions and WS paths are not left down overnight.
            local restartStatus=0
            restartXray || restartStatus=$?
            handleNginx start
            return "${restartStatus}"
        else
            echoContent green " ---> 证书有效"
        fi
    elif [[ -f "/opt/xray-agent/tls/${tlsDomain}.crt" && -f "/opt/xray-agent/tls/${tlsDomain}.key" && -n $(cat "/opt/xray-agent/tls/${tlsDomain}.crt") ]]; then
        echoContent yellow " ---> 检测到使用自定义证书，无法执行renew操作。"
    else
        echoContent red " ---> 未安装"
    fi
}
