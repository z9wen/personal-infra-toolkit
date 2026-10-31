# Status display
showInstallStatus() {
    if [[ -n "${coreInstallType}" ]]; then
        if [[ -n $(pgrep -f "xray/xray") ]]; then
            echoContent yellow "\n核心: Xray-core[运行中]"
        else
            echoContent yellow "\n核心: Xray-core[未运行]"
        fi
        # Read the protocol types
        readInstallProtocolType

        if [[ -n ${currentInstallProtocolType} ]]; then
            echoContent yellow "已安装协议: \c"
        fi
        if echo ${currentInstallProtocolType} | grep -q ",0,"; then
            echoContent yellow "VLESS+TCP[TLS_Vision] \c"
        fi

        if hasProtocol "${currentInstallProtocolType}" 1; then
            echoContent yellow "VLESS+WS[TLS,已弃用] \c"
        fi

        if hasProtocol "${currentInstallProtocolType}" 14; then
            echoContent yellow "VLESS+XHTTP[TLS] \c"
        fi
        if hasProtocol "${currentInstallProtocolType}" 6; then
            echoContent yellow "Hysteria2 \c"
        fi
        if hasProtocol "${currentInstallProtocolType}" 3; then
            echoContent yellow "VLESS+Reality+Vision \c"
        fi
        if hasProtocol "${currentInstallProtocolType}" 12; then
            echoContent yellow "VLESS+XHTTP+Reality \c"
        fi
    fi
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
# Main menu
menu() {
    cd "$HOME" || exit
    echoContent red "\n=============================================================="
    echoContent green "当前版本：v__XRAY_AGENT_VERSION__"
    echoContent green "描述：Xray 一键安装管理脚本\c"
    showInstallStatus
    echoContent skyBlue "快捷命令：xraya"
    echoContent skyBlue "-------------------------安装---------------------------------"
    if [[ -n "${coreInstallType}" ]]; then
        echoContent yellow "1.重新安装推荐组合"
    else
        echoContent yellow "1.安装推荐组合[Vision + XHTTP + Reality + Hysteria2]"
    fi
    echoContent yellow "2.自选协议安装"
    echoContent skyBlue "-------------------------管理---------------------------------"
    echoContent yellow "3.账号管理"
    echoContent yellow "4.订阅管理"
    echoContent yellow "5.中转管理（链式代理）"
    echoContent yellow "6.协议设置[Reality / Hysteria2 / 额外端口]"
    echoContent yellow "7.分流工具"
    echoContent yellow "8.伪装站与证书"
    echoContent skyBlue "-------------------------维护---------------------------------"
    echoContent yellow "9.Xray版本管理"
    echoContent yellow "10.更新脚本"
    echoContent yellow "11.卸载脚本"
    echoContent yellow "0.退出"
    echoContent red "=============================================================="
    mkdirTools
    aliasInstall
    read -r -p "请选择:" selectInstallType
    case ${selectInstallType} in
        1) installRecommended ;;
        2) customXrayInstall ;;
        3) manageAccount 1 ;;
        4) manageSubscriptions ;;
        5) manageRelay 1 ;;
        6) protocolSettingsMenu ;;
        7) routingToolsMenu 1 ;;
        8) siteAndCertificateMenu ;;
        9) coreVersionManageMenu 1 ;;
        10) updateXrayAgent 1 ;;
        11) unInstall 1 ;;
        0) exit 0 ;;
        *) echoContent red " ---> 请输入 0-11" ;;
    esac
}

protocolSettingsMenu() {
    echoContent skyBlue "\n-------------------------协议设置-----------------------------"
    echoContent yellow "1.Reality管理[更换目标网站/密钥]"
    echoContent yellow "2.Hysteria2管理[拥塞控制]"
    echoContent yellow "3.额外端口[多端口转发到主端口]"
    echoContent yellow "0.返回"
    local selection
    read -r -p "请选择:" selection
    case ${selection} in
        1) manageReality 1 ;;
        2) manageHysteria2 ;;
        3) addCorePort 1 ;;
        0) menu ;;
        *) echoContent red " ---> 请输入 0-3" ;;
    esac
}

siteAndCertificateMenu() {
    echoContent skyBlue "\n-------------------------伪装站与证书-------------------------"
    echoContent yellow "1.更换伪装站"
    echoContent yellow "2.检查/续签证书"
    echoContent yellow "0.返回"
    local selection
    read -r -p "请选择:" selection
    case ${selection} in
        1) updateNginxBlog 1 ;;
        2) renewalTLS 1 ;;
        0) menu ;;
        *) echoContent red " ---> 请输入 0-2" ;;
    esac
}
