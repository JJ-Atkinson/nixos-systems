#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC2154
trap 'rc=$?; printf "\nERROR: %s exited %d at %s:%d (cmd: %s)\n" "$(basename "$0")" "$rc" "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

usage() {
  printf 'Usage: %s PUBLIC_KEY_ASC\n' "$0" >&2
}

if [ "$#" -ne 1 ]; then
  usage
  exit 2
fi

public_key=$1

if [ ! -f "$public_key" ]; then
  printf 'Public key file not found: %s\n' "$public_key" >&2
  exit 1
fi

gpg --import "$public_key"
gpgconf --kill gpg-agent
gpg --card-status
gpg --list-secret-keys --keyid-format LONG --with-subkey-fingerprint --with-keygrip
