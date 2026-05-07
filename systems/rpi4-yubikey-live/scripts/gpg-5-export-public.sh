#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC2154
trap 'rc=$?; printf "\nERROR: %s exited %d at %s:%d (cmd: %s)\n" "$(basename "$0")" "$rc" "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

usage() {
  cat >&2 <<'EOF'
Usage:
  gpg-5-export-public [KEY_FINGERPRINT] [OUTPUT_DIR] [CARDNO_FILTER]

Exports the GPG public key (.asc) and the YubiKey-backed SSH public key (.pub)
into OUTPUT_DIR for upload to GitHub or similar.

KEY_FINGERPRINT is optional. Resolution order:
  1. positional argument
  2. $KEYFP environment variable
  3. $LOCAL_BACKUP/KEYFP file (default /dev/shm/gpg-new-master/KEYFP)

Defaults:
  OUTPUT_DIR     $HOME/github-key-exports
  CARDNO_FILTER  none — exports every key shown by ssh-add -L
EOF
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  usage
  exit 0
fi

if [ "$#" -gt 3 ]; then
  usage
  exit 2
fi

local_backup=${LOCAL_BACKUP:-/dev/shm/gpg-new-master}
keyfp=${1:-${KEYFP:-}}
if [ -z "$keyfp" ] && [ -r "$local_backup/KEYFP" ]; then
  keyfp=$(cat "$local_backup/KEYFP")
fi
if [ -z "$keyfp" ]; then
  printf 'KEY_FINGERPRINT could not be resolved.\n' >&2
  # shellcheck disable=SC2016
  printf 'Pass it as an argument, set $KEYFP, or run gpg-1-create-key first.\n' >&2
  exit 2
fi

output_dir=${2:-"$HOME/github-key-exports"}
card_filter=${3:-}

export SSH_AUTH_SOCK="${SSH_AUTH_SOCK:-$(gpgconf --list-dirs agent-ssh-socket)}"
mkdir -p "$output_dir"

gpg --armor --export "$keyfp" > "$output_dir/github-gpg-public-key.asc"
[ -s "$output_dir/github-gpg-public-key.asc" ] || { printf 'gpg --armor --export %s produced empty output (key not in keyring?)\n' "$keyfp" >&2; exit 1; }

ssh_output=$(ssh-add -L 2>/dev/null || true)
if [ -z "$ssh_output" ]; then
  printf 'ssh-add -L produced no output. Is a YubiKey inserted with the [A] subkey loaded?\n' >&2
  exit 1
fi

if [ -n "$card_filter" ]; then
  filtered=$(printf '%s\n' "$ssh_output" | while IFS= read -r key; do
    case "$key" in
      *"$card_filter"*) printf '%s\n' "$key" ;;
    esac
  done)
  if [ -z "$filtered" ]; then
    printf 'CARDNO_FILTER %q matched no keys in ssh-add -L output.\n' "$card_filter" >&2
    exit 1
  fi
  printf '%s\n' "$filtered" > "$output_dir/github-ssh-public-key.pub"
else
  printf '%s\n' "$ssh_output" > "$output_dir/github-ssh-public-key.pub"
fi

chmod 644 "$output_dir/github-gpg-public-key.asc" "$output_dir/github-ssh-public-key.pub"
ls -lh "$output_dir"
