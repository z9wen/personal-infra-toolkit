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

# ===== Entry Point =====
# Runs after every module is loaded, so initialization can use any function.
initVar "$1"
checkSystem
checkCPUVendor
detectPanelNginxPath
readInstallType
readInstallProtocolType
readConfigHostPathUUID
readCustomPort
checkNginxEnvironment
cronFunction
menu
