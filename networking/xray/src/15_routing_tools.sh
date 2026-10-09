# ==================== Routing tools ====================

# Routing tools
routingToolsMenu() {
    echoContent skyBlue "\n功能 1/${totalProgress} : 分流工具"
    echoContent red "\n=============================================================="
    echoContent yellow "# 注意事项"
    echoContent yellow "# 用于服务端的流量分流，可用于解锁ChatGPT、流媒体等相关内容\n"

    echoContent yellow "1.WARP分流【第三方 IPv4】"
    echoContent yellow "2.WARP分流【第三方 IPv6】"
    echoContent yellow "3.IPv6分流"
    echoContent yellow "4.Socks5分流【替换任意门分流】"
    echoContent yellow "5.DNS分流"
    echoContent yellow "6.SNI反向代理分流"

    read -r -p "请选择:" selectType

    case ${selectType} in
        1)
            warpRoutingReg 1 IPv4
            ;;
        2)
            warpRoutingReg 1 IPv6
            ;;
        3)
            ipv6Routing 1
            ;;
        4)
            socks5Routing
            ;;
        5)
            dnsRouting 1
            ;;
        6)
            sniRouting 1
            ;;
    esac

}
# SNI reverse proxy split routing
sniRouting() {

    if [[ -z "${configPath}" ]]; then
        echoContent red " ---> 未安装，请使用脚本安装"
        menu
        exit 0
    fi
    echoContent skyBlue "\n功能 1/${totalProgress} : SNI反向代理分流"
    echoContent red "\n=============================================================="
    echoContent yellow "# 注意事项\n"

    echoContent yellow "1.添加"
    echoContent yellow "2.卸载"
    read -r -p "请选择:" selectType

    case ${selectType} in
        1)
            setUnlockSNI
            ;;
        2)
            removeUnlockSNI
            ;;
    esac
}
# Set up SNI split routing
setUnlockSNI() {
    read -r -p "请输入分流的SNI IP:" setSNIP
    if [[ -n ${setSNIP} ]]; then
        echoContent red "=============================================================="
        echoContent yellow "录入示例:netflix,disney,hulu"
        read -r -p "请按照上面示例录入域名:" domainList

        if [[ -n "${domainList}" ]]; then
            local hosts={}
            while read -r domain; do
                hosts=$(echo "${hosts}" | jq -r ".\"geosite:${domain}\"=\"${setSNIP}\"")
            done < <(echo "${domainList}" | tr ',' '\n')
            cat <<EOF >${configPath}11_dns.json
{
    "dns": {
        "hosts":${hosts},
        "servers": [
            "8.8.8.8",
            "1.1.1.1"
        ]
    }
}
EOF
            echoContent red " ---> SNI反向代理分流成功"
            restartXray || return 1
        else
            echoContent red " ---> 域名不可为空"
        fi

    else

        echoContent red " ---> SNI IP不可为空"
    fi
    exit 0
}

# Remove SNI split routing
removeUnlockSNI() {
    cat <<EOF >${configPath}11_dns.json
{
	"dns": {
		"servers": [
			"localhost"
		]
	}
}
EOF
    restartXray || return 1

    echoContent green " ---> 卸载成功"

    exit 0
}
