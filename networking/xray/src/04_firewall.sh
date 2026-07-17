# 检查防火墙
allowPort() {
    local type=$2
    if [[ -z "${type}" ]]; then
        type=tcp
    fi
    
    # 只有 UFW 确实启用时才由它处理；仅安装但未启用时继续检查其他防火墙。
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
        if ! ufw status | grep -q "$1/${type}"; then
            ufw allow "$1/${type}"
            checkUFWAllowPort "$1"
        fi
        return
    fi
    
    # 检查 firewalld
    if systemctl status firewalld 2>/dev/null | grep -q "active (running)"; then
        local updateFirewalldStatus=
        if ! firewall-cmd --list-ports --permanent | grep -qw "$1/${type}"; then
            updateFirewalldStatus=true
            local firewallPort=$1
            if echo "${firewallPort}" | grep -q ":"; then
                firewallPort=$(echo "${firewallPort}" | awk -F ":" '{print $1"-"$2}')
            fi
            firewall-cmd --zone=public --add-port="${firewallPort}/${type}" --permanent
            checkFirewalldAllowPort "${firewallPort}"
        fi

        if echo "${updateFirewalldStatus}" | grep -q "true"; then
            firewall-cmd --reload
        fi
        return
    fi
    
    # 最后检查 iptables (仅当没有其他防火墙时)
    if dpkg -l 2>/dev/null | grep -q "^[[:space:]]*ii[[:space:]]\+netfilter-persistent"; then
        if systemctl status netfilter-persistent 2>/dev/null | grep -q "active (exited)"; then
            local updateNetfilterStatus=
            if ! iptables -C INPUT -p "${type}" --dport "$1" -j ACCEPT >/dev/null 2>&1; then
                updateNetfilterStatus=true
                iptables -I INPUT -p "${type}" --dport "$1" -m comment --comment "allow $1/${type}(z9)" -j ACCEPT
            fi

            if command -v ip6tables >/dev/null 2>&1 && ! ip6tables -C INPUT -p "${type}" --dport "$1" -j ACCEPT >/dev/null 2>&1; then
                updateNetfilterStatus=true
                ip6tables -I INPUT -p "${type}" --dport "$1" -m comment --comment "allow $1/${type}(z9)" -j ACCEPT
            fi

            if [[ "${updateNetfilterStatus}" == "true" ]]; then
                netfilter-persistent save
            fi
        fi
    fi
}
# 获取公网IP
getPublicIP() {
    local type=4
    if [[ -n "$1" ]]; then
        type=$1
    fi
    if [[ -n "${currentHost}" && -z "$1" ]] && [[ "${xrayVLESSRealityServerName}" == "${currentHost}" ]]; then
        echo "${currentHost}"
    else
        local currentIP=
        currentIP=$(curl -s "-${type}" http://www.cloudflare.com/cdn-cgi/trace | grep "ip" | awk -F "[=]" '{print $2}')
        if [[ -z "${currentIP}" && -z "$1" ]]; then
            currentIP=$(curl -s "-6" http://www.cloudflare.com/cdn-cgi/trace | grep "ip" | awk -F "[=]" '{print $2}')
        fi
        echo "${currentIP}"
    fi

}

# 输出ufw端口开放状态
checkUFWAllowPort() {
    if ufw status | grep -q "$1"; then
        echoContent green " ---> $1端口开放成功"
    else
        echoContent red " ---> $1端口开放失败"
        exit 0
    fi
}

# 输出firewall-cmd端口开放状态
checkFirewalldAllowPort() {
    if firewall-cmd --list-ports --permanent | grep -q "$1"; then
        echoContent green " ---> $1端口开放成功"
    else
        echoContent red " ---> $1端口开放失败"
        exit 0
    fi
}

