#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage:
  gpg-7-publish-drive [COPIES] [PAR2_REDUNDANCY_PERCENT]

Publishes the freshly-created identity onto the mounted USB drive at $MOUNT_DIR.
Run this after gpg-1-create-key, gpg-2-card-policy, gpg-3-load-card, and
gpg-4-finish-local have succeeded for the first YubiKey.

Layout written to $MOUNT_DIR (default /mnt/firstkey):

  /gpg-9-redundant-backup.sh         portable copy of backup script
  /gpg-9-redundant-restore.sh        portable copy of restore script
  /public/import-keys                portable script to import on a new machine
  /public/public-key-gpg             armored GPG public key
  /public/public-key-ssh             ssh-add -L line for the [A] subkey
  /public/fingerprint.txt            master + subkey fingerprint summary
  /public-bak/copy-NNN/...           gpg-9-redundant-backup --no-encrypt of /public
  /master-bak/copy-NNN/...           gpg-9-redundant-backup of the master secret +
                                     revocation cert, encrypted to the inserted YubiKey

Defaults:
  COPIES = 40
  PAR2_REDUNDANCY_PERCENT = 30

Pre-flight refuses to run if:
  - $MOUNT_DIR is not a mounted, non-tmpfs filesystem.
  - any of /public, /public-bak, /master-bak already exists under $MOUNT_DIR.
  - required plaintext files are missing from $LOCAL_BACKUP.
  - the inserted YubiKey has no encryption subkey.
EOF
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  usage
  exit 0
fi

if [ "$#" -gt 2 ]; then
  usage
  exit 2
fi

copies=${1:-40}
redundancy=${2:-30}
local_backup=${LOCAL_BACKUP:-/dev/shm/gpg-new-master}
mount_dir=${MOUNT_DIR:-/mnt/firstkey}

case "$copies" in
  ''|*[!0-9]*) printf 'COPIES must be a positive integer\n' >&2; exit 2 ;;
esac
case "$redundancy" in
  ''|*[!0-9]*) printf 'PAR2_REDUNDANCY_PERCENT must be a positive integer\n' >&2; exit 2 ;;
esac

backup_script=${RPI4_BACKUP_SCRIPT:-}
restore_script=${RPI4_RESTORE_SCRIPT:-}
import_keys_script=${RPI4_IMPORT_KEYS_SCRIPT:-}
for var in backup_script restore_script import_keys_script; do
  eval "v=\$$var"
  if [ -z "$v" ] || [ ! -r "$v" ]; then
    printf 'Internal error: %s is unset or not readable. Was this image built correctly?\n' "$var" >&2
    exit 1
  fi
done

if [ ! -d "$local_backup" ]; then
  printf 'LOCAL_BACKUP does not exist: %s\n' "$local_backup" >&2
  exit 1
fi
for f in master-secret-key.asc revocation-certificate.asc public-key.asc KEYFP; do
  if [ ! -s "$local_backup/$f" ]; then
    printf 'Missing or empty required file: %s/%s\n' "$local_backup" "$f" >&2
    printf 'Run gpg-1-create-key first.\n' >&2
    exit 1
  fi
done
keyfp=$(cat "$local_backup/KEYFP")

mount_fstype=$(findmnt -n -o FSTYPE "$mount_dir" 2>/dev/null || true)
if [ -z "$mount_fstype" ]; then
  printf 'MOUNT_DIR %s is not a mountpoint. Mount the USB drive there first:\n' "$mount_dir" >&2
  printf '  gpg-0-disk-list\n' >&2
  printf '  gpg-0-disk-mount /dev/sdXN %s\n' "$mount_dir" >&2
  exit 1
fi
case "$mount_fstype" in
  tmpfs|overlay|ramfs|rootfs)
    printf 'Refusing to publish onto %s filesystem at %s — backups would be lost on reboot.\n' "$mount_fstype" "$mount_dir" >&2
    exit 1
    ;;
esac

if ! test -w "$mount_dir"; then
  printf 'Mount point %s is not writable as %s.\n' "$mount_dir" "$(id -un)" >&2
  printf 'For FAT/exFAT drives, remount via gpg-0-disk-mount (which applies uid=/gid=/umask= options):\n' >&2
  printf '  sudo umount %s\n' "$mount_dir" >&2
  printf '  gpg-0-disk-mount /dev/sdXN %s\n' "$mount_dir" >&2
  printf 'For ext4/btrfs/etc., the patched gpg-0-disk-mount also chowns the mount root after mounting.\n' >&2
  exit 1
fi

for sub in public public-bak master-bak; do
  if [ -e "$mount_dir/$sub" ]; then
    printf 'Refusing to overwrite existing %s/%s. Move or remove it first.\n' "$mount_dir" "$sub" >&2
    exit 1
  fi
done

encryption_fp=$(gpg --card-status 2>/dev/null | awk -F: '/^Encryption key/ { gsub(/[[:space:]]/, "", $2); print $2; exit }')
if [ -z "$encryption_fp" ] || [ "$encryption_fp" = "[none]" ]; then
  printf 'Inserted YubiKey has no encryption subkey on the OpenPGP applet.\n' >&2
  printf 'Run gpg-3-load-card first so the master can be encrypted to this YubiKey.\n' >&2
  exit 1
fi

export SSH_AUTH_SOCK="${SSH_AUTH_SOCK:-$(gpgconf --list-dirs agent-ssh-socket)}"

stage_dir=$(mktemp -d -p /dev/shm gpg-master-bak.XXXXXX)
chmod 700 "$stage_dir"
cleanup() {
  rm -rf "$stage_dir"
}
trap cleanup EXIT

printf 'Staging /public on %s\n' "$mount_dir"
mkdir -p "$mount_dir/public"
install -m 0755 "$backup_script" "$mount_dir/gpg-9-redundant-backup.sh"
install -m 0755 "$restore_script" "$mount_dir/gpg-9-redundant-restore.sh"
install -m 0755 "$import_keys_script" "$mount_dir/public/import-keys"

gpg --armor --export "$keyfp" > "$mount_dir/public/public-key-gpg"

ssh_output=$(ssh-add -L 2>/dev/null || true)
if [ -z "$ssh_output" ]; then
  printf 'ssh-add -L produced no output. Is the YubiKey [A] subkey loaded?\n' >&2
  exit 1
fi
printf '%s\n' "$ssh_output" > "$mount_dir/public/public-key-ssh"

{
  printf 'Master fingerprint: %s\n' "$keyfp"
  printf 'Identity:           %s\n' "$(gpg --list-keys --with-colons "$keyfp" | awk -F: '/^uid:/ { print $10; exit }')"
  printf '\nSubkey fingerprints (capabilities, fingerprint):\n'
  gpg --list-keys --with-colons --with-subkey-fingerprint "$keyfp" | awk -F: '
    /^sub:/ { cap=$12 }
    /^fpr:/ && cap { printf "  [%s] %s\n", cap, $10; cap="" }
  '
  printf '\nGenerated UTC: '
  date -u '+%Y-%m-%dT%H:%M:%SZ'
} > "$mount_dir/public/fingerprint.txt"

chmod 644 "$mount_dir/public/public-key-gpg" "$mount_dir/public/public-key-ssh" "$mount_dir/public/fingerprint.txt"

printf '\nWriting redundant unencrypted copy sets of /public to /public-bak ...\n'
gpg-9-redundant-backup --no-encrypt "$mount_dir/public" "$mount_dir/public-bak" "$copies" "$redundancy"

printf '\nStaging master + revocation cert for encrypted backup ...\n'
master_set="$stage_dir/gpg-master-bak"
mkdir -p "$master_set"
cp "$local_backup/master-secret-key.asc" "$master_set/master-secret-key.asc"
cp "$local_backup/revocation-certificate.asc" "$master_set/revocation-certificate.asc"
chmod 600 "$master_set"/*

printf '\nWriting redundant encrypted copy sets of master to /master-bak ...\n'
gpg-9-redundant-backup "$master_set" "$mount_dir/master-bak" "$copies" "$redundancy"

sync

printf '\nDrive layout written to %s:\n' "$mount_dir"
ls -la "$mount_dir"

printf '\nVerify the backups before shredding plaintext:\n'
printf '  gpg-9-redundant-restore --dry-run %s/master-bak\n' "$mount_dir"
printf '  gpg-9-redundant-restore --no-encrypt --dry-run %s/public-bak\n' "$mount_dir"

printf '\nOnce verified, plaintext working backups can be shredded. They live on RAM-backed tmpfs and will vanish on reboot anyway:\n'
printf '  find %q -type f -exec shred -vuz -- {} +\n' "$local_backup"
printf '  find %q -depth -type d -empty -delete\n' "$local_backup"
