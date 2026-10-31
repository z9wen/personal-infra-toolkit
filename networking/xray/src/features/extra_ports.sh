# Extra ports are dokodemo-door inbounds that forward to the main TLS port.
# Files: 02_dokodemodoor_inbounds_<port>[_default].json, plus
# 02_dokodemodoor_inbounds_hysteria_<port>.json when Hysteria2 is installed.
# The _default marker selects the port used in shared links/subscriptions.

# Print "<port> <file>" for every extra TCP port, sorted by port.
listCorePorts() {
    local file name port
    for file in "${configPath}"02_dokodemodoor_inbounds_*.json; do
        [[ -f "${file}" ]] || continue
        name=${file##*/}
        [[ "${name}" =~ ^02_dokodemodoor_inbounds_([0-9]+)(_default)?\.json$ ]] || continue
        port=${BASH_REMATCH[1]}
        echo "${port} ${file}"
    done | sort -n
}

# Remove exactly the files that belong to one extra port.
removeCorePortFiles() {
    local port=$1
    rm -f "${configPath}02_dokodemodoor_inbounds_${port}.json" \
        "${configPath}02_dokodemodoor_inbounds_${port}_default.json" \
        "${configPath}02_dokodemodoor_inbounds_hysteria_${port}.json"
}

writeCorePortFiles() {
    local port=$1 isDefault=$2 settingsPort=${customPort:-443} fileName
    fileName="${configPath}02_dokodemodoor_inbounds_${port}.json"
    [[ "${isDefault}" == "true" ]] && fileName="${configPath}02_dokodemodoor_inbounds_${port}_default.json"

    jq -n --argjson port "${port}" --argjson target "${settingsPort}" '{inbounds:[{
        listen:"0.0.0.0", port:$port, protocol:"dokodemo-door",
        settings:{address:"127.0.0.1", port:$target, network:"tcp", followRedirect:false},
        tag:("dokodemo-door-newPort-" + ($port | tostring))
    }]}' >"${fileName}" || return 1

    if [[ -n "${hysteria2Port}" ]]; then
        jq -n --argjson port "${port}" --argjson target "${hysteria2Port}" '{inbounds:[{
            listen:"0.0.0.0", port:$port, protocol:"dokodemo-door",
            settings:{address:"127.0.0.1", port:$target, network:"udp", followRedirect:false},
            tag:("dokodemo-door-newPort-hysteria-" + ($port | tostring))
        }]}' >"${configPath}02_dokodemodoor_inbounds_hysteria_${port}.json" || return 1
    fi
}

# Add the given ports; with a default port, move the _default marker to it.
applyCorePorts() {
    local defaultPort=$1 port existing file
    shift
    if [[ -n "${defaultPort}" ]]; then
        # Demote the previous default port instead of deleting it.
        for file in "${configPath}"02_dokodemodoor_inbounds_*_default.json; do
            [[ -f "${file}" ]] && mv "${file}" "${file%_default.json}.json"
        done
    fi
    for port in "$@"; do
        removeCorePortFiles "${port}"
        writeCorePortFiles "${port}" "$([[ "${port}" == "${defaultPort}" ]] && echo true || echo false)" || return 1
    done
}

# Parse "2053,2083 ,2087" into a validated, de-duplicated list in corePortList.
# Empty items (e.g. a trailing comma) are ignored; any invalid item fails.
parseCorePortList() {
    local input=${1//，/,} item
    local -a items=()
    corePortList=()
    IFS=',' read -r -a items <<<"${input}"
    for item in "${items[@]}"; do
        item=${item//[[:space:]]/}
        [[ -z "${item}" ]] && continue
        if ! isValidPort "${item}"; then
            echoContent red " ---> 端口无效: ${item}（需为 1-65535 的数字）"
            return 1
        fi
        [[ " ${corePortList[*]:-} " == *" ${item} "* ]] || corePortList+=("${item}")
    done
    ((${#corePortList[@]} > 0)) || {
        echoContent red " ---> 未输入任何端口"
        return 1
    }
}

# Add a new port
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
    local selectNewPortType newPort defaultPort portIndex selected port
    read -r -p "请选择:" selectNewPortType
    case "${selectNewPortType}" in
        1)
            listCorePorts | awk '{print NR ":" $1}'
            ;;
        2)
            read -r -p "请输入端口号:" newPort
            parseCorePortList "${newPort}" || return 1
            read -r -p "请输入默认的端口号，同时会更改订阅端口以及节点端口，[回车]默认443:" defaultPort
            defaultPort=${defaultPort//[[:space:]]/}
            if [[ -n "${defaultPort}" && " ${corePortList[*]} " != *" ${defaultPort} "* ]]; then
                echoContent red " ---> 默认端口必须是本次输入的端口之一"
                return 1
            fi

            for port in "${corePortList[@]}"; do
                allowPort "${port}"
                allowPort "${port}" "udp"
            done
            applyXrayConfigChange "添加端口" applyCorePorts "${defaultPort}" "${corePortList[@]}" || return 1
            echoContent green " ---> 添加完毕"
            restartXray || return 1
            ;;
        3)
            listCorePorts | awk '{print NR ":" $1}'
            read -r -p "请输入要删除的端口编号:" portIndex
            if [[ "${portIndex}" =~ ^[1-9][0-9]*$ ]]; then
                selected=$(listCorePorts | awk -v n="${portIndex}" 'NR == n {print $1}')
            fi
            if [[ -z "${selected}" ]]; then
                echoContent yellow "\n ---> 编号输入错误，请重新选择"
                return 1
            fi
            applyXrayConfigChange "删除端口" removeCorePortFiles "${selected}" || return 1
            echoContent green " ---> 端口 ${selected} 已删除"
            restartXray || return 1
            ;;
        *)
            echoContent red " ---> 选择错误"
            ;;
    esac
}
