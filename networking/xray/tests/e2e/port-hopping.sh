#!/usr/bin/env bash
#
# Runs INSIDE a privileged throwaway container (see run.sh). The installer
# enables Hysteria2 port hopping with real nftables; a client in a separate
# network namespace (so its packets traverse PREROUTING) connects through a
# port inside the range, and a hopping client keeps working while conntrack
# shows it really used several ports.
#
# Usage: port-hopping.sh <server-version> <client-version>...

# Globals are shared with the sourced modules, which ShellCheck cannot see.
# shellcheck disable=SC1090,SC2034

SERVER=$1
shift
apt-get update -qq >/dev/null && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    nftables iproute2 conntrack jq curl openssl ca-certificates procps >/dev/null 2>&1
mkdir -p /opt/xray-agent/xray/conf /opt/xray-agent/tls
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 30 -subj "/CN=example.com" \
    -addext "subjectAltName=DNS:example.com" -keyout /opt/xray-agent/tls/example.com.key -out /opt/xray-agent/tls/example.com.crt >/dev/null 2>&1
cp /bins/linux-${SERVER}/xray /opt/xray-agent/xray/xray
for m in /src/[01][0-9]_*.sh; do source "$m" >/dev/null 2>&1; done
initVar "" >/dev/null 2>&1
echoContent() { :; }
checkPort() { :; }
allowPort() { :; }
domain=example.com currentHost=example.com port=443 customPath=abc totalProgress=1
selectCustomInstallType=",0,6,"
configPath=/opt/xray-agent/xray/conf/
# The install questions are covered by tests/test_port_hopping.sh; here the
# answers are fixed: Hysteria2 on 8443 with hopping over 20000-50000.
initHysteria2Port() {
    hysteria2Port=8443
    hysteria2PortHopRange=20000-50000
}
yes "" | head -300 >/tmp/answers
(initXrayConfig custom 1 </tmp/answers) >/tmp/init.log 2>&1
hysteria2Port=$(jq -r '.inbounds[0].port' ${configPath}05_hysteria2_inbounds.json)
echo "hysteria2 port: ${hysteria2Port}"
hysteria2PortHopRange=20000-50000
syncPortHopping >/tmp/sync.log 2>&1 || {
    echo "syncPortHopping failed"
    cat /tmp/sync.log
}
# nft prints the counter values inside the rule.
nft list table inet xray_agent_port_hopping | grep -qE "udp dport 20000-50000 counter packets [0-9]+ bytes [0-9]+ redirect to :${hysteria2Port}" \
    && echo "nft rule: installed" || echo "nft rule: FAILED"

# Share link and subscriptions carry the range in each client's format.
mkdir -p /opt/xray-agent/subscribe_local/default /opt/xray-agent/subscribe_local/clashMeta /opt/xray-agent/subscribe_local/sing-box
defaultBase64Code hysteria "${hysteria2Port}" alice-Hysteria2 secret >/dev/null 2>&1
grep -q "@example.com:${hysteria2Port}/?.*&mport=20000-50000" /opt/xray-agent/subscribe_local/default/alice \
    && echo "share link (v2rayN mport): ok" || echo "share link (v2rayN mport): FAILED"
grep -q "ports: 20000-50000" /opt/xray-agent/subscribe_local/clashMeta/alice && grep -q "hop-interval: 30" /opt/xray-agent/subscribe_local/clashMeta/alice \
    && echo "Clash Meta ports/hop-interval: ok" || echo "Clash Meta ports/hop-interval: FAILED"
jq -e '.[0].server_ports == ["20000:50000"] and .[0].hop_interval == "30s"' /opt/xray-agent/subscribe_local/sing-box/alice >/dev/null \
    && echo "sing-box server_ports/hop_interval: ok" || echo "sing-box server_ports/hop_interval: FAILED"

# Client network namespace connected to the server over a veth pair.
ip netns add c
ip link add veth0 type veth peer name veth1
ip link set veth1 netns c
ip addr add 10.9.0.1/24 dev veth0 && ip link set veth0 up
ip netns exec c ip addr add 10.9.0.2/24 dev veth1
ip netns exec c ip link set veth1 up
ip netns exec c ip link set lo up

UUID=$(jq -r '.inbounds[0].settings.clients[0].auth' ${configPath}05_hysteria2_inbounds.json)
/opt/xray-agent/xray/xray run -confdir ${configPath} >/tmp/server.log 2>&1 &
sleep 3

client() { # name version port hop-json
    jq -n --arg id "$UUID" --argjson port "$3" --argjson hop "$4" '{
        inbounds:[{listen:"127.0.0.1",port:21080,protocol:"socks",settings:{udp:true}}],
        outbounds:[{protocol:"hysteria",settings:{version:2,address:"10.9.0.1",port:$port},
          streamSettings:({network:"hysteria",security:"tls",
            tlsSettings:{serverName:"example.com",alpn:["h3"],certificates:[{usage:"verify",certificateFile:"/opt/xray-agent/tls/example.com.crt"}]},
            hysteriaSettings:{version:2,auth:$id}} + $hop)}]}' >/tmp/client.json
    conntrack -D -p udp >/dev/null 2>&1
    ip netns exec c /bins/linux-$2/xray run -c /tmp/client.json >/tmp/client.log 2>&1 &
    local c=$! ok=0 total=0 i code ports
    sleep 1.5
    for i in $(seq 1 ${5:-1}); do
        total=$((total + 1))
        code=$(ip netns exec c curl -s -o /dev/null -w '%{http_code}' --max-time 8 -x socks5h://127.0.0.1:21080 http://1.1.1.1/cdn-cgi/trace)
        [[ $code =~ ^(200|301)$ ]] && ok=$((ok + 1))
        ((${5:-1} > 1)) && sleep 1
    done
    ports=$(conntrack -L -p udp --orig-src 10.9.0.2 2>/dev/null | grep -oE 'dport=[0-9]+' | sort -u | grep -v "dport=${hysteria2Port}$" | wc -l)
    printf "  %-52s %s\n" "$1" "$([[ $ok == "$total" ]] && echo "works ($ok/$total requests, $ports distinct range ports)" || echo "FAILED ($ok/$total)")"
    kill $c 2>/dev/null
    wait $c 2>/dev/null
}
for v in "$@"; do
    echo "== server Xray ${SERVER}, client Xray ${v}"
    client "direct to the real port ${hysteria2Port}" "$v" "${hysteria2Port}" '{}'
    client "single port inside the range (33333)" "$v" 33333 '{}'
    if xrayVersionAtLeast "$v" v26.9.8; then
        hop='{"finalmask":{"udp":[{"type":"udphop","settings":{"mode":"intervalRemote","interval":"5","remotePorts":"20000-50000"}}]}}'
    else
        hop='{"finalmask":{"quicParams":{"udpHop":{"ports":"20000-50000","interval":"5"}}}}'
    fi
    client "hopping every 5s for ~20s" "$v" 33333 "$hop" 15
done
echo "redirected packets: $(nft list table inet xray_agent_port_hopping | grep -oE 'packets [0-9]+')"
