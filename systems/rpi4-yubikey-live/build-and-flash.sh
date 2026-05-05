#!/usr/bin/env bash
set -euo pipefail

self_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$self_dir/../.." && pwd)

usage() {
  cat >&2 <<EOF
Usage:
  $0                        Show lsblk and instructions.
  sudo $0 /dev/sdX          Build the rpi4-yubikey-live image and flash it to
                            /dev/sdX (whole disk, NOT a partition).

The flash step needs root. Re-invoke with sudo when you have the target path.
The build itself runs under \$SUDO_USER so the Nix store stays user-owned.
EOF
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  usage
  exit 0
fi

if [ "$#" -eq 0 ]; then
  printf 'Available block devices:\n\n'
  lsblk -o NAME,SIZE,TYPE,MODEL,MOUNTPOINTS
  cat <<'EOF'

To flash, re-invoke with the target whole-disk path under sudo:

  sudo build-and-flash /dev/sdX

Use the WHOLE-DISK path (/dev/sdX, /dev/nvme0n1, /dev/mmcblk0).
Do NOT pass a partition path (/dev/sdX1).

Flashing overwrites the entire device. Triple-check the path is the
YubiKey admin USB or SD card and not a working drive before running.
EOF
  exit 0
fi

if [ "$#" -ne 1 ]; then
  usage
  exit 2
fi

target=$1

if [ "$(id -u)" -ne 0 ]; then
  printf 'Refusing to run without root. Re-invoke as: sudo %s %s\n' "$0" "$target" >&2
  exit 1
fi

if [ ! -b "$target" ]; then
  printf 'Not a block device: %s\n' "$target" >&2
  exit 1
fi

dev_type=$(lsblk -no TYPE "$target" | head -n 1 | tr -d '[:space:]')
case "$dev_type" in
  disk|loop) ;;
  part)
    printf 'Refusing: %s is a partition. Pass the parent disk (e.g. /dev/sdX, not /dev/sdX1).\n' "$target" >&2
    exit 1
    ;;
  *)
    printf 'Refusing: %s has type %q, not a whole disk.\n' "$target" "$dev_type" >&2
    exit 1
    ;;
esac

build_user=${SUDO_USER:-}
if [ -z "$build_user" ]; then
  printf 'SUDO_USER is empty. Re-invoke this script via sudo from a normal user account.\n' >&2
  exit 1
fi

printf 'Target device:\n'
lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINTS "$target"
printf '\nThis will OVERWRITE the entire device %s. All data on it will be lost.\n' "$target"
printf 'Type "FLASH" (uppercase) to confirm: '
read -r confirm
if [ "$confirm" != "FLASH" ]; then
  printf 'Aborted.\n'
  exit 1
fi

while read -r mp; do
  [ -z "$mp" ] && continue
  printf 'Unmounting %s\n' "$mp"
  umount "$mp" || true
done < <(lsblk -nr -o MOUNTPOINTS "$target" | sed '/^$/d')

result_dir=$(sudo -u "$build_user" mktemp -d)
result_link="$result_dir/result"
trap 'sudo -u "$build_user" rm -rf "$result_dir"' EXIT

printf '\nBuilding image as user %s...\n' "$build_user"
sudo -u "$build_user" nix build \
  --out-link "$result_link" \
  "path:${repo_root}#nixosConfigurations.rpi4-yubikey-live.config.system.build.sdImage"

img=$(find "$result_link/sd-image" -maxdepth 1 -type f -name '*.img.zst' -print -quit)
if [ -z "$img" ] || [ ! -e "$img" ]; then
  printf 'Could not locate *.img.zst under %s/sd-image/\n' "$result_link" >&2
  exit 1
fi

printf '\nFlashing %s to %s\n' "$img" "$target"
zstdcat "$img" | dd of="$target" bs=4M status=progress conv=fsync
sync

printf '\nDone. Safe to remove %s.\n' "$target"
