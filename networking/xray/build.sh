#!/usr/bin/env bash

set -euo pipefail

project_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source_dir="${project_dir}/src"
output_file="${project_dir}/../xray-install.sh"
mode=${1:-build}
version_marker="__XRAY_AGENT_VERSION__"

modules=(
    01_common.sh
    02_state_readers.sh
    03_panels.sh
    04_firewall.sh
    05_preflight.sh
    06_host_provisioning.sh
    07_nginx.sh
    08_tls_hysteria.sh
    09_core_runtime.sh
    10_xray_config.sh
    11_client_output.sh
    12_operations.sh
    13_network_routing.sh
    14_relay.sh
    15_routing_tools.sh
    16_install_management.sh
    17_subscriptions.sh
    18_reality.sh
    19_hysteria_management.sh
    20_menu.sh
)

temp_file=$(mktemp "${output_file}.tmp.XXXXXX")
trap 'rm -f "${temp_file}"' EXIT

for module in "${modules[@]}"; do
    cat "${source_dir}/${module}" >>"${temp_file}"
done

case ${mode} in
    --check)
        if [[ ! -f "${output_file}" ]]; then
            echo "xray-install.sh does not exist; run networking/xray/build.sh" >&2
            exit 1
        fi
        build_version=$(sed -n 's/.*当前版本：v\([0-9][0-9.]*\)".*/\1/p' "${output_file}" | head -1)
        if [[ -z "${build_version}" ]]; then
            echo "xray-install.sh does not contain a generated version" >&2
            exit 1
        fi
        ;;
    build | --stdout)
        build_version="$(TZ=Asia/Taipei date '+%Y.%m.%d').$(date '+%s')"
        ;;
    *)
        echo "Usage: $0 [build|--check|--stdout]" >&2
        exit 2
        ;;
esac

if ! grep -q "${version_marker}" "${temp_file}"; then
    echo "Xray version marker is missing from source modules" >&2
    exit 1
fi
versioned_temp="${temp_file}.versioned"
sed "s/${version_marker}/${build_version}/g" "${temp_file}" >"${versioned_temp}"
mv "${versioned_temp}" "${temp_file}"

bash -n "${temp_file}"

case ${mode} in
    --check)
        if ! cmp -s "${output_file}" "${temp_file}"; then
            echo "xray-install.sh is out of date; run networking/xray/build.sh" >&2
            diff -u "${output_file}" "${temp_file}" || true
            exit 1
        fi
        echo "Xray bundle is up to date"
        ;;
    --stdout)
        cat "${temp_file}"
        ;;
    build)
        chmod --reference="${output_file}" "${temp_file}" 2>/dev/null || chmod 755 "${temp_file}"
        mv "${temp_file}" "${output_file}"
        trap - EXIT
        echo "Built ${output_file}"
        ;;
esac
