# Uninstall the script
unInstall() {
    read -r -p "是否确认卸载安装内容？[y/n]:" unInstallStatus
    if [[ "${unInstallStatus}" != "y" ]]; then
        echoContent green " ---> 放弃卸载"
        menu
        exit 0
    fi
    checkBTPanel
    echoContent yellow " ---> 脚本不会删除acme相关配置，删除请手动执行 [rm -rf /root/.acme.sh]"
    handleNginx stop
    if [[ -z $(pgrep -f "nginx") ]]; then
        echoContent green " ---> 停止Nginx成功"
    fi
    if [[ "${coreInstallType}" == "1" ]]; then
        handleXray stop
        rm -rf /etc/systemd/system/xray.service
        echoContent green " ---> 删除Xray开机自启完成"
    fi

    removeAllPanelXhttpLocations
    disablePortHopping
    rm -rf /opt/xray-agent
    rm -rf ${nginxConfigPath}xray-agent.conf
    rm -rf ${nginxConfigPath}checkPortOpen.conf >/dev/null 2>&1
    rm -rf "${nginxConfigPath}sing_box_VMess_HTTPUpgrade.conf" >/dev/null 2>&1
    rm -rf ${nginxConfigPath}checkPortOpen.conf >/dev/null 2>&1

    unInstallSubscribe

    if [[ -d "${nginxStaticPath}" && -f "${nginxStaticPath}/check" ]]; then
        rm -rf "${nginxStaticPath}"
        echoContent green " ---> 删除伪装网站完成"
    fi
    # Other sites on the same nginx keep running without our config.
    restoreStoppedNginx

    rm -rf /usr/bin/xraya
    rm -rf /usr/sbin/xraya
    echoContent green " ---> 卸载快捷方式完成"
    echoContent green " ---> 卸载脚本完成"
}
# Update the script
updateXrayAgent() {
    echoContent skyBlue "\n进度  $1/${totalProgress} : 更新脚本"
    local scriptUrl="https://raw.githubusercontent.com/z9wen/personal-infra-toolkit/main/networking/xray-install.sh"
    local targetScript="/opt/xray-agent/install.sh"
    local temporaryScript

    mkdir -p "$(dirname "${targetScript}")"
    temporaryScript=$(mktemp "${targetScript}.update.XXXXXX") || {
        echoContent red " ---> 无法创建更新临时文件"
        return 1
    }

    echoContent yellow " ---> 正在从 GitHub 获取最新脚本..."
    if ! downloadFile "${scriptUrl}" "${temporaryScript}" --https-only; then
        rm -f "${temporaryScript}"
        echoContent red " ---> 下载失败，当前脚本未变更"
        return 1
    fi

    if ! bash -n "${temporaryScript}" || ! grep -q '^updateXrayAgent() {' "${temporaryScript}" || ! grep -q '^menu() {' "${temporaryScript}"; then
        rm -f "${temporaryScript}"
        echoContent red " ---> 下载内容校验失败，当前脚本未变更"
        return 1
    fi

    if [[ -f "${targetScript}" ]] && cmp -s "${targetScript}" "${temporaryScript}"; then
        rm -f "${temporaryScript}"
        echoContent green " ---> 当前已经是最新脚本"
        return 0
    fi

    chmod 755 "${temporaryScript}"
    if ! mv -f "${temporaryScript}" "${targetScript}"; then
        rm -f "${temporaryScript}"
        echoContent red " ---> 替换脚本失败，当前脚本未变更"
        return 1
    fi

    echoContent green " ---> 脚本更新成功，正在重新启动..."
    exec /bin/bash "${targetScript}"
}

# Script shortcut
aliasInstall() {
    # Get the actual path of the current script
    local currentScript
    currentScript="$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")"

    # Make sure the target directory exists
    if [[ ! -d "/opt/xray-agent" ]]; then
        mkdir -p /opt/xray-agent
    fi

    # Copy only on first install or when the file does not exist
    local targetScript="/opt/xray-agent/install.sh"
    local needCopy=false

    if [[ ! -f "$targetScript" ]]; then
        needCopy=true
    elif [[ "$currentScript" != "$targetScript" ]]; then
        # If the current script is not at the target location, copy it (update scenario)
        needCopy=true
    fi

    if [[ "$needCopy" == "true" && -f "$currentScript" ]]; then
        cp "$currentScript" "$targetScript"
        chmod +x "$targetScript"
        echoContent green " ---> 脚本已复制到 /opt/xray-agent/install.sh"
    elif [[ ! -f "$currentScript" ]]; then
        echoContent red " ---> 无法找到当前脚本: $currentScript"
        return 1
    fi

    # Check for and create the symlink
    local xrayaType=false
    local symlinkPath=""

    if [[ -d "/usr/bin/" ]]; then
        symlinkPath="/usr/bin/xraya"
    elif [[ -d "/usr/sbin" ]]; then
        symlinkPath="/usr/sbin/xraya"
    fi

    if [[ -n "$symlinkPath" ]]; then
        # Check whether the symlink already exists and is correct
        if [[ -L "$symlinkPath" ]] && [[ "$(readlink "$symlinkPath")" == "$targetScript" ]]; then
            # The symlink already exists and is correct; no need to recreate it
            xrayaType=true
        else
            # Remove the old symlink or file
            rm -f "$symlinkPath"

            # Create a new symlink
            ln -s "$targetScript" "$symlinkPath"
            chmod 755 "$symlinkPath"
            xrayaType=true
            echoContent green " ---> 快捷方式创建成功，可执行[xraya]重新打开脚本"
        fi
    fi

    if [[ "${xrayaType}" == "false" ]]; then
        echoContent red " ---> 快捷方式创建失败"
    fi
}
