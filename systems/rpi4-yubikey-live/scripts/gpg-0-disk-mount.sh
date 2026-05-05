#!/usr/bin/env bash
set -euo pipefail

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

fstype=$(lsblk -no FSTYPE "$partition" | tr -d '[:space:]')
sudo mkdir -p "$mountpoint"

case "$fstype" in
  vfat|exfat|fat|msdos)
    sudo mount -o uid="$(id -u)",gid="$(id -g)",umask=077 "$partition" "$mountpoint"
    ;;
  *)
    sudo mount "$partition" "$mountpoint"
    sudo chown "$(id -u):$(id -g)" "$mountpoint"
    ;;
esac

findmnt "$mountpoint"
ls -la "$mountpoint"
