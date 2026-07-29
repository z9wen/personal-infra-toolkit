# Xray-core个性化安装
mapInstallMenuSelection() {
    local menuSelection=${1//[[:space:]]/}
    [[ "${menuSelection}" =~ ^[1-4](,[1-4])*$ ]] || return 1

    local mappedSelection= menuItem protocolId
    local -a menuItems=()
    IFS=',' read -r -a menuItems <<<"${menuSelection}"
    for menuItem in "${menuItems[@]}"; do
        case "${menuItem}" in
        1) protocolId=0 ;;
        2) protocolId=1 ;;
        3) protocolId=3 ;;
        4) protocolId=6 ;;
        *) return 1 ;;
        esac
        if [[ ",${mappedSelection}," != *",${protocolId},"* ]]; then
            mappedSelection="${mappedSelection:+${mappedSelection},}${protocolId}"
        fi
    done

    # WS 与 Hysteria2 的组合安装沿用 Vision 作为 TLS 前置；Reality 可单独安装。
    if [[ "${mappedSelection}" != "3" && ",${mappedSelection}," != *",0,"* ]]; then
        mappedSelection="0,${mappedSelection}"
    fi
    printf ',%s,\n' "${mappedSelection}"
}

customXrayInstall() {
    echoContent skyBlue "\n========================个性化安装============================"
    echoContent yellow "1.VLESS+TLS Vision+TCP[推荐]"
    echoContent yellow "2.VLESS+TLS+WebSocket[仅CDN推荐]"
    echoContent yellow "3.VLESS+Reality+uTLS+Vision[可单独安装]"
    echoContent yellow "4.Hysteria2+TLS+QUIC[UDP/游戏推荐]"
    echoContent green "提示：选择WebSocket或Hysteria2时会自动包含TLS Vision前置"
    local installMenuSelection=
    read -r -p "请选择[多选]，[例如:1,2,4]:" installMenuSelection
    echoContent skyBlue "--------------------------------------------------------------"
    if echo "${installMenuSelection}" | grep -q "，"; then
        echoContent red " ---> 请使用英文逗号分隔"
        exit 0
    fi
    if ! selectCustomInstallType=$(mapInstallMenuSelection "${installMenuSelection}"); then
        echoContent red " ---> 输入不合法，请使用1-4并以英文逗号分隔"
        customXrayInstall
        return
    fi

    if [[ "${selectCustomInstallType//,/}" =~ ^[0136]+$ ]]; then
        readLastInstallationConfig
        unInstallSubscribe
        checkBTPanel
        check1Panel
        checkHestiaPanel
        totalProgress=12
        installTools 1
        if [[ -n "${btDomain}" ]]; then
            echoContent skyBlue "\n进度  3/${totalProgress} : 检测到宝塔面板/1Panel/HestiaCP，跳过申请TLS步骤"
            handleXray stop
            if [[ "${selectCustomInstallType}" != ",3," ]]; then
                customPortFunction
            fi
        else
            # 申请tls
            if [[ "${selectCustomInstallType}" != ",3," ]]; then
                initTLSNginxConfig 2
                handleXray stop
                installTLS 3
            else
                echoContent skyBlue "\n进度  2/${totalProgress} : 检测到仅安装Reality，跳过TLS证书步骤"
            fi
        fi

        handleNginx stop
        # 随机path
        if echo "${selectCustomInstallType}" | grep -q ",1,"; then
            randomPathFunction 4
        fi
        if [[ -n "${btDomain}" ]]; then
            echoContent skyBlue "\n进度  6/${totalProgress} : 检测到宝塔面板/1Panel/HestiaCP，跳过伪装网站"
        else
            nginxBlog 6
        fi
        if [[ "${selectCustomInstallType}" != ",3," ]]; then
            if ! updateRedirectNginxConf; then
                echoContent red " ---> 无法生成Nginx配置，已中止安装并尝试恢复Nginx"
                handleNginx start
                return 1
            fi
            handleNginx start
        fi

        # 安装Xray
        installXray 7 false
        installXrayService 8
        initXrayConfig custom 9
        if [[ "${selectCustomInstallType}" != ",3," ]]; then
            installCronTLS 10
        fi

        handleXray stop
        handleXray start
        # 生成账号
        checkGFWStatue 11
        showAccounts 12
    else
        echoContent red " ---> 输入不合法"
        customXrayInstall
    fi
}


selectCoreInstall() {
    # 现在只支持 Xray-core，直接进入安装
    if [[ "${selectInstallType}" == "2" ]]; then
        customXrayInstall
    else
        xrayCoreInstall
    fi
}

# xray-core 安装
xrayCoreInstall() {
    readLastInstallationConfig
    unInstallSubscribe
    checkBTPanel
    check1Panel
    checkHestiaPanel
    selectCustomInstallType=
    totalProgress=12
    installTools 2
    if [[ -n "${btDomain}" ]]; then
        echoContent skyBlue "\n进度  3/${totalProgress} : 检测到宝塔面板/1Panel/HestiaCP，跳过申请TLS步骤"
        handleXray stop
        customPortFunction
    else
        # 申请tls
        initTLSNginxConfig 3
        handleXray stop
        installTLS 4
    fi

    handleNginx stop
    randomPathFunction 5

    # 安装Xray
    installXray 6 false
    installXrayService 7
    initXrayConfig all 8
    installCronTLS 9
    if [[ -n "${btDomain}" ]]; then
        echoContent skyBlue "\n进度  11/${totalProgress} : 检测到宝塔面板/1Panel/HestiaCP，跳过伪装网站"
    else
        nginxBlog 10
    fi
    if ! updateRedirectNginxConf; then
        echoContent red " ---> 无法生成Nginx配置，已中止安装并尝试恢复Nginx"
        handleNginx start
        return 1
    fi
    handleXray stop
    sleep 2
    handleXray start

    handleNginx start
    # 生成账号
    checkGFWStatue 11
    showAccounts 12
}

# 核心管理
coreVersionManageMenu() {

    if [[ -z "${coreInstallType}" ]]; then
        echoContent red "\n ---> 没有检测到安装目录，请执行脚本安装内容"
        menu
        exit 0
    fi
    # 现在只支持 Xray-core，直接进入版本管理
    xrayVersionManageMenu 1
}
# 定时任务检查
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
# 账号管理
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
