#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC2154
trap 'rc=$?; printf "\nERROR: %s exited %d at %s:%d (cmd: %s)\n" "$(basename "$0")" "$rc" "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

usage() {
  cat >&2 <<EOF
Usage: gpg-8-restore-state [--force]

Restores end-of-§7 working state after a Pi reboot, from any published drive
mounted at \$MOUNT_DIR. Run with one of your loaded YubiKeys inserted.

Steps performed:
  1. sh \$MOUNT_DIR/public/import-keys     — public key + trust into ~/.gnupg
  2. gpg-9-redundant-restore \$MOUNT_DIR/master-bak <tmp>
                                          — decrypt master + revocation cert via YubiKey
  3. cp <tmp>/gpg-master-bak/* into \$LOCAL_BACKUP
  4. gpg --import \$LOCAL_BACKUP/master-secret-key.asc
  5. write \$LOCAL_BACKUP/KEYFP from the imported master fingerprint
  6. gpg --card-status to attach stubs

After this completes, \$LOCAL_BACKUP contains master-secret-key.asc,
revocation-certificate.asc, public-key.asc, secret-subkeys.asc, and KEYFP
— the same shape gpg-1-create-key produces. You can then proceed to §9
to load the next YubiKey.

Pre-flight refuses to run if:
  - \$MOUNT_DIR is not a mounted, non-tmpfs filesystem.
  - \$MOUNT_DIR/public/import-keys or \$MOUNT_DIR/master-bak is missing.
  - \$LOCAL_BACKUP already contains master-secret-key.asc (use --force to overwrite).
  - No YubiKey is inserted, or the inserted YubiKey has no encryption subkey.
EOF
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  usage
  exit 0
fi

force=false
if [ "${1:-}" = "--force" ]; then
  force=true
  shift
fi

if [ "$#" -ne 0 ]; then
  usage
  exit 2
fi

local_backup=${LOCAL_BACKUP:-/dev/shm/gpg-new-master}
mount_dir=${MOUNT_DIR:-/mnt/firstkey}

mount_fstype=$(findmnt -n -o FSTYPE "$mount_dir" 2>/dev/null || true)
if [ -z "$mount_fstype" ]; then
  printf '%s is not a mountpoint. Mount a published drive there first:\n' "$mount_dir" >&2
  printf '  gpg-0-disk-list\n  gpg-0-disk-mount /dev/sdXN %s\n' "$mount_dir" >&2
  exit 1
fi
case "$mount_fstype" in
  tmpfs|overlay|ramfs|rootfs)
    printf 'Refusing: %s is %s — backups would not be persistent.\n' "$mount_dir" "$mount_fstype" >&2
    exit 1
    ;;
esac

for f in "$mount_dir/public/import-keys" "$mount_dir/master-bak"; do
  if [ ! -e "$f" ]; then
    printf 'Missing on drive: %s\n' "$f" >&2
    printf 'This drive does not look like a gpg-7-publish-drive output.\n' >&2
    exit 1
  fi
done

if [ -s "$local_backup/master-secret-key.asc" ] && [ "$force" = false ]; then
  printf 'Refusing: %s/master-secret-key.asc already present.\n' "$local_backup" >&2
  printf 'Pass --force to overwrite, or shred the existing copy first.\n' >&2
  exit 1
fi

printf 'Verifying inserted YubiKey...\n' >&2
gpgconf --kill all >/dev/null 2>&1 || true

card_status_file=$(mktemp -p /dev/shm gpg-card-status.XXXXXX)
if ! timeout 10s gpg --card-status >"$card_status_file" 2>&1; then
  printf '\ngpg --card-status failed or timed out. Output:\n' >&2
  sed 's/^/  /' "$card_status_file" >&2
  printf '\nIs a YubiKey inserted?\n' >&2
  rm -f "$card_status_file"
  exit 1
fi

encryption_fp=$(awk -F: '/^Encryption key/ { gsub(/[[:space:]]/, "", $2); print $2; exit }' "$card_status_file")
rm -f "$card_status_file"

if [ -z "$encryption_fp" ] || [ "$encryption_fp" = "[none]" ]; then
  printf 'Inserted YubiKey has no encryption subkey on the OpenPGP applet.\n' >&2
  printf 'Insert a YubiKey loaded by gpg-3-load-card, then re-run.\n' >&2
  exit 1
fi
printf 'Encryption subkey found: %s\n' "$encryption_fp" >&2

stage=$(mktemp -d -p /dev/shm gpg-restore-stage.XXXXXX)
chmod 700 "$stage"
cleanup() {
  rc=$?
  if [ "$rc" -ne 0 ] && [ -d "$stage" ]; then
    printf 'Failure (rc=%d). Staging dir was %s — listing before cleanup:\n' "$rc" "$stage" >&2
    ls -la "$stage" >&2 || true
  fi
  rm -rf "$stage"
}
trap cleanup EXIT

printf '\nImporting public key from %s/public/import-keys ...\n' "$mount_dir"
if ! sh "$mount_dir/public/import-keys"; then
  printf 'WARNING: import-keys returned non-zero. Continuing — the master import below is what matters for §9.\n' >&2
fi

printf '\nDecrypting master from %s/master-bak ...\n' "$mount_dir"
gpg-9-redundant-restore "$mount_dir/master-bak" "$stage"

if [ ! -d "$stage/gpg-master-bak" ]; then
  printf 'Restored archive has no gpg-master-bak/ — drive layout unexpected.\n' >&2
  ls -la "$stage" >&2
  exit 1
fi

mkdir -p "$local_backup"
chmod 700 "$local_backup"
cp -a "$stage/gpg-master-bak/." "$local_backup/"
chmod 600 "$local_backup"/*.asc

printf '\nImporting master into the local keychain ...\n'
import_log=$(mktemp -p /dev/shm gpg-import.XXXXXX)
gpg --import "$local_backup/master-secret-key.asc" 2>&1 | tee "$import_log"

keyfp=$(gpg --list-secret-keys --with-colons | awk -F: '/^fpr:/ { print $10; exit }')
if [ -z "$keyfp" ]; then
  printf '\ngpg --list-secret-keys returned no fingerprint after import.\n' >&2
  if grep -qi 'time warp\|in the future' "$import_log"; then
    printf '\ngpg refused the import: system clock is wrong.\n' >&2
    printf 'The Pi has no RTC; on cold boot the clock defaults to the build epoch.\n' >&2
    printf 'Set the clock and re-run:\n' >&2
    printf '  gpg-0-clock "YYYY-MM-DD HH:MM:SS"   # current UTC\n' >&2
    printf '  gpg-8-restore-state\n' >&2
  else
    printf 'Inspect ~/.gnupg state and gpgconf --check-programs.\n' >&2
  fi
  rm -f "$import_log"
  exit 1
fi
rm -f "$import_log"
printf '%s\n' "$keyfp" > "$local_backup/KEYFP"
chmod 600 "$local_backup/KEYFP"

printf '\nRegenerating secret-subkeys.asc (gpg-3-load-card pre-flight expects it) ...\n'
gpg --armor --export-secret-subkeys "$keyfp" > "$local_backup/secret-subkeys.asc"
chmod 600 "$local_backup/secret-subkeys.asc"

if diff -q <(gpg --armor --export "$keyfp") "$mount_dir/public/public-key-gpg" >/dev/null 2>&1; then
  printf 'Public key matches drive copy.\n'
else
  printf 'WARNING: public key differs from drive copy at %s/public/public-key-gpg\n' "$mount_dir" >&2
fi

printf '\nRe-attaching YubiKey stubs ...\n'
stub_status_file=$(mktemp -p /dev/shm gpg-card-status.XXXXXX)
if ! timeout 10s gpg --card-status >"$stub_status_file" 2>&1; then
  printf '\ngpg --card-status failed or timed out while attaching stubs. Output:\n' >&2
  sed 's/^/  /' "$stub_status_file" >&2
  rm -f "$stub_status_file"
  exit 1
fi
rm -f "$stub_status_file"

printf '\nWorking state restored. LOCAL_BACKUP=%s\n' "$local_backup"
ls -la "$local_backup"
printf '\nMaster fingerprint: %s\n' "$keyfp"
printf '\nReady for §9: insert next YubiKey, then run gpg-3-reimport-master && gpg-2-card-policy && gpg-3-load-card && gpg-4-finish-local.\n'
