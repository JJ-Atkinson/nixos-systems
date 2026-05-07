#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC2154
trap 'rc=$?; printf "\nERROR: %s exited %d at %s:%d (cmd: %s)\n" "$(basename "$0")" "$rc" "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

usage() {
  printf 'Usage: %s [YYYY-MM-DD HH:MM:SS]\n' "$0" >&2
  printf 'Without an argument, prints current clock state. With an argument, sets local system time.\n' >&2
}

if [ "$#" -gt 1 ]; then
  usage
  exit 2
fi

if [ "$#" -eq 1 ]; then
  sudo date -s "$1"
fi

date
date -u
if command -v timedatectl >/dev/null 2>&1; then
  timedatectl 2>/dev/null || true
fi

if command -v curl >/dev/null 2>&1; then
  printf '\nRemote HTTP Date sanity check, if network is available:\n'
  curl -I --max-time 10 https://google.com 2>/dev/null | grep -i '^date:' || true
fi
