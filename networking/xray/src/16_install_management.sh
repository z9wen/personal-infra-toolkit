# ==================== Installation ====================

# Custom-install menu entries and the protocol IDs they map to.
installMenuProtocols=(0 14 6 3 12 1)
installMenuLabels=(
    "VLESS+TCP+TLS Vision      [直连首选，需要域名]"
    "VLESS+XHTTP+TLS           [走443/可套CDN，需要域名]"
    "Hysteria2+QUIC            [UDP/游戏首选，需要域名]"
    "VLESS+Reality+Vision      [无需域名]"
    "VLESS+XHTTP+Reality       [无需域名]"
    "VLESS+WebSocket+TLS       [已弃用，建议改用XHTTP]"
)

# Human-readable names for a protocol ID list such as ",0,14,6,".
describeInstallSelection() {
    local index names=""
    for index in "${!installMenuProtocols[@]}"; do
        if hasProtocol "$1" "${installMenuProtocols[index]}"; then
            names+="${installMenuLabels[index]%%[[:space:]]*}, "
        fi
    done
    echo "${names%, }"
}

# Turn a menu selection such as "1,2,3" into a protocol ID list.
# Everything that needs a domain certificate (XHTTP+TLS, Hysteria2, WS) keeps
# Vision as the TLS front: certificate renewal and the nginx fallback hang
# off it. REALITY protocols can be installed on their own.
mapInstallMenuSelection() {
    local menuSelection=${1//[[:space:]]/} menuItem protocolId selection=","
    [[ "${menuSelection}" =~ ^[1-6](,[1-6])*$ ]] || return 1
    local -a menuItems=()
    IFS=',' read -r -a menuItems <<<"${menuSelection}"
    for menuItem in "${menuItems[@]}"; do
        protocolId=${installMenuProtocols[menuItem - 1]}
        hasProtocol "${selection}" "${protocolId}" || selection+="${protocolId},"
    done
    if selectionNeedsTLS "${selection}" && ! hasProtocol "${selection}" 0; then
        selection=",0${selection}"
    fi
    echo "${selection}"
}

customXrayInstall() {
    echoContent skyBlue "\n========================自选协议安装==========================="
    local index installMenuSelection
    for index in "${!installMenuLabels[@]}"; do
        echoContent yellow "$((index + 1)).${installMenuLabels[index]}"
    done
    echoContent green "提示：选择需要域名的协议时会自动包含 TLS Vision 作为证书和回落入口"
    read -r -p "请选择[多选，英文逗号分隔，例如:1,2,3]:" installMenuSelection
    installMenuSelection=${installMenuSelection//，/,}
    if ! selectCustomInstallType=$(mapInstallMenuSelection "${installMenuSelection}"); then
        echoContent red " ---> 输入不合法，请输入1-6并以逗号分隔"
        return 1
    fi
    runInstall
}

installRecommended() {
    selectCustomInstallType=${recommendedInstallSelection}
    echoContent skyBlue "\n推荐组合: $(describeInstallSelection "${selectCustomInstallType}")"
    runInstall
}

# Stop an installation after a failed step without leaving nginx (stopped
# earlier in the flow) down. Always returns 1.
abortInstall() {
    echoContent red " ---> $1，已中止安装"
    handleNginx start
    return 1
}

# Install the protocols in selectCustomInstallType.
runInstall() {
    local step=0 needsTLS=false restartStatus=0
    selectionNeedsTLS "${selectCustomInstallType}" && needsTLS=true
    totalProgress=11
    echoContent green " ---> 将安装: $(describeInstallSelection "${selectCustomInstallType}")"

    readLastInstallationConfig
    unInstallSubscribe
    if [[ "${needsTLS}" == "true" ]]; then
        checkBTPanel
        check1Panel
    fi
    installTools $((++step))

    if [[ "${needsTLS}" != "true" ]]; then
        echoContent skyBlue "\n进度  $((++step))/${totalProgress} : 仅安装 Reality，跳过域名与证书"
    elif [[ -n "${btDomain}" ]]; then
        echoContent skyBlue "\n进度  $((++step))/${totalProgress} : 检测到宝塔/aaPanel/1Panel，使用面板站点证书"
        customPortFunction
    else
        initTLSNginxConfig $((++step))
        installTLS $((++step))
    fi

    handleNginx stop
    if hasProtocol "${selectCustomInstallType}" 1 || hasProtocol "${selectCustomInstallType}" 12 \
        || hasProtocol "${selectCustomInstallType}" 14; then
        randomPathFunction $((++step))
    fi
    if [[ "${needsTLS}" == "true" && -z "${btDomain}" ]]; then
        nginxBlog $((++step))
    fi

    installXray $((++step)) false || abortInstall "Xray 下载或安装失败" || return 1
    installXrayService $((++step))
    initXrayConfig custom $((++step)) || abortInstall "Xray 配置生成失败" || return 1
    syncRelayRouting || abortInstall "无法恢复中转路由" || return 1
    if hasProtocol "${selectCustomInstallType}" 6; then
        syncPortHopping
    elif [[ -n "$(currentPortHopRange)" ]]; then
        disablePortHopping
    fi

    if [[ "${needsTLS}" == "true" ]]; then
        updateRedirectNginxConf || abortInstall "无法生成Nginx配置" || return 1
        # Panel sites serve 443 themselves; XHTTP goes through a location there.
        if hasProtocol "${selectCustomInstallType}" 14; then
            if [[ -n "${btDomain}" ]]; then
                echo 443 >"${xhttpStateFile}"
            else
                echo "${port}" >"${xhttpStateFile}"
            fi
            syncPanelXhttpLocation install
        else
            syncPanelXhttpLocation remove
            rm -f "${xhttpStateFile}"
        fi
        installCronTLS $((++step))
    fi

    restartXray || restartStatus=$?
    handleNginx start
    ((restartStatus == 0)) || return 1
    checkGFWStatue $((++step))
    showAccounts $((++step))
}

# Core management
coreVersionManageMenu() {

    if [[ -z "${coreInstallType}" ]]; then
        echoContent red "\n ---> 没有检测到安装目录，请执行脚本安装内容"
        menu
        exit 0
    fi
    # Only Xray-core is supported now; go straight to version management
    xrayVersionManageMenu 1
}
# Cron job check
cronFunction() {
    if [[ "${cronName}" == "RenewTLS" ]]; then
        renewalTLS
        exit 0
    elif [[ "${cronName}" == "UpdateGeo" ]]; then
        updateGeoSite >>/opt/xray-agent/crontab_updateGeoSite.log
        echoContent green " ---> geo更新日期:$(date "+%F %H:%M:%S")" >>/opt/xray-agent/crontab_updateGeoSite.log
        exit 0
    elif [[ "${cronName}" == "UpdateRelay" ]]; then
        updateRelaySubscription
        exit $?
    fi
}
# Account management
manageAccount() {
    if [[ -z "${configPath}" ]]; then
        echoContent red " ---> 未安装"
        return
    fi

    local manageAccountStatus
    while true; do
        echoContent skyBlue "\n功能 1/${totalProgress} : 账号管理"
        echoContent red "\n=============================================================="
        echoContent yellow "# 这里只管理服务端账号，不生成或修改订阅"
        echoContent yellow "# 添加账号时可自定义 UUID、tag 和目标协议\n"
        echoContent yellow "# 删除账号会从该 UUID 所属的全部协议中移除\n"
        echoContent yellow "1.查看账号"
        echoContent yellow "2.添加账号"
        echoContent yellow "3.删除账号"
        echoContent yellow "0.返回主菜单"
        echoContent red "=============================================================="
        read -r -p "请输入:" manageAccountStatus
        case ${manageAccountStatus} in
            1) listAccounts ;;
            2) addUser ;;
            3) removeUser ;;
            0) return ;;
            *) echoContent red " ---> 选择错误" ;;
        esac
        read -r -p "按回车键继续..."
    done
}
