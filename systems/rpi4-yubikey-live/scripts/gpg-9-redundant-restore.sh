#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage:
  gpg-9-redundant-restore [--no-encrypt] [--dry-run] BACKUP_DIR [OUTPUT_DIR]

Restores a backup created by gpg-9-redundant-backup:
  1. Searches copy-* directories for the first valid payload.
  2. Uses SHA256 if clean, otherwise attempts PAR2 repair.
  3. Decrypts the recovered .gpg payload using the inserted YubiKey, unless --no-encrypt is set.
  4. In normal mode, extracts the tar.gz into OUTPUT_DIR.
  5. Deletes intermediate recovered/decrypted files before exit.

Options:
  --no-encrypt  Restore redundant plaintext tar.gz copy sets created with --no-encrypt.
  --dry-run     Validate recoverability without extracting files.

Dry-run mode:
  Decrypts if needed, validates the tar.gz listing, then deletes intermediates.
  It does not write extracted files and does not require OUTPUT_DIR.

Examples:
  gpg-9-redundant-restore --dry-run /mnt/backup/gpg-master-key-backup
  gpg-9-redundant-restore --no-encrypt --dry-run /mnt/backup/public-docs-backup
  gpg-9-redundant-restore /mnt/backup/gpg-master-key-backup /dev/shm/restored-gpg-master
EOF
}

dry_run=false
no_encrypt=false
if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  usage
  exit 0
fi

while [ "${1:-}" = "--dry-run" ] || [ "${1:-}" = "--no-encrypt" ]; do
  case "$1" in
    --dry-run) dry_run=true ;;
    --no-encrypt) no_encrypt=true ;;
  esac
  shift
done

if { [ "$dry_run" = true ] && [ "$#" -ne 1 ]; } || { [ "$dry_run" = false ] && [ "$#" -ne 2 ]; }; then
  usage
  exit 2
fi

backup_dir=$1
output_dir=${2:-}

if [ ! -d "$backup_dir" ]; then
  printf 'Backup directory does not exist: %s\n' "$backup_dir" >&2
  exit 1
fi

tmp_root=$(mktemp -d)
cleanup() {
  rm -rf "$tmp_root"
}
trap cleanup EXIT

checked=0
failed=0
recovery_method=
recovered_payload=
decrypted_archive="$tmp_root/recovered.tar.gz"

print_summary() {
  printf '\nRestore summary:\n'
  printf '  Copy sets checked: %s\n' "$checked"
  printf '  Copy sets failed:  %s\n' "$failed"
  if [ -n "$recovery_method" ]; then
    printf '  Result:            recovered with %s\n' "$recovery_method"
    if [ "$dry_run" = true ]; then
      printf '  Mode:              dry-run validation only\n'
    else
      printf '  Output directory:  %s\n' "$output_dir"
    fi
    if [ "$no_encrypt" = true ]; then
      printf '  Encryption:        no; restored plaintext tar.gz payload\n'
    else
      printf '  Encryption:        yes; decrypted with GPG/YubiKey\n'
    fi
  else
    printf '  Result:            no recoverable copy set found\n'
  fi
}

verify_payload() {
  vp_dir=$1
  vp_name=$2
  if [ -f "$vp_dir/$vp_name.sha256" ] && (cd "$vp_dir" && sha256sum -c "$vp_name.sha256" >/dev/null 2>&1); then
    printf 'SHA256'
    return 0
  fi
  if [ -f "$vp_dir/$vp_name.b2" ] && (cd "$vp_dir" && b2sum -c "$vp_name.b2" >/dev/null 2>&1); then
    printf 'BLAKE2'
    return 0
  fi
  return 1
}

try_copy_dir() {
  copy_dir=$1
  work_dir=$2

  cp -a -- "$copy_dir/." "$work_dir/"

  payload_count=$(find "$work_dir" -maxdepth 1 -type f ! -name '*.sha256' ! -name '*.b2' ! -name '*.par2' | wc -l)
  if [ "$payload_count" -ne 1 ]; then
    printf 'Skipping %s: expected exactly one payload file, found %s\n' "$copy_dir" "$payload_count" >&2
    return 1
  fi

  payload=$(find "$work_dir" -maxdepth 1 -type f ! -name '*.sha256' ! -name '*.b2' ! -name '*.par2' -print -quit)
  payload_name=$(basename "$payload")

  if method=$(verify_payload "$work_dir" "$payload_name"); then
    recovered_payload="$payload"
    recovery_method="$method verification"
    printf 'Recovered from %s using %s verification\n' "$copy_dir" "$method"
    return 0
  fi

  par2_file=$(find "$work_dir" -maxdepth 1 -type f -name '*.par2' ! -name '*.vol*.par2' -print -quit)
  if [ -n "$par2_file" ]; then
    if (cd "$work_dir" && par2 repair -q "$(basename "$par2_file")" >/dev/null 2>&1); then
      if method=$(verify_payload "$work_dir" "$payload_name"); then
        recovered_payload="$payload"
        recovery_method="PAR2 repair + $method verification"
        printf 'Recovered from %s using PAR2 repair + %s verification\n' "$copy_dir" "$method"
        return 0
      fi
    fi
  fi

  printf 'Copy set is not recoverable: %s\n' "$copy_dir" >&2
  return 1
}

for copy_dir in "$backup_dir"/copy-*; do
  [ -d "$copy_dir" ] || continue
  checked=$((checked + 1))
  work_dir=$(mktemp -d "$tmp_root/work.XXXXXX")
  if try_copy_dir "$copy_dir" "$work_dir"; then
    break
  fi
  failed=$((failed + 1))
done

if [ -z "$recovered_payload" ]; then
  printf 'No recoverable copy set found under %s\n' "$backup_dir" >&2
  print_summary >&2
  exit 1
fi

if [ "$no_encrypt" = true ]; then
  printf 'Using recovered plaintext tar.gz payload because --no-encrypt was set.\n'
  cp -- "$recovered_payload" "$decrypted_archive"
else
  printf 'Decrypting recovered payload with GPG/YubiKey...\n'
  gpg --decrypt --output "$decrypted_archive" "$recovered_payload"
fi

if [ "$dry_run" = true ]; then
  printf 'Validating decrypted tar.gz archive listing...\n'
  tar -tzf "$decrypted_archive" >/dev/null
else
  mkdir -p "$output_dir"
  printf 'Extracting decrypted archive into %s\n' "$output_dir"
  tar -xzf "$decrypted_archive" -C "$output_dir"
fi

print_summary
printf '\nIntermediate recovered and decrypted files were stored under a temporary directory and have been scheduled for deletion on exit.\n'
