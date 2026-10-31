#!/usr/bin/env bash
#
# Native (host) nginx: listen ports read from "nginx -T", the check that our
# config is loaded, and starting nginx again after this run stopped it.
# Stub nginx/systemctl/pgrep keep the state; no real nginx is touched.

# Globals are shared with the sourced modules, which ShellCheck cannot see.
# shellcheck disable=SC2034,SC2154

set -euo pipefail

testDirectory=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "${testDirectory}/load_modules.sh"

echoContent() { :; }
sleep() { :; }
fail() {
    echo "FAIL: $*" >&2
    exit 1
}

btDomain=
selectCustomInstallType=
nginxStoppedByAgent=
nginxConfigPath=/etc/nginx/conf.d/

hostRunning=false
containerRunning=false
nginxStarts=0
nginxDumpStatus=0
nginxDump=$(
    cat <<'DUMP'
# configuration file /etc/nginx/nginx.conf:
http {
    include /etc/nginx/conf.d/*.conf;
    include /etc/nginx/sites-enabled/*;
}

# configuration file /etc/nginx/conf.d/xray-agent.conf:
server {
	listen 127.0.0.1:31300;
	server_name _;
}
server {
	listen 127.0.0.1:31302 so_keepalive=on proxy_protocol;http2 on;
}

# configuration file /etc/nginx/sites-enabled/blog:
server {
    listen 443 ssl; listen [::]:443 ssl;
    listen 443 quic reuseport;
    listen 8443 quic;
    # listen 9000;
    listen unix:/run/blog.sock;
    listen 127.0.0.1;
}

# configuration file /etc/nginx/conf.d/checkPortOpen.conf:
server {
    listen 2053;
}
DUMP
)

nginx() {
    case ${1:-} in
        -T)
            printf '%s\n' "${nginxDump}"
            return "${nginxDumpStatus}"
            ;;
        -t) echo "nginx: configuration file /etc/nginx/nginx.conf test is successful" ;;
        -s) hostRunning=false ;;
        *)
            hostRunning=true
            nginxStarts=$((nginxStarts + 1))
            ;;
    esac
}
systemctl() {
    case $1 in
        list-unit-files) echo "nginx.service enabled enabled" ;;
        start)
            hostRunning=true
            nginxStarts=$((nginxStarts + 1))
            ;;
        stop) hostRunning=false ;;
    esac
}
# Used instead of systemctl where the host has the SysV script.
/etc/init.d/nginx() { systemctl "$@"; }
# 4242 is the host nginx, 5151 one in a container (another PID namespace).
pgrep() {
    [[ "$*" == "-x nginx" ]] || return 1
    [[ "${hostRunning}" == "true" ]] && echo 4242
    [[ "${containerRunning}" == "true" ]] && echo 5151
    return 0
}
readlink() {
    case $1 in
        /proc/self/ns/pid | /proc/4242/ns/pid) echo "pid:[1]" ;;
        /proc/5151/ns/pid) echo "pid:[2]" ;;
    esac
}

# --- listen ports from nginx -T ---------------------------------------------
ports=$(nginxListenPorts | tr '\n' ' ')
[[ "${ports}" == "80 443 31300 31302 " ]] || fail "unexpected listen ports: ${ports}"
nginxListensOnPort 443 || fail "an existing HTTPS site owns 443"
nginxListensOnPort 8443 && fail "QUIC listens on UDP and does not block a TCP port"
nginxListensOnPort 9000 && fail "commented-out listen must be ignored"
nginxListensOnPort 2053 && fail "a leftover port-check config must be ignored"
nginxDumpStatus=1
nginxListensOnPort 443 && fail "a config that does not test cleanly reports no ports"
nginxDumpStatus=0

# --- our config is loaded ---------------------------------------------------
checkNginxLoadsConf /etc/nginx/conf.d/xray-agent.conf || fail "xray-agent.conf is in the dump"
checkNginxLoadsConf /etc/nginx/conf.d/missing.conf && fail "a file nginx does not load must fail"
nginxDumpStatus=1
checkNginxLoadsConf /etc/nginx/conf.d/missing.conf || fail "a failing nginx -T is left to handleNginx"
nginxDumpStatus=0

# --- host nginx vs nginx in a container -------------------------------------
containerRunning=true
hostNginxRunning && fail "a container nginx is not the host nginx"
selectCustomInstallType=",0,14,"
handleNginx start
[[ "${hostRunning}" == "true" && ${nginxStarts} -eq 1 ]] || fail "a container nginx must not block starting the host nginx"
hostNginxRunning || fail "the host nginx runs now"
handleNginx stop || fail "stop must not wait on the container nginx"
[[ "${hostRunning}" == "false" ]] || fail "host nginx not stopped"
containerRunning=false
handleNginx start
nginxStarts=0

# --- REALITY-only installs --------------------------------------------------
selectCustomInstallType=",3,"
handleNginx start
[[ ${nginxStarts} -eq 0 ]] || fail "REALITY-only start must not touch nginx (it was running)"
handleNginx stop
[[ "${nginxStoppedByAgent}" == "true" ]] || fail "stop must remember that this run stopped nginx"
handleNginx start
[[ "${hostRunning}" == "true" && ${nginxStarts} -eq 1 ]] || fail "nginx stopped by this run must be started again"
[[ -z "${nginxStoppedByAgent}" ]] || fail "a successful start clears the flag"
hostRunning=false
handleNginx start
[[ ${nginxStarts} -eq 1 ]] || fail "REALITY-only start must not start an nginx this run did not stop"

# --- leaving without starting nginx again -----------------------------------
selectCustomInstallType=
hostRunning=true
nginxStarts=0
handleNginx stop
restoreStoppedNginx
[[ "${hostRunning}" == "true" && ${nginxStarts} -eq 1 ]] || fail "exit must start the nginx this run stopped"
restoreStoppedNginx
[[ ${nginxStarts} -eq 1 ]] || fail "restore is a no-op once nginx runs again"

echo "host nginx tests passed"
