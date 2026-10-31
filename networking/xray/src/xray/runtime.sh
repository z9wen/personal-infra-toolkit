# Verify that the whole service is working
checkGFWStatue() {
    readInstallType
    echoContent skyBlue "\n进度 $1/${totalProgress} : 验证服务启动状态"
    if [[ "${coreInstallType}" == "1" ]] && [[ -n $(pgrep -f "xray/xray") ]]; then
        echoContent green " ---> 服务启动成功"
    else
        echoContent red " ---> 服务启动失败，请检查终端是否有日志打印"
        exit 0
    fi
}

# Enable Xray start on boot
installXrayService() {
    echoContent skyBlue "\n进度  $1/${totalProgress} : 配置Xray开机自启"
    execStart='/opt/xray-agent/xray/xray run -confdir /opt/xray-agent/xray/conf'
    if [[ -n $(find /bin /usr/bin -name "systemctl") ]]; then
        rm -rf /etc/systemd/system/xray.service
        touch /etc/systemd/system/xray.service
        cat <<EOF >/etc/systemd/system/xray.service
[Unit]
Description=Xray Service
Documentation=https://github.com/xtls
After=network.target nss-lookup.target
[Service]
User=root
ExecStart=${execStart}
Restart=on-failure
RestartPreventExitStatus=23
LimitNPROC=infinity
LimitNOFILE=infinity
[Install]
WantedBy=multi-user.target
EOF
        bootStartup "xray.service"
        echoContent green " ---> 配置Xray开机自启成功"
    fi
}

# Manage xray
handleXray() {
    if [[ -n $(find /bin /usr/bin -name "systemctl") ]] && [[ -n $(find /etc/systemd/system/ -name "xray.service") ]]; then
        if [[ -z $(pgrep -f "xray/xray") ]] && [[ "$1" == "start" ]]; then
            systemctl start xray.service
        elif [[ -n $(pgrep -f "xray/xray") ]] && [[ "$1" == "stop" ]]; then
            systemctl stop xray.service
        fi
    fi

    sleep 0.8

    if [[ "$1" == "start" ]]; then
        if [[ -n $(pgrep -f "xray/xray") ]]; then
            echoContent green " ---> Xray启动成功"
        else
            echoContent red "Xray启动失败"
            echoContent red "请手动执行以下的命令后【/opt/xray-agent/xray/xray -confdir /opt/xray-agent/xray/conf】将错误日志进行反馈"
            return 1
        fi
    elif [[ "$1" == "stop" ]]; then
        if [[ -z $(pgrep -f "xray/xray") ]]; then
            echoContent green " ---> Xray关闭成功"
        else
            echoContent red "xray关闭失败"
            echoContent red "请手动执行【ps -ef|grep -v grep|grep xray|awk '{print \$2}'|xargs kill -9】"
            return 1
        fi
    fi
}

xraySystemdServiceAvailable() {
    command -v systemctl >/dev/null 2>&1 && [[ -f /etc/systemd/system/xray.service ]]
}

# Restart Xray through systemd in one step, so the script cannot exit between
# a successful stop and the start.
#
# Success requires the service to stay up for several consecutive checks
# without systemd restarting it; with Restart=on-failure a crash-looping
# Xray is briefly "active" between crashes and would otherwise pass.
restartXray() {
    local stableChecks=0 restartsBefore restartsNow
    if xraySystemdServiceAvailable; then
        if ! systemctl restart xray.service; then
            echoContent yellow " ---> Xray 重启失败，正在尝试重新启动"
            systemctl start xray.service || {
                echoContent red " ---> Xray 服务无法启动"
                return 1
            }
        fi

        restartsBefore=$(systemctl show -p NRestarts --value xray.service 2>/dev/null)
        for _ in 1 2 3 4 5 6 7 8 9 10; do
            sleep 0.5
            restartsNow=$(systemctl show -p NRestarts --value xray.service 2>/dev/null)
            if systemctl is-active --quiet xray.service && pgrep -f "xray/xray" >/dev/null \
                && [[ "${restartsNow}" == "${restartsBefore}" ]]; then
                stableChecks=$((stableChecks + 1))
                if ((stableChecks >= 3)); then
                    echoContent green " ---> Xray重启成功"
                    return 0
                fi
            else
                stableChecks=0
                restartsBefore=${restartsNow}
            fi
        done
        echoContent red " ---> Xray重启后未保持运行"
        echoContent yellow " ---> 请执行【journalctl -u xray.service -n 50 --no-pager】查看错误"
        return 1
    fi

    handleXray stop || return 1
    handleXray start
}

xrayBinary=/opt/xray-agent/xray/xray

# Validate the complete config directory the way the service will load it.
validateXrayConfig() {
    "${xrayBinary}" run -test -confdir "${configPath}"
}

# Apply a change to the Xray configuration as one transaction.
#
# The config directory (and the relay state, which lives outside it) is
# snapshotted, the change command runs, and the result is validated with
# `xray run -test`. If the command or the validation fails, the snapshot is
# restored exactly, including removing files the change created. Restarting
# Xray is left to the caller so several changes can share one restart.
#
# Usage: applyXrayConfigChange <description> <command> [args...]
applyXrayConfigChange() {
    local description=$1 snapshot validationOutput=""
    shift
    snapshot=$(mktemp -d /tmp/xray-config-snapshot.XXXXXX) || return 1
    if ! cp -Rp "${configPath}." "${snapshot}/conf"; then
        rm -rf "${snapshot}"
        return 1
    fi
    if [[ -n "${relayStateFile:-}" && -f "${relayStateFile}" ]]; then
        cp -p "${relayStateFile}" "${snapshot}/relay_state.json"
    fi

    if "$@" && validationOutput=$(validateXrayConfig 2>&1); then
        rm -rf "${snapshot}"
        return 0
    fi

    find "${configPath}" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
    cp -Rp "${snapshot}/conf/." "${configPath}"
    if [[ -f "${snapshot}/relay_state.json" ]]; then
        cp -p "${snapshot}/relay_state.json" "${relayStateFile}"
    fi
    echoContent red " ---> ${description}失败，已恢复上一版配置"
    [[ -n "${validationOutput}" ]] && echoContent yellow "${validationOutput}"
    rm -rf "${snapshot}"
    return 1
}

# View and check logs
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
            restartXray || return 1
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
