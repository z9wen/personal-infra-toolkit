
removeNginx302() {
    # 检查配置文件是否存在
    if [[ ! -f "${nginxConfigPath}xray-agent.conf" ]]; then
        echoContent red " ---> 配置文件不存在: ${nginxConfigPath}xray-agent.conf"
        echoContent yellow " ---> 请先完成 Xray 安装后再使用此功能"
        return 1
    fi
    
    # 使用临时文件避免在循环中修改原文件
    local tmpFile="${nginxConfigPath}xray-agent.conf.tmp"
    cp "${nginxConfigPath}xray-agent.conf" "${tmpFile}"
    
    # 删除所有 return 302/301 行（排除包含 request_uri 的）
    sed -i '/return 30[12]/!b; /request_uri/b; d' "${tmpFile}"
    
    # 替换原文件
    mv "${tmpFile}" "${nginxConfigPath}xray-agent.conf"
}

# 检查302是否成功
checkNginx302() {
    local testHost="${currentHost}"
    local testPort="${currentPort}"

    if [[ -z "${testHost}" || "${testHost}" == "null" ]]; then
        testHost=$(getPublicIP)
    fi
    if [[ -z "${testHost}" ]]; then
        testHost="127.0.0.1"
    fi

    if [[ -z "${testPort}" || "${testPort}" == "null" ]]; then
        if [[ -n "${currentDefaultPort}" ]]; then
            testPort="${currentDefaultPort}"
        else
            testPort=443
        fi
    fi

    local scheme="https"
    if [[ "${testPort}" == "80" ]]; then
        scheme="http"
    fi

    local targetUrl="${scheme}://${testHost}:${testPort}"
    local httpCode=
    httpCode=$(curl -I -k --connect-timeout 5 -s -o /dev/null -w "%{http_code}" "${targetUrl}")
    
    if [[ "${httpCode}" == "302" ]]; then
        echoContent green " ---> 重定向设置完毕 (HTTP ${httpCode})"
        exit 0
    fi

    echoContent red " ---> 重定向设置失败，HTTP状态码: ${httpCode}"
    echoContent yellow " ---> 检测 URL: ${targetUrl}"
    echoContent yellow "请检查配置是否正确"
    backupNginxConfig restoreBackup
    handleNginx stop >/dev/null 2>&1
    handleNginx start >/dev/null 2>&1
}

# 备份恢复nginx文件
backupNginxConfig() {
    if [[ "$1" == "backup" ]]; then
        if [[ ! -f "${nginxConfigPath}xray-agent.conf" ]]; then
            echoContent red " ---> 配置文件不存在: ${nginxConfigPath}xray-agent.conf"
            echoContent yellow " ---> 请先完成 Xray 安装后再使用此功能"
            return 1
        fi
        cp ${nginxConfigPath}xray-agent.conf /opt/xray-agent/xray-agent_backup.conf
        echoContent green " ---> nginx配置文件备份成功"
    fi

    if [[ "$1" == "restoreBackup" ]] && [[ -f "/opt/xray-agent/xray-agent_backup.conf" ]]; then
        cp /opt/xray-agent/xray-agent_backup.conf ${nginxConfigPath}xray-agent.conf
        echoContent green " ---> nginx配置文件恢复备份成功"
        rm /opt/xray-agent/xray-agent_backup.conf
    fi

}
# 添加302配置
addNginx302() {
    local redirectUrl="$1"
    local redirectCode="302"  # 固定使用 302

    # 检查配置文件是否存在
    if [[ ! -f "${nginxConfigPath}xray-agent.conf" ]]; then
        echoContent red " ---> 配置文件不存在: ${nginxConfigPath}xray-agent.conf"
        echoContent yellow " ---> 请先完成 Xray 安装后再使用此功能"
        backupNginxConfig restoreBackup
        return 1
    fi
    
    # 验证 URL 格式
    if [[ ! "${redirectUrl}" =~ ^https?:// ]]; then
        echoContent red " ---> URL 格式错误，必须以 http:// 或 https:// 开头"
        backupNginxConfig restoreBackup
        return 1
    fi
    
    # 转义特殊字符（单引号）
    redirectUrl="${redirectUrl//\'/\'\\\'\'}"
    
    # 读取所有 location / { 的行号到数组
    local lineNumbers=()
    while IFS= read -r line; do
        lineNumbers+=("$(echo "${line}" | awk -F ":" '{print $1}')")
    done < <(grep -n "location / {" "${nginxConfigPath}xray-agent.conf")
    
    # 从后往前插入，避免行号变化
    local count=${#lineNumbers[@]}
    for ((i=count-1; i>=0; i--)); do
        local insertIndex=$((lineNumbers[i] + 1))
        sed -i "${insertIndex}i\\        return ${redirectCode} '${redirectUrl}';" "${nginxConfigPath}xray-agent.conf"
    done
    
    if [[ ${count} -eq 0 ]]; then
        echoContent red " ---> 重定向添加失败：未找到 location / { 配置"
        backupNginxConfig restoreBackup
        return 1
    fi
    
    echoContent green " ---> 已在 ${count} 处添加 ${redirectCode} 重定向"
}

# 更新伪装站
updateNginxBlog() {
    echoContent skyBlue "\n进度 $1/${totalProgress} : 更换伪装站点"

    if ! echo "${currentInstallProtocolType}" | grep -q ",0," || [[ -z "${coreInstallType}" ]]; then
        echoContent red "\n ---> 由于环境依赖，请先安装Xray-core的VLESS_TCP_TLS_Vision"
        exit 0
    fi
    echoContent red "=============================================================="
    echoContent yellow "# 如需自定义，请手动复制模版文件到 ${nginxStaticPath} \n"
    echoContent yellow "1.新手引导"
    echoContent yellow "2.游戏网站"
    echoContent yellow "3.个人博客01"
    echoContent yellow "4.企业站"
    echoContent yellow "5.解锁加密的音乐文件模版[https://github.com/ix64/unlock-music]"
    echoContent yellow "6.mikutap[https://github.com/HFIProgramming/mikutap]"
    echoContent yellow "7.企业站02"
    echoContent yellow "8.个人博客02"
    echoContent yellow "9.404自动跳转baidu"
    echoContent yellow "10.重定向网站（不使用伪装站）"
    echoContent red "=============================================================="
    read -r -p "请选择:" selectInstallNginxBlogType

    if [[ "${selectInstallNginxBlogType}" == "10" ]]; then
        echoContent red "\n=============================================================="
        echoContent skyBlue "📌 重定向配置说明："
        echoContent yellow "• 重定向会替代伪装站点，根路由 / 将直接跳转"
        echoContent yellow "• 代理路径（如 /your-path）不受影响，正常使用"
        echoContent yellow "1.添加重定向"
        echoContent yellow "2.删除重定向"
        echoContent red "=============================================================="
        read -r -p "请选择:" redirectStatus

        if [[ "${redirectStatus}" == "1" ]]; then
            backupNginxConfig backup
            echoContent yellow "\n使用 302 临时重定向，便于随时调整目标 URL。"

            read -r -p "请输入要重定向的完整URL:" redirectDomain
            
            if [[ -z "${redirectDomain}" ]]; then
                echoContent red " ---> 重定向URL不能为空"
                backupNginxConfig restoreBackup
                exit 0
            fi
            
            removeNginx302
            addNginx302 "${redirectDomain}"
            handleNginx stop
            handleNginx start
            if [[ -z $(pgrep -f "nginx") ]]; then
                backupNginxConfig restoreBackup
                handleNginx start
                exit 0
            fi
            checkNginx302
            exit 0
        fi
        if [[ "${redirectStatus}" == "2" ]]; then
            removeNginx302
            echoContent green " ---> 移除302重定向成功"
            exit 0
        fi
    fi
    if [[ "${selectInstallNginxBlogType}" =~ ^[1-9]$ ]]; then
        deployNginxTemplate "${selectInstallNginxBlogType}" || return 1
        echoContent green " ---> 更换伪站成功"
    else
        echoContent red " ---> 选择错误，请重新选择"
        updateNginxBlog
    fi
}

# 添加新端口
addCorePort() {
    echoContent skyBlue "\n功能 1/${totalProgress} : 添加新端口"
    echoContent red "\n=============================================================="
    echoContent yellow "# 注意事项\n"
    echoContent yellow "支持批量添加"
    echoContent yellow "不影响默认端口的使用"
    echoContent yellow "查看账号时，只会展示默认端口的账号"
    echoContent yellow "不允许有特殊字符，注意逗号的格式"
    echoContent yellow "如已安装Hysteria2，会同时添加Hysteria2的UDP转发端口"
    echoContent yellow "录入示例:2053,2083,2087\n"

    echoContent yellow "1.查看已添加端口"
    echoContent yellow "2.添加端口"
    echoContent yellow "3.删除端口"
    echoContent red "=============================================================="
    read -r -p "请选择:" selectNewPortType
    if [[ "${selectNewPortType}" == "1" ]]; then
        find ${configPath} -name "*dokodemodoor*" | grep -v "hysteria" | awk -F "[c][o][n][f][/]" '{print $2}' | awk -F "[_]" '{print $4}' | awk -F "[.]" '{print ""NR""":"$1}'
        exit 0
    elif [[ "${selectNewPortType}" == "2" ]]; then
        read -r -p "请输入端口号:" newPort
        read -r -p "请输入默认的端口号，同时会更改订阅端口以及节点端口，[回车]默认443:" defaultPort

        if [[ -n "${defaultPort}" ]]; then
            rm -rf "$(find ${configPath}* | grep "default")"
        fi

        if [[ -n "${newPort}" ]]; then

            while read -r port; do
                rm -rf "$(find ${configPath}* | grep "${port}")"

                local fileName=
                local hysteriaFileName=
                if [[ -n "${defaultPort}" && "${port}" == "${defaultPort}" ]]; then
                    fileName="${configPath}02_dokodemodoor_inbounds_${port}_default.json"
                else
                    fileName="${configPath}02_dokodemodoor_inbounds_${port}.json"
                fi

                if [[ -n ${hysteria2Port} ]]; then
                    hysteriaFileName="${configPath}02_dokodemodoor_inbounds_hysteria_${port}.json"
                fi

                # 开放端口
                allowPort "${port}"
                allowPort "${port}" "udp"

                local settingsPort=443
                if [[ -n "${customPort}" ]]; then
                    settingsPort=${customPort}
                fi

                if [[ -n ${hysteriaFileName} ]]; then
                    cat <<EOF >"${hysteriaFileName}"
{
  "inbounds": [
	{
	  "listen": "0.0.0.0",
	  "port": ${port},
	  "protocol": "dokodemo-door",
	  "settings": {
		"address": "127.0.0.1",
		"port": ${hysteria2Port},
		"network": "udp",
		"followRedirect": false
	  },
	  "tag": "dokodemo-door-newPort-hysteria-${port}"
	}
  ]
}
EOF
                fi
                cat <<EOF >"${fileName}"
{
  "inbounds": [
	{
	  "listen": "0.0.0.0",
	  "port": ${port},
	  "protocol": "dokodemo-door",
	  "settings": {
		"address": "127.0.0.1",
		"port": ${settingsPort},
		"network": "tcp",
		"followRedirect": false
	  },
	  "tag": "dokodemo-door-newPort-${port}"
	}
  ]
}
EOF
            done < <(echo "${newPort}" | tr ',' '\n')

            echoContent green " ---> 添加完毕"
            handleXray stop
            handleXray start
            addCorePort
        fi
    elif [[ "${selectNewPortType}" == "3" ]]; then
        find ${configPath} -name "*dokodemodoor*" | grep -v "hysteria" | awk -F "[c][o][n][f][/]" '{print $2}' | awk -F "[_]" '{print $4}' | awk -F "[.]" '{print ""NR""":"$1}'
        read -r -p "请输入要删除的端口编号:" portIndex
        local dokoConfig
        dokoConfig=$(find ${configPath} -name "*dokodemodoor*" | grep -v "hysteria" | awk -F "[c][o][n][f][/]" '{print $2}' | awk -F "[_]" '{print $4}' | awk -F "[.]" '{print ""NR""":"$1}' | grep "${portIndex}:")
        if [[ -n "${dokoConfig}" ]]; then
            rm "${configPath}02_dokodemodoor_inbounds_$(echo "${dokoConfig}" | awk -F "[:]" '{print $2}').json"
            local hysteriaDokodemodoorFilePath=

            hysteriaDokodemodoorFilePath="${configPath}02_dokodemodoor_inbounds_hysteria_$(echo "${dokoConfig}" | awk -F "[:]" '{print $2}').json"
            if [[ -f "${hysteriaDokodemodoorFilePath}" ]]; then
                rm "${hysteriaDokodemodoorFilePath}"
            fi

            handleXray stop
            handleXray start
            addCorePort
        else
            echoContent yellow "\n ---> 编号输入错误，请重新选择"
            addCorePort
        fi
    fi
}

# 卸载脚本
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

    rm -rf /usr/bin/xraya
    rm -rf /usr/sbin/xraya
    echoContent green " ---> 卸载快捷方式完成"
    echoContent green " ---> 卸载脚本完成"
}

# 自定义uuid
customUUID() {
    read -r -p "请输入合法的UUID，[回车]随机UUID:" currentCustomUUID
    echo
    if [[ -z "${currentCustomUUID}" ]]; then
        currentCustomUUID=$(${ctlPath} uuid)

        echoContent yellow "uuid：${currentCustomUUID}\n"

    else
        local checkUUID=
        local userConfigFile=
        while IFS= read -r userConfigFile; do
            if jq -e --arg currentUUID "${currentCustomUUID}" '
                any(.inbounds[]?.settings.clients[]?; (.auth // .id // .uuid // "") == $currentUUID) or
                any(.inbounds[]?.settings.users[]?; (.auth // .id // .uuid // "") == $currentUUID)
            ' "${userConfigFile}" >/dev/null 2>&1; then
                checkUUID=true
                break
            fi
        done < <(find "${configPath}" -maxdepth 1 -type f -name '*inbounds.json' 2>/dev/null)

        if [[ -n "${checkUUID}" ]]; then
            echoContent red " ---> UUID不可重复"
            exit 0
        fi
    fi
}

# 自定义email
customUserEmail() {
    read -r -p "请输入合法的email，[回车]随机email:" currentCustomEmail
    echo
    if [[ -z "${currentCustomEmail}" ]]; then
        currentCustomEmail="${currentCustomUUID}"
        echoContent yellow "email: ${currentCustomEmail}\n"
    else
        local checkEmail=
        local userConfigFile=
        while IFS= read -r userConfigFile; do
            if jq -e --arg currentEmail "${currentCustomEmail}" '
                any(
                    (.inbounds[]?.settings.clients[]?, .inbounds[]?.settings.users[]?);
                    ((.email // .name // .username // "") == $currentEmail) or
                    ((.email // .name // .username // "") | startswith($currentEmail + "-"))
                )
            ' "${userConfigFile}" >/dev/null 2>&1; then
                checkEmail=true
                break
            fi
        done < <(find "${configPath}" -maxdepth 1 -type f -name '*inbounds.json' 2>/dev/null)

        if [[ -n "${checkEmail}" ]]; then
            echoContent red " ---> email不可重复"
            exit 0
        fi
    fi
}

# 添加用户
addUser() {
    read -r -p "请输入要添加的用户数量:" userNum
    echo
    if [[ -z ${userNum} || ${userNum} -le 0 ]]; then
        echoContent red " ---> 输入有误，请重新输入"
        exit 0
    fi
    local userConfig=".inbounds[0].settings.clients"

    while [[ ${userNum} -gt 0 ]]; do
        readConfigHostPathUUID
        local users=
        ((userNum--)) || true

        customUUID
        customUserEmail

        uuid=${currentCustomUUID}
        email=${currentCustomEmail}

        # VLESS TCP
        if echo "${currentInstallProtocolType}" | grep -q ",0,"; then
            local clients=
            clients=$(initXrayClients 0 "${uuid}" "${email}")
            clients=$(jq -r "${userConfig} = ${clients}" ${configPath}02_VLESS_TCP_inbounds.json)
            echo "${clients}" | jq . >${configPath}02_VLESS_TCP_inbounds.json
        fi

        # VLESS WS
        if echo "${currentInstallProtocolType}" | grep -q ",1,"; then
            local clients=
            clients=$(initXrayClients 1 "${uuid}" "${email}")
            clients=$(jq -r "${userConfig} = ${clients}" ${configPath}03_VLESS_WS_inbounds.json)
            echo "${clients}" | jq . >${configPath}03_VLESS_WS_inbounds.json
        fi

        # vless reality vision
        if echo "${currentInstallProtocolType}" | grep -q ",3,"; then
            local clients=
            clients=$(initXrayClients 3 "${uuid}" "${email}") || return 1
            clients=$(jq -r "${userConfig} = ${clients}" ${configPath}07_VLESS_vision_reality_inbounds.json)
            echo "${clients}" | jq . >${configPath}07_VLESS_vision_reality_inbounds.json
        fi

        # Hysteria2 使用同一个 UUID 作为认证密码
        if echo "${currentInstallProtocolType}" | grep -q ",6,"; then
            local hysteria2Config=
            hysteria2Config=$(jq --arg auth "${uuid}" --arg email "${email}-Hysteria2" '
                if .inbounds[0].settings.clients != null then
                    .inbounds[0].settings.clients += [{auth: $auth, level: 0, email: $email}]
                else
                    .inbounds[0].settings.users += [{auth: $auth, level: 0, email: $email}]
                end
            ' "${configPath}05_hysteria2_inbounds.json")
            echo "${hysteria2Config}" | jq . >"${configPath}05_hysteria2_inbounds.json"
        fi

    done
    handleXray stop
    handleXray start
    echoContent green " ---> 添加完成"
    subscribe false
    manageAccount 1
}
# 移除用户
removeUser() {
    local sourceConfig= candidateConfig userCount delUserIndex userId temporaryConfig
    local -a preferredConfigs=(
        "02_VLESS_TCP_inbounds.json" "03_VLESS_WS_inbounds.json"
        "07_VLESS_vision_reality_inbounds.json" "05_hysteria2_inbounds.json"
    )

    for candidateConfig in "${preferredConfigs[@]}"; do
        candidateConfig="${configPath}${candidateConfig}"
        [[ -f "${candidateConfig}" ]] || continue
        userCount=$(jq -r '(.inbounds[0].settings.clients // .inbounds[0].settings.users // .inbounds[0].users // []) | length' "${candidateConfig}" 2>/dev/null)
        if [[ "${userCount}" =~ ^[0-9]+$ && ${userCount} -gt 0 ]]; then
            sourceConfig="${candidateConfig}"
            break
        fi
    done

    if [[ -z "${sourceConfig}" ]]; then
        echoContent red " ---> 未找到可删除的用户"
        return 1
    fi

    jq -r '(.inbounds[0].settings.clients // .inbounds[0].settings.users // .inbounds[0].users // [])[] | (.email // .name // .username // "unnamed")' "${sourceConfig}" | awk '{print NR":"$0}'
    read -r -p "请选择要删除的用户编号[仅支持单个删除]:" delUserIndex
    if [[ ! "${delUserIndex}" =~ ^[0-9]+$ || ${delUserIndex} -lt 1 || ${delUserIndex} -gt ${userCount} ]]; then
        echoContent red " ---> 选择错误"
        return 1
    fi

    userId=$(jq -r --argjson index "$((delUserIndex - 1))" '(.inbounds[0].settings.clients // .inbounds[0].settings.users // .inbounds[0].users // [])[$index] | (.id // .uuid // .auth // .password // empty)' "${sourceConfig}")
    if [[ -z "${userId}" ]]; then
        echoContent red " ---> 无法识别该用户的 UUID/auth，未修改配置"
        return 1
    fi

    while IFS= read -r candidateConfig; do
        if ! jq -e --arg userId "${userId}" '
            any((.inbounds[]?.settings.clients[]?, .inbounds[]?.settings.users[]?, .inbounds[]?.users[]?);
                (.id // .uuid // .auth // .password // "") == $userId)
        ' "${candidateConfig}" >/dev/null 2>&1; then
            continue
        fi

        temporaryConfig=$(mktemp "${candidateConfig}.tmp.XXXXXX") || return 1
        if jq --arg userId "${userId}" '
            (.inbounds[]? | select(.settings.clients? != null).settings.clients) |= map(select((.id // .uuid // .auth // .password // "") != $userId)) |
            (.inbounds[]? | select(.settings.users? != null).settings.users) |= map(select((.id // .uuid // .auth // .password // "") != $userId)) |
            (.inbounds[]? | select(.users? != null).users) |= map(select((.id // .uuid // .auth // .password // "") != $userId))
        ' "${candidateConfig}" >"${temporaryConfig}"; then
            chmod --reference="${candidateConfig}" "${temporaryConfig}" 2>/dev/null || chmod 600 "${temporaryConfig}"
            mv -f "${temporaryConfig}" "${candidateConfig}"
        else
            rm -f "${temporaryConfig}"
            echoContent red " ---> 更新配置失败: ${candidateConfig}"
            return 1
        fi
    done < <(find "${configPath}" -maxdepth 1 -type f -name '*inbounds.json' 2>/dev/null)

    handleXray stop
    handleXray start
    manageAccount 1
}
# 更新脚本
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
    if ! downloadFile "${scriptUrl}" "${temporaryScript}"; then
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

# 防火墙
handleFirewall() {
    if systemctl status ufw 2>/dev/null | grep -q "active (exited)" && [[ "$1" == "stop" ]]; then
        systemctl stop ufw >/dev/null 2>&1
        systemctl disable ufw >/dev/null 2>&1
        echoContent green " ---> ufw关闭成功"

    fi

    if systemctl status firewalld 2>/dev/null | grep -q "active (running)" && [[ "$1" == "stop" ]]; then
        systemctl stop firewalld >/dev/null 2>&1
        systemctl disable firewalld >/dev/null 2>&1
        echoContent green " ---> firewalld关闭成功"
    fi
}

# 查看、检查日志
checkLog() {
    if [[ -z "${configPath}" && -z "${realityStatus}" ]]; then
        echoContent red " ---> 没有检测到安装目录，请执行脚本安装内容"
        exit 0
    fi
    local realityLogShow=
    local logStatus=false
    if grep -q "access" ${configPath}00_log.json; then
        logStatus=true
    fi

    echoContent skyBlue "\n功能 $1/${totalProgress} : 查看日志"
    echoContent red "\n=============================================================="
    echoContent yellow "# 建议仅调试时打开access日志\n"

    if [[ "${logStatus}" == "false" ]]; then
        echoContent yellow "1.打开access日志"
    else
        echoContent yellow "1.关闭access日志"
    fi

    echoContent yellow "2.监听access日志"
    echoContent yellow "3.监听error日志"
    echoContent yellow "4.查看证书定时任务日志"
    echoContent yellow "5.查看证书安装日志"
    echoContent yellow "6.清空日志"
    echoContent red "=============================================================="

    read -r -p "请选择:" selectAccessLogType
    local configPathLog=${configPath//conf\//}

    case ${selectAccessLogType} in
    1)
        if [[ "${logStatus}" == "false" ]]; then
            realityLogShow=true
            cat <<EOF >${configPath}00_log.json
{
  "log": {
  	"access":"${configPathLog}access.log",
    "error": "${configPathLog}error.log",
    "loglevel": "debug"
  }
}
EOF
        elif [[ "${logStatus}" == "true" ]]; then
            realityLogShow=false
            cat <<EOF >${configPath}00_log.json
{
  "log": {
    "error": "${configPathLog}error.log",
    "loglevel": "warning"
  }
}
EOF
        fi

        if [[ -n ${realityStatus} ]]; then
            local vlessVisionRealityInbounds
            vlessVisionRealityInbounds=$(jq -r ".inbounds[0].streamSettings.realitySettings.show=${realityLogShow}" ${configPath}07_VLESS_vision_reality_inbounds.json)
            echo "${vlessVisionRealityInbounds}" | jq . >${configPath}07_VLESS_vision_reality_inbounds.json
        fi
        handleXray stop
        handleXray start
        checkLog 1
        ;;
    2)
        tail -f ${configPathLog}access.log
        ;;
    3)
        tail -f ${configPathLog}error.log
        ;;
    4)
        if [[ ! -f "/opt/xray-agent/crontab_tls.log" ]]; then
            touch /opt/xray-agent/crontab_tls.log
        fi
        tail -n 100 /opt/xray-agent/crontab_tls.log
        ;;
    5)
        tail -n 100 /opt/xray-agent/tls/acme.log
        ;;
    6)
        echo >${configPathLog}access.log
        echo >${configPathLog}error.log
        ;;
    esac
}

# 脚本快捷方式
aliasInstall() {
    # 获取当前脚本的实际路径
    local currentScript
    currentScript="$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")"
    
    # 确保目标目录存在
    if [[ ! -d "/opt/xray-agent" ]]; then
        mkdir -p /opt/xray-agent
    fi
    
    # 只在首次安装或文件不存在时复制
    local targetScript="/opt/xray-agent/install.sh"
    local needCopy=false
    
    if [[ ! -f "$targetScript" ]]; then
        needCopy=true
    elif [[ "$currentScript" != "$targetScript" ]]; then
        # 如果当前脚本不是目标位置，则需要复制（更新场景）
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

    # 检查并创建软连接
    local xrayaType=false
    local symlinkPath=""
    
    if [[ -d "/usr/bin/" ]]; then
        symlinkPath="/usr/bin/xraya"
    elif [[ -d "/usr/sbin" ]]; then
        symlinkPath="/usr/sbin/xraya"
    fi
    
    if [[ -n "$symlinkPath" ]]; then
        # 检查软连接是否已存在且正确
        if [[ -L "$symlinkPath" ]] && [[ "$(readlink "$symlinkPath")" == "$targetScript" ]]; then
            # 软连接已存在且正确，无需重新创建
            xrayaType=true
        else
            # 删除旧的软连接或文件
            rm -f "$symlinkPath"
            
            # 创建新的软连接
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
