#!/usr/bin/env bash
#
# Prove the private network design works after `terraform apply`:
#   1. inside the VNet, db.<zone> resolves through Private DNS to a private IP
#   2. the VM reaches MySQL on 3306 and can log in over TLS
#   3. from the internet, the database is not reachable at all
#
# Usage: verify_connectivity.sh [terraform-dir]
# Requires: terraform, jq, ssh, nc

# Remote commands embed Terraform outputs that are expanded locally on purpose.
# shellcheck disable=SC2029

set -euo pipefail

TF_DIR="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../terraform" && pwd)}"
SSH_OPTIONS=(-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new)

log() {
    echo "$(date '+%H:%M:%S') $*"
}

die() {
    log "FAIL: $*" >&2
    exit 1
}

for tool in terraform jq ssh nc; do
    command -v "${tool}" >/dev/null 2>&1 || die "${tool} is required"
done

outputs="$(terraform -chdir="${TF_DIR}" output -json)"
output() {
    jq -er --arg name "$1" '.[$name].value' <<<"${outputs}"
}

vm_ip="$(output vm_public_ip)"
mysql_fqdn="$(output mysql_fqdn)"
mysql_alias="$(output mysql_alias)"
mysql_user="$(output mysql_admin_login)"
mysql_password="$(output mysql_admin_password)"
mysql_database="$(output mysql_database)"
target="azureuser@${vm_ip}"

log "Waiting for cloud-init on ${vm_ip}"
ssh "${SSH_OPTIONS[@]}" "${target}" 'cloud-init status --wait >/dev/null' \
    || die "cannot SSH to ${vm_ip} (check admin_source_cidr and that the VM is running)"

log "Resolving ${mysql_alias} inside the VNet"
resolved_ip="$(ssh "${SSH_OPTIONS[@]}" "${target}" "dig +short '${mysql_alias}' | tail -n 1")"
[[ ${resolved_ip} =~ ^10\.20\.2\.[0-9]+$ ]] \
    || die "${mysql_alias} resolved to '${resolved_ip}', expected an address in the MySQL subnet 10.20.2.0/24"
log "PASS ${mysql_alias} -> ${resolved_ip} (private)"

log "Checking TCP 3306 from the VM"
ssh "${SSH_OPTIONS[@]}" "${target}" "nc -z -w 5 '${mysql_alias}' 3306" \
    || die "VM cannot reach ${mysql_alias}:3306 (check the MySQL subnet NSG)"
log "PASS VM reaches MySQL on 3306"

log "Logging in to MySQL over TLS"
# The password travels over SSH stdin, never in a command line or process list.
result="$(ssh "${SSH_OPTIONS[@]}" "${target}" \
    "MYSQL_PWD=\"\$(cat)\" mysql --ssl-mode=REQUIRED --batch --skip-column-names \
        -h '${mysql_alias}' -u '${mysql_user}' '${mysql_database}' \
        -e \"SELECT VERSION(), @@require_secure_transport, (SELECT VARIABLE_VALUE FROM performance_schema.session_status WHERE VARIABLE_NAME = 'Ssl_cipher')\"" \
    <<<"${mysql_password}")" || die "MySQL login failed"
log "PASS MySQL login: version, require_secure_transport, TLS cipher = ${result//$'\t'/, }"

log "Checking the database is not reachable from the internet"
if nc -z -w 5 "${mysql_fqdn}" 3306 >/dev/null 2>&1; then
    die "${mysql_fqdn}:3306 is reachable from outside the VNet"
fi
log "PASS ${mysql_fqdn}:3306 is not reachable from outside the VNet"

log "All connectivity checks passed"
