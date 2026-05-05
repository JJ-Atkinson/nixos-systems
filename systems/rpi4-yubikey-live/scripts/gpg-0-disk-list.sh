#!/usr/bin/env bash
set -euo pipefail

lsblk -o NAME,SIZE,FSTYPE,LABEL,UUID,MOUNTPOINTS

printf '\nMounts under /mnt and /run/media:\n'
findmnt -R /mnt /run/media 2>/dev/null || true
