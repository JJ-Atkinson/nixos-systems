#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf 'Usage: %s PARTITION\n' "$0" >&2
  printf 'Example: %s /dev/sda1\n' "$0" >&2
}

if [ "$#" -ne 1 ]; then
  usage
  exit 2
fi

partition=$1

if [ ! -b "$partition" ]; then
  printf 'Not a block device: %s\n' "$partition" >&2
  exit 1
fi

if findmnt -rn --source "$partition" >/dev/null; then
  printf '%s is mounted. Unmount it before fsck.\n' "$partition" >&2
  findmnt -rn --source "$partition" >&2
  exit 1
fi

fstype=$(lsblk -no FSTYPE "$partition" | tr -d '[:space:]')

case "$fstype" in
  vfat|fat|msdos)
    sudo fsck.vfat -a "$partition"
    ;;
  ext2|ext3|ext4)
    sudo fsck.ext4 -f -y "$partition"
    ;;
  exfat)
    if command -v fsck.exfat >/dev/null 2>&1; then
      sudo fsck.exfat "$partition"
    else
      printf 'fsck.exfat is not available in this image. Repair exFAT from a system with exfatprogs.\n' >&2
      exit 1
    fi
    ;;
  ntfs)
    if command -v ntfsfix >/dev/null 2>&1; then
      sudo ntfsfix "$partition"
    else
      printf 'ntfsfix is not available in this image. Repair NTFS from Windows or a fuller Linux system.\n' >&2
      exit 1
    fi
    ;;
  *)
    printf 'Unsupported or unknown filesystem for %s: %s\n' "$partition" "${fstype:-unknown}" >&2
    exit 1
    ;;
esac
