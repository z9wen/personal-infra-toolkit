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

# If restart fails, start must be attempted; Xray must not be left stopped.
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

# A failed start should return non-zero rather than `exit 0`, which would abort the whole management script.
systemctl() {
    return 1
}
if restartXray; then
    echo "restartXray unexpectedly succeeded" >&2
    exit 1
fi

# A crash-looping service is briefly "active" between restarts. systemd's
# NRestarts counter keeps climbing, so restartXray must not report success.
# The counter lives in a file because restartXray reads it via $(...),
# which runs the stub in a subshell.
restartCounterFile=$(mktemp)
trap 'rm -f "${restartCounterFile}"' EXIT
echo 0 >"${restartCounterFile}"
systemctl() {
    case $1 in
        restart | start) return 0 ;;
        is-active) return 0 ;;
        show)
            local count
            count=$(($(cat "${restartCounterFile}") + 1))
            echo "${count}" >"${restartCounterFile}"
            echo "${count}"
            ;;
    esac
}
if restartXray; then
    echo "restartXray accepted a crash-looping service" >&2
    exit 1
fi

echo "xray restart tests passed"
