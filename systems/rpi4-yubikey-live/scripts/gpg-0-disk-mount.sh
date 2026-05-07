#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC2154
trap 'rc=$?; printf "\nERROR: %s exited %d at %s:%d (cmd: %s)\n" "$(basename "$0")" "$rc" "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

usage() {
  printf 'Usage: %s PARTITION [MOUNTPOINT]\n' "$0" >&2
  printf 'Example: %s /dev/sda1 /mnt/shared\n' "$0" >&2
}

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  usage
  exit 2
fi

partition=$1
mountpoint=${2:-/mnt/shared}

if [ ! -b "$partition" ]; then
  printf 'Not a block device: %s\n' "$partition" >&2
  exit 1
fi

if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ]; then
  target_uid=$(id -u "$SUDO_USER")
  target_gid=$(id -g "$SUDO_USER")
  target_user=$SUDO_USER
  printf 'Detected sudo invocation; mounting as uid=%s gid=%s (user %s) so FAT/exFAT drives are user-writable.\n' \
    "$target_uid" "$target_gid" "$target_user" >&2
  printf 'Tip: this script invokes sudo internally. Run it without sudo next time.\n' >&2
elif [ "$(id -u)" -eq 0 ]; then
  printf 'Refusing to run as root with no SUDO_USER set — FAT mounts would be root-owned and unwritable for normal users.\n' >&2
  printf 'Run this script as your normal user; it elevates internally via sudo.\n' >&2
  exit 1
else
  target_uid=$(id -u)
  target_gid=$(id -g)
  target_user=$(id -un)
fi

fstype=$(lsblk -no FSTYPE "$partition" | tr -d '[:space:]')
sudo mkdir -p "$mountpoint"

case "$fstype" in
  vfat|exfat|fat|msdos)
    sudo mount -o uid="$target_uid",gid="$target_gid",umask=077 "$partition" "$mountpoint"
    ;;
  *)
    sudo mount "$partition" "$mountpoint"
    sudo chown "$target_uid:$target_gid" "$mountpoint"
    ;;
esac

findmnt "$mountpoint"
ls -la "$mountpoint"
