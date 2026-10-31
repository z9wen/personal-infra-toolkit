# Initialize the Xray-core Hysteria2 UDP listen port.
# TCP/443 and UDP/443 can be listened on simultaneously, so the main TLS port is reused by default.
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
    initHysteria2PortHopping
}

# Choose the Xray QUIC BBR behavior profile; the result is written to selectedHysteria2BbrProfile.
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

# The BBR profile is not asked during installation. New installs use
# "standard"; a reinstall keeps the profile chosen earlier in Hysteria2
# management (hysteria2BbrProfile is read from the existing config).
initHysteria2BbrProfile() {
    [[ "${hysteria2BbrProfile}" =~ ^(conservative|standard|aggressive)$ ]] || hysteria2BbrProfile=standard
    echoContent green " ---> Hysteria2 QUIC拥塞控制: BBR/${hysteria2BbrProfile}（可在「协议设置 → Hysteria2管理」中修改）"
}

# Expand a bare domain into an HTTPS URL, rejecting non-HTTP(S) schemes and whitespace.
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

# Choose the masquerade method for unauthenticated Hysteria2 HTTP/3 requests.
# Sets hysteria2MasqueradeConfig to a JSON object, or to "null" when
# masquerading is turned off (the inbound then has no masquerade at all).
initHysteria2Masquerade() {
    # The panel site already serves a full website with valid TLS, so use it directly as the Hysteria2 masquerade target.
    # Hysteria2 uses a UDP inbound while the target site uses TCP/443, so there is no port conflict.
    if [[ -n "${btDomain:-}" ]]; then
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
    echoContent yellow "1.本地静态网站[默认]"
    echoContent yellow "2.301跳转"
    echoContent yellow "3.反向代理现有网站"
    echoContent yellow "4.不启用伪装"
    echoContent skyBlue "------------------------------------------"

    local masqueradeType=
    read -r -p "请选择[默认:1]:" masqueradeType
    masqueradeType=${masqueradeType:-1}

    case ${masqueradeType} in
        1)
            hysteria2MasqueradeConfig=$(jq -nc --arg dir "${nginxStaticPath}" '{type:"file",dir:$dir}')
            echoContent green " ---> 使用本地静态网站: ${nginxStaticPath}"
            ;;
        4)
            hysteria2MasqueradeConfig=null
            echoContent yellow " ---> 不启用HTTP/3伪装"
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

# Hysteria2 configs written by older versions of this script on a v26.5.9+
# core use "users", which stable v26.3.27 accepts in `run -test` but ignores
# at runtime. "clients" works everywhere, so convert before switching cores.
normalizeHysteria2UserField() {
    local file="${configPath}05_hysteria2_inbounds.json" converted
    [[ -f "${file}" ]] || return 0
    jq -e '.inbounds[0].settings | has("users") and (has("clients") | not)' "${file}" >/dev/null 2>&1 || return 0
    converted=$(jq '.inbounds[0].settings |= (.clients = .users | del(.users))' "${file}") || return 1
    echo "${converted}" >"${file}.tmp.$$" && mv "${file}.tmp.$$" "${file}"
}
# Hysteria management

# quicParams.bbrProfile exists since Xray v26.4.13 (XTLS/Xray-core#5869).
# Stable v26.3.27 silently ignores it, so the profile would have no effect.
hysteria2BbrProfileMinVersion=v26.4.13

bbrProfileSupported() {
    xrayVersionAtLeast "$(installedXrayVersion)" "${hysteria2BbrProfileMinVersion}"
}

writeHysteria2BbrProfile() {
    local profile=$1 file="${configPath}05_hysteria2_inbounds.json" updated
    updated=$(jq --arg profile "${profile}" '
        .inbounds[0].streamSettings.finalmask.quicParams.congestion = "bbr" |
        .inbounds[0].streamSettings.finalmask.quicParams.bbrProfile = $profile
    ' "${file}") || return 1
    echo "${updated}" >"${file}"
}

setHysteria2BbrProfile() {
    local profile=$1
    [[ "${profile}" =~ ^(conservative|standard|aggressive)$ ]] || return 1
    if [[ ! -f "${configPath}05_hysteria2_inbounds.json" ]]; then
        echoContent red " ---> 未安装Hysteria2"
        return 1
    fi
    if ! bbrProfileSupported; then
        echoContent red " ---> 当前 Xray $(installedXrayVersion) 不支持 bbrProfile，设置不会生效"
        echoContent yellow " ---> 需要 ${hysteria2BbrProfileMinVersion} 或更新版本，可在「Xray版本管理」中升级到预览版"
        return 1
    fi
    applyXrayConfigChange "切换Hysteria2拥塞控制" writeHysteria2BbrProfile "${profile}" || return 1
    restartXray || return 1
    hysteria2BbrProfile=${profile}
    echoContent green " ---> Hysteria2 QUIC拥塞控制已切换为: BBR/${profile}"
}

# Short description of the current HTTP/3 masquerade.
describeHysteria2Masquerade() {
    jq -r '.inbounds[0].streamSettings.hysteriaSettings.masquerade |
        if . == null then "未启用"
        elif .type == "file" then "本地静态网站 " + .dir
        elif .type == "proxy" then "反向代理 " + .url
        elif .type == "string" then "跳转 " + (.headers.Location // "")
        else .type end' "${configPath}05_hysteria2_inbounds.json"
}

writeHysteria2Masquerade() {
    local file="${configPath}05_hysteria2_inbounds.json" updated
    updated=$(jq --argjson masquerade "${hysteria2MasqueradeConfig}" '
        if $masquerade == null then del(.inbounds[0].streamSettings.hysteriaSettings.masquerade)
        else .inbounds[0].streamSettings.hysteriaSettings.masquerade = $masquerade end
    ' "${file}") || return 1
    echo "${updated}" >"${file}"
}

setHysteria2Masquerade() {
    local currentDir
    # Keep the directory a local-site masquerade already uses (e.g. a panel site).
    currentDir=$(jq -r '.inbounds[0].streamSettings.hysteriaSettings.masquerade | select(.type == "file") | .dir // empty' \
        "${configPath}05_hysteria2_inbounds.json")
    # Always show the menu here; the install-time panel shortcut (btDomain)
    # would otherwise pick the panel site without asking.
    local btDomain=
    nginxStaticPath=${currentDir:-${nginxStaticPath}}
    initHysteria2Masquerade || return 1
    applyXrayConfigChange "修改Hysteria2伪装" writeHysteria2Masquerade || return 1
    restartXray || return 1
    echoContent green " ---> HTTP/3伪装: $(describeHysteria2Masquerade)"
}

manageHysteria2() {
    local hysteriaConfig="${configPath}05_hysteria2_inbounds.json"
    if [[ ! -f "${hysteriaConfig}" ]]; then
        echoContent red " ---> 当前未安装Hysteria2，请先通过任意组合安装"
        return
    fi

    while true; do
        local currentCongestion=
        local currentProfile=
        local manageChoice=
        currentCongestion=$(jq -r '.inbounds[0].streamSettings.finalmask.quicParams.congestion // "默认"' "${hysteriaConfig}")
        currentProfile=$(jq -r '.inbounds[0].streamSettings.finalmask.quicParams.bbrProfile // "standard"' "${hysteriaConfig}")

        echoContent skyBlue "\n===================== Hysteria2管理 ====================="
        echoContent yellow "当前QUIC拥塞控制: ${currentCongestion}/${currentProfile}"
        if ! bbrProfileSupported; then
            echoContent red "注意: 当前 Xray $(installedXrayVersion) 不支持 bbrProfile（${hysteria2BbrProfileMinVersion} 起支持），以下档位不会生效"
        fi
        echoContent green "# 此处调整本机Hysteria2入站；链式上游在中转管理中单独设置"
        echoContent yellow "1.切换为 conservative [低抖动/保守]"
        echoContent yellow "2.切换为 standard [均衡/推荐]"
        echoContent yellow "3.切换为 aggressive [吞吐优先]"
        echoContent yellow "4.端口跳跃[当前: $(currentPortHopRange || echo 未启用)]"
        echoContent yellow "5.HTTP/3伪装[当前: $(describeHysteria2Masquerade)]"
        echoContent yellow "0.返回主菜单"
        echoContent red "========================================================="
        read -r -p "请选择:" manageChoice

        case ${manageChoice} in
            1) setHysteria2BbrProfile conservative ;;
            2) setHysteria2BbrProfile standard ;;
            3) setHysteria2BbrProfile aggressive ;;
            4) managePortHopping ;;
            5) setHysteria2Masquerade ;;
            0) return ;;
            *) echoContent red " ---> 请输入 0-5" ;;
        esac
    done
}
