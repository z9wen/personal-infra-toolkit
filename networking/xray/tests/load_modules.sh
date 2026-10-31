# Sourced by the unit tests: loads every installer module in build order
# (src/modules.list) without the entry point, so a test sees the same
# functions as the built installer, whichever file they live in.

xrayModuleDirectory=$(cd "$(dirname "${BASH_SOURCE[0]}")/../src" && pwd)
while read -r xrayModule; do
    # shellcheck source=/dev/null
    source "${xrayModuleDirectory}/${xrayModule}"
done < <(grep -v '^[[:space:]]*\(#\|$\)' "${xrayModuleDirectory}/modules.list")
unset xrayModule xrayModuleDirectory
