#!/usr/bin/env bash

set -euo pipefail

project_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source_dir="${project_dir}/src"
# CI writes the committed installer; local checks build a throwaway copy by
# setting XRAY_BUILD_OUTPUT so the generated file is never edited by hand.
output_file="${XRAY_BUILD_OUTPUT:-${project_dir}/../xray-install.sh}"
mode=${1:-build}
version_marker="__XRAY_AGENT_VERSION__"

# Library modules come from modules.list (shared with the tests); the entry
# point goes last.
modules=()
while read -r module; do
    modules+=("${module}")
done < <(grep -v '^[[:space:]]*\(#\|$\)' "${source_dir}/modules.list")
modules+=(main.sh)

# A source file left out of the list would silently drop its functions.
while read -r file; do
    if [[ " ${modules[*]} " != *" ${file} "* ]]; then
        echo "${file} is not listed in src/modules.list" >&2
        exit 1
    fi
done < <(cd "${source_dir}" && find . -name '*.sh' | sed 's|^\./||' | sort)

temp_file=$(mktemp "${output_file}.tmp.XXXXXX")
trap 'rm -f "${temp_file}" "${temp_file}.versioned"' EXIT

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
