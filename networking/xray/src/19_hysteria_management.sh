# hysteria管理
setHysteria2BbrProfile() {
    local profile=$1
    local hysteriaConfig="${configPath}05_hysteria2_inbounds.json"
    local tempConfig=
    local backupConfig=
    local validationOutput=

    [[ "${profile}" =~ ^(conservative|standard|aggressive)$ ]] || return 1
    if [[ ! -f "${hysteriaConfig}" ]]; then
        echoContent red " ---> 未安装Hysteria2"
        return 1
    fi

    tempConfig=$(mktemp "${hysteriaConfig}.tmp.XXXXXX") || return 1
    if ! jq --arg profile "${profile}" '
        .inbounds[0].streamSettings.finalmask //= {} |
        .inbounds[0].streamSettings.finalmask.quicParams //= {} |
        .inbounds[0].streamSettings.finalmask.quicParams.congestion = "bbr" |
        .inbounds[0].streamSettings.finalmask.quicParams.bbrProfile = $profile
    ' "${hysteriaConfig}" >"${tempConfig}"; then
        rm -f "${tempConfig}"
        echoContent red " ---> Hysteria2配置更新失败"
        return 1
    fi

    backupConfig=$(mktemp "${hysteriaConfig}.bak.XXXXXX") || {
        rm -f "${tempConfig}"
        return 1
    }
    if ! cp "${hysteriaConfig}" "${backupConfig}"; then
        rm -f "${tempConfig}" "${backupConfig}"
        echoContent red " ---> Hysteria2配置备份失败"
        return 1
    fi
    chmod --reference="${hysteriaConfig}" "${tempConfig}" 2>/dev/null || chmod 644 "${tempConfig}"
    if ! mv "${tempConfig}" "${hysteriaConfig}"; then
        rm -f "${tempConfig}" "${backupConfig}"
        echoContent red " ---> Hysteria2配置保存失败"
        return 1
    fi

    if ! validationOutput=$(/opt/xray-agent/xray/xray run -test -confdir "${configPath}" 2>&1); then
        mv "${backupConfig}" "${hysteriaConfig}"
        echoContent red " ---> Xray拒绝了新配置，已自动恢复"
        echoContent yellow "${validationOutput}"
        return 1
    fi

    rm -f "${backupConfig}"
    handleXray stop
    handleXray start
    hysteria2BbrProfile=${profile}
    echoContent green " ---> Hysteria2 QUIC拥塞控制已切换为: BBR/${profile}"
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
        echoContent green "# 此处调整本机Hysteria2入站；链式上游在中转管理中单独设置"
        echoContent yellow "1.切换为 conservative [低抖动/保守]"
        echoContent yellow "2.切换为 standard [均衡/推荐]"
        echoContent yellow "3.切换为 aggressive [吞吐优先]"
        echoContent yellow "0.返回主菜单"
        echoContent red "========================================================="
        read -r -p "请选择:" manageChoice

        case ${manageChoice} in
        1) setHysteria2BbrProfile conservative ;;
        2) setHysteria2BbrProfile standard ;;
        3) setHysteria2BbrProfile aggressive ;;
        0) return ;;
        *) echoContent red " ---> 请输入 0-3" ;;
        esac
    done
}

