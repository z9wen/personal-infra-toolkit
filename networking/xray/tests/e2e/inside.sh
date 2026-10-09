#!/usr/bin/env bash
#
# Runs INSIDE a throwaway Debian container (see run.sh). The installer's own
# functions generate every config with one Xray version, real nginx serves
# the fallback and a fake aaPanel site, and real Xray clients connect through
# each protocol, served by every given version.
#
# Usage: inside.sh <generator-version> <server-version>...

# Globals are shared with the sourced modules, which ShellCheck cannot see.
# shellcheck disable=SC1090,SC2034

GEN=$1
shift
apt-get update -qq >/dev/null && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nginx jq openssl curl ca-certificates procps iproute2 >/dev/null 2>&1
mkdir -p /opt/xray-agent/xray/conf /opt/xray-agent/tls /opt/xray-agent/subscribe_local/{default,clashMeta,sing-box} /var/www/html
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 30 -subj "/CN=example.com" \
    -addext "subjectAltName=DNS:example.com" -keyout /opt/xray-agent/tls/example.com.key -out /opt/xray-agent/tls/example.com.crt >/dev/null 2>&1
echo "127.0.0.1 example.com" >>/etc/hosts
cp /bins/linux-${GEN}/xray /opt/xray-agent/xray/xray
for m in /src/[01][0-9]_*.sh; do source "$m" >/dev/null 2>&1; done
initVar "" >/dev/null 2>&1
checkCPUVendor >/dev/null 2>&1

echoContent() { :; }
checkPort() { :; }
allowPort() { :; }
initRealityClientServersName() {
    realityServerName=addons.mozilla.org
    realityDomainPort=443
}
domain=example.com
currentHost=example.com
port=443
customPath=abc
totalProgress=1
selectCustomInstallType=",0,14,3,6,12,"
configPath=/opt/xray-agent/xray/conf/
nginxConfigPath=/etc/nginx/conf.d/
nginxStaticPath=/var/www/html/
yes "" | head -500 >/tmp/answers
(initXrayConfig custom 1 </tmp/answers) >/tmp/init.log 2>&1 || {
    echo "initXrayConfig failed"
    tail -5 /tmp/init.log
}
updateRedirectNginxConf >/tmp/nginx-gen.log 2>&1 || {
    echo "updateRedirectNginxConf failed"
    cat /tmp/nginx-gen.log
}
rm -f /etc/nginx/sites-enabled/default

# A fake aaPanel site that owns "443" (127.0.0.1:8443 here) and includes its rewrite file.
mkdir -p /pv/nginx /pv/rewrite
cat >/pv/nginx/example.com.conf <<NGX
server {
    listen 127.0.0.1:8443 ssl http2;
    server_name example.com;
    ssl_certificate /opt/xray-agent/tls/example.com.crt;
    ssl_certificate_key /opt/xray-agent/tls/example.com.key;
    include /pv/rewrite/example.com.conf;
    location ~ .*\.(js|css)?$ { expires 12h; }
    location / { return 200 "panel site\n"; }
}
NGX
echo 'location /robots.txt { return 200 "user rule\n"; }' >/pv/rewrite/example.com.conf
ln -s /pv/nginx/example.com.conf /etc/nginx/conf.d/panel-site.conf
nginx -t >/tmp/nginx-test.log 2>&1 || {
    echo "nginx -t failed"
    cat /tmp/nginx-test.log
}
nginx
panelVhostRoot=/pv btDomain=example.com syncPanelXhttpLocation install >/tmp/panel.log 2>&1 || {
    echo "panel sync failed"
    cat /tmp/panel.log
}
echo "configs: $(ls /opt/xray-agent/xray/conf | tr '\n' ' ')"

UUID=$(jq -r '.inbounds[0].settings.clients[0].id' ${configPath}02_VLESS_TCP_inbounds.json)
PATHX=$(jq -r '.inbounds[0].streamSettings.xhttpSettings.path' ${configPath}14_VLESS_XHTTP_TLS_inbounds.json)
RPORT=$(jq -r '.inbounds[0].port' ${configPath}07_VLESS_vision_reality_inbounds.json)
XRPORT=$(jq -r '.inbounds[0].port' ${configPath}12_VLESS_XHTTP_inbounds.json)
HPORT=$(jq -r '.inbounds[0].port' ${configPath}05_hysteria2_inbounds.json)
PUB=$(jq -r '.inbounds[0].streamSettings.realitySettings.publicKey' ${configPath}07_VLESS_vision_reality_inbounds.json)
PUB12=$(jq -r '.inbounds[0].streamSettings.realitySettings.publicKey' ${configPath}12_VLESS_XHTTP_inbounds.json)
[[ "${PUB}" == "${PUB12}" ]] && echo "REALITY identity shared: yes (publicKey=${PUB:0:8}..., valid: $([[ ${PUB} =~ ^[A-Za-z0-9_-]{43}$ ]] && echo yes || echo NO))" || echo "REALITY identity shared: NO"
CA='[{usage:"verify",certificateFile:"/opt/xray-agent/tls/example.com.crt"}]'
stream() { # kind -> streamSettings JSON
    case $1 in
        vision) jq -n "{network:\"tcp\",security:\"tls\",tlsSettings:{serverName:\"example.com\",certificates:$CA}}" ;;
        xhttp-h2) jq -n --arg p "$PATHX" "{network:\"xhttp\",security:\"tls\",xhttpSettings:{path:\$p},tlsSettings:{serverName:\"example.com\",alpn:[\"h2\"],certificates:$CA}}" ;;
        xhttp-h1) jq -n --arg p "$PATHX" "{network:\"xhttp\",security:\"tls\",xhttpSettings:{path:\$p},tlsSettings:{serverName:\"example.com\",fingerprint:\"unsafe\",alpn:[\"http/1.1\"],certificates:$CA}}" ;;
        reality) jq -n --arg pub "$PUB" '{network:"tcp",security:"reality",realitySettings:{serverName:"addons.mozilla.org",fingerprint:"chrome",password:$pub,shortId:"6ba85179e30d4fc2"}}' ;;
        xreality) jq -n --arg pub "$PUB" --arg p "$PATHX" '{network:"xhttp",security:"reality",xhttpSettings:{path:$p},realitySettings:{serverName:"addons.mozilla.org",fingerprint:"chrome",password:$pub,shortId:"6ba85179e30d4fc2"}}' ;;
        hy2) jq -n --arg id "$UUID" "{network:\"hysteria\",security:\"tls\",tlsSettings:{serverName:\"example.com\",alpn:[\"h3\"],certificates:$CA},hysteriaSettings:{version:2,auth:\$id}}" ;;
    esac
}
probe() { # name port kind flow
    local out
    if [[ $3 == hy2 ]]; then
        out=$(jq -n --argjson port $2 --argjson s "$(stream hy2)" '{protocol:"hysteria",settings:{version:2,address:"127.0.0.1",port:$port},streamSettings:$s}')
    else
        out=$(jq -n --arg id "$UUID" --arg flow "$4" --argjson port $2 --argjson s "$(stream $3)" '{protocol:"vless",settings:{vnext:[{address:"127.0.0.1",port:$port,users:[{id:$id,encryption:"none",flow:$flow}]}]},streamSettings:$s}')
    fi
    jq -n --argjson o "$out" '{inbounds:[{listen:"127.0.0.1",port:21080,protocol:"socks",settings:{udp:true}}],outbounds:[$o]}' >/tmp/client.json
    $XB run -c /tmp/client.json >/tmp/client.log 2>&1 &
    local c=$!
    sleep 1.5
    # REALITY needs the real target site, so retry once on network hiccups.
    local code attempt
    for attempt in 1 2; do
        code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -x socks5h://127.0.0.1:21080 http://1.1.1.1/cdn-cgi/trace)
        [[ $code =~ ^(200|301)$ ]] && break
        sleep 2
    done
    printf "  %-40s %s\n" "$1" "$([[ $code =~ ^(200|301)$ ]] && echo works || echo "FAILED ($code)")"
    kill $c 2>/dev/null
    wait $c 2>/dev/null
}
for v in "$@"; do
    XB=/bins/linux-$v/xray
    echo "== generated with ${GEN}, served by Xray ${v}"
    $XB run -confdir ${configPath} >/tmp/server.log 2>&1 &
    s=$!
    sleep 3
    kill -0 $s 2>/dev/null || {
        echo "  server did not start:"
        grep -iE "fail|error" /tmp/server.log | tail -3
        continue
    }
    probe "VLESS+TCP+TLS Vision (443)" 443 vision xtls-rprx-vision
    probe "VLESS+XHTTP+TLS via 443 (h2)" 443 xhttp-h2 ""
    probe "VLESS+XHTTP+TLS via 443 (http/1.1)" 443 xhttp-h1 ""
    probe "VLESS+XHTTP+TLS via panel site (h2)" 8443 xhttp-h2 ""
    probe "VLESS+XHTTP+TLS via panel (http/1.1)" 8443 xhttp-h1 ""
    probe "VLESS+Reality+Vision" "$RPORT" reality xtls-rprx-vision
    probe "VLESS+XHTTP+Reality" "$XRPORT" xreality ""
    probe "Hysteria2" "$HPORT" hy2 ""
    kill $s
    wait $s 2>/dev/null
done
printf "panel site still serves: %s / user rule: %s\n" "$(curl -sk https://example.com:8443/)" "$(curl -sk https://example.com:8443/robots.txt)"
