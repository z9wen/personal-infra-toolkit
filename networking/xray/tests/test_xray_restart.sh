#!/usr/bin/env bash

set -euo pipefail

testDirectory=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "${testDirectory}/../src/09_core_runtime.sh"

echoContent() {
    :
}

sleep() {
    :
}

pgrep() {
    return 0
}

xraySystemdServiceAvailable() {
    return 0
}

restartCalls=0
startCalls=0
systemctl() {
    case $1 in
    restart)
        ((restartCalls += 1))
        return 0
        ;;
    start)
        ((startCalls += 1))
        return 0
        ;;
    is-active) return 0 ;;
    esac
}

restartXray
[[ ${restartCalls} -eq 1 && ${startCalls} -eq 0 ]]

# restart 失败时必须再尝试 start，不能把 Xray 留在停止状态。
systemctl() {
    case $1 in
    restart)
        ((restartCalls += 1))
        return 1
        ;;
    start)
        ((startCalls += 1))
        return 0
        ;;
    is-active) return 0 ;;
    esac
}

restartXray
[[ ${restartCalls} -eq 2 && ${startCalls} -eq 1 ]]

# 启动失败应返回非零，而不是 exit 0 中断整个管理脚本。
systemctl() {
    return 1
}
if restartXray; then
    echo "restartXray unexpectedly succeeded" >&2
    exit 1
fi

echo "xray restart tests passed"
