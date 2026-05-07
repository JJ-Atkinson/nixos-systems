#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC2154
trap 'rc=$?; printf "\nERROR: %s exited %d at %s:%d (cmd: %s)\n" "$(basename "$0")" "$rc" "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

lsblk -o NAME,SIZE,FSTYPE,LABEL,UUID,MOUNTPOINTS

printf '\nMounts under /mnt and /run/media:\n'
findmnt -R /mnt /run/media 2>/dev/null || true
