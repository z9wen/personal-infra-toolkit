#!/usr/bin/env bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "This script must be run as root." >&2
  exit 1
fi

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <username>" >&2
  exit 1
fi

user="$1"
if ! id "$user" &>/dev/null; then
  echo "User '$user' does not exist." >&2
  exit 1
fi

user_home="$(getent passwd "$user" | cut -d: -f6)"
if [[ -z "$user_home" || ! -d "$user_home" ]]; then
  echo "Cannot determine home directory for '$user'." >&2
  exit 1
fi

src_file="$user_home/.ssh/authorized_keys"
if [[ ! -f "$src_file" ]]; then
  echo "Source authorized_keys not found for user '$user'." >&2
  exit 1
fi

root_ssh_dir="/root/.ssh"
dest_file="$root_ssh_dir/authorized_keys"

mkdir -p "$root_ssh_dir"
touch "$dest_file"

tmp_file="$(mktemp)"
cat "$dest_file" "$src_file" | awk 'NF {line=$0; if (!seen[line]++) print line}' >"$tmp_file"
mv "$tmp_file" "$dest_file"

chown root:root "$root_ssh_dir" "$dest_file"
chmod 700 "$root_ssh_dir"
chmod 600 "$dest_file"

echo "Copied keys from $src_file to $dest_file (deduplicated)."
