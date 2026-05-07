#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC2154
trap 'rc=$?; printf "\nERROR: %s exited %d at %s:%d (cmd: %s)\n" "$(basename "$0")" "$rc" "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

usage() {
  cat >&2 <<'EOF'
Usage:
  gpg-9-redundant-backup [--no-encrypt] SOURCE_DIR DEST_DIR [COPIES] [PAR2_REDUNDANCY_PERCENT]

Creates a cold-storage backup from a source folder:
  1. Creates a tar.gz archive from SOURCE_DIR in a temporary directory.
  2. Encrypts that archive to the inserted YubiKey OpenPGP encryption subkey, unless --no-encrypt is set.
  3. Writes many independent copy sets under DEST_DIR.
  4. Adds SHA256, BLAKE2, and PAR2 recovery data to every copy set.

Options:
  --no-encrypt  Store redundant plaintext tar.gz copy sets for public data.

SOURCE_DIR is never modified by this command.

Defaults:
  COPIES = 40
  PAR2_REDUNDANCY_PERCENT = 30

Examples:
  gpg-9-redundant-backup /dev/shm/gpg-new-master /mnt/backup/gpg-master-key-backup
  gpg-9-redundant-backup --no-encrypt ./public-docs /mnt/backup/public-docs-backup
  gpg-9-redundant-backup /dev/shm/gpg-new-master /mnt/backup/gpg-master-key-backup 40 30

Verify afterward with:
  gpg-9-redundant-restore --dry-run DEST_DIR
EOF
}

no_encrypt=false

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  usage
  exit 0
fi

if [ "${1:-}" = "--no-encrypt" ]; then
  no_encrypt=true
  shift
fi

if [ "$#" -lt 2 ] || [ "$#" -gt 4 ]; then
  usage
  exit 2
fi

source_dir=$1
dest_dir=$2
copies=${3:-40}
redundancy=${4:-30}

if [ ! -d "$source_dir" ]; then
  printf 'Source directory does not exist: %s\n' "$source_dir" >&2
  exit 1
fi

case "$copies" in
  ''|*[!0-9]*) printf 'COPIES must be a positive integer\n' >&2; exit 2 ;;
esac

case "$redundancy" in
  ''|*[!0-9]*) printf 'PAR2_REDUNDANCY_PERCENT must be a positive integer\n' >&2; exit 2 ;;
esac

if [ "$copies" -lt 1 ]; then
  printf 'COPIES must be at least 1\n' >&2
  exit 2
fi

if [ "$redundancy" -lt 1 ]; then
  printf 'PAR2_REDUNDANCY_PERCENT must be at least 1\n' >&2
  exit 2
fi

encryption_fingerprint=
if [ "$no_encrypt" = false ]; then
  encryption_fingerprint=$(gpg --card-status 2>/dev/null | awk -F: '/^Encryption key/ { gsub(/[[:space:]]/, "", $2); print $2; exit }')

  if [ -z "$encryption_fingerprint" ] || [ "$encryption_fingerprint" = "[none]" ]; then
    printf 'Could not find an encryption key on the inserted YubiKey.\n' >&2
    printf 'Run gpg --card-status and make sure the public key has been imported.\n' >&2
    exit 1
  fi
fi

mkdir -p "$dest_dir"
tmp_root=$(mktemp -d)
cleanup() {
  rc=$?
  if [ "$rc" -ne 0 ] && [ -d "$tmp_root" ]; then
    printf 'Failure (rc=%d). Staging dir was %s — listing before cleanup:\n' "$rc" "$tmp_root" >&2
    ls -la "$tmp_root" >&2 || true
  fi
  rm -rf "$tmp_root"
}
trap cleanup EXIT

source_base=$(basename "$source_dir")
archive_name="$source_base.tar.gz"
encrypted_name="$archive_name.gpg"
archive_path="$tmp_root/$archive_name"
encrypted_path="$tmp_root/$encrypted_name"
payload_name=$encrypted_name
payload_path=$encrypted_path
manifest="$dest_dir/MANIFEST.txt"

printf 'Creating archive from %s\n' "$source_dir"
tar -C "$(dirname "$source_dir")" -czf "$archive_path" "$source_base"

if [ "$no_encrypt" = true ]; then
  payload_name=$archive_name
  payload_path=$archive_path
  printf 'Leaving archive unencrypted because --no-encrypt was set. Use only for public data.\n'
else
  printf 'Encrypting archive to YubiKey encryption subkey: %s\n' "$encryption_fingerprint"
  gpg --encrypt --recipient "$encryption_fingerprint" --output "$encrypted_path" "$archive_path"
fi

{
  if [ "$no_encrypt" = true ]; then
    printf 'Redundant unencrypted backup set\n'
  else
    printf 'Redundant encrypted backup set\n'
  fi
  printf 'Source directory: %s\n' "$source_dir"
  printf 'Stored payload: %s\n' "$payload_name"
  printf 'Encrypted: %s\n' "$([ "$no_encrypt" = true ] && printf 'no' || printf 'yes')"
  if [ "$no_encrypt" = false ]; then
    printf 'YubiKey encryption recipient: %s\n' "$encryption_fingerprint"
  fi
  printf 'Copies: %s\n' "$copies"
  printf 'PAR2 redundancy percent: %s\n' "$redundancy"
  printf 'Created UTC: '
  date -u '+%Y-%m-%dT%H:%M:%SZ'
  printf '\nPayload checksums:\n'
  sha256sum "$payload_path"
  b2sum "$payload_path"
} > "$manifest"

i=1
while [ "$i" -le "$copies" ]; do
  copy_dir=$(printf '%s/copy-%03d' "$dest_dir" "$i")
  mkdir -p "$copy_dir"
  cp --reflink=auto -- "$payload_path" "$copy_dir/$payload_name"

  (
    cd "$copy_dir"
    sha256sum "$payload_name" > "$payload_name.sha256"
    b2sum "$payload_name" > "$payload_name.b2"
    par2 create -q -r"$redundancy" "$payload_name.par2" "$payload_name" "$payload_name.sha256" "$payload_name.b2"
  )

  printf 'Created %s\n' "$copy_dir"
  i=$((i + 1))
done

if [ "$no_encrypt" = true ]; then
  printf '\nCreated %s redundant unencrypted copy sets under %s\n' "$copies" "$dest_dir"
  printf '\nIMPORTANT: BACKUP PAYLOADS ARE NOT ENCRYPTED\n'
  printf 'Use --no-encrypt only for public data. Stored tarballs can be read without a YubiKey.\n'
else
  printf '\nCreated %s redundant encrypted copy sets under %s\n' "$copies" "$dest_dir"
fi
printf '\nIMPORTANT: SOURCE FILES LEFT UNTOUCHED\n'
printf 'This command did not delete, shred, rename, or modify the source directory:\n'
printf '  %s\n' "$source_dir"
printf '\nVerify this backup before deleting any source material:\n'
if [ "$no_encrypt" = true ]; then
  printf '  gpg-9-redundant-restore --no-encrypt --dry-run %s\n' "$dest_dir"
else
  printf '  gpg-9-redundant-restore --dry-run %s\n' "$dest_dir"
fi
printf '\nAfter verification, shred regular files in the source directory if appropriate:\n'
printf '  find %q -type f -exec shred -vuz -- {} +\n' "$source_dir"
printf '  find %q -depth -type d -empty -delete\n' "$source_dir"
printf '\nNote: shred is not reliable on all flash media, SSDs, CoW filesystems, or wear-leveling devices. For highest assurance, keep plaintext only on tmpfs such as /dev/shm.\n'
