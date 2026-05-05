#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage:
  gpg-3-reimport-master [KEY_FINGERPRINT]

Re-imports the master secret key into the local keyring so the next
gpg-3-load-card run has real subkey material to move (not ssb> stubs).

Use this between YubiKey loads when loading the same identity onto multiple
YubiKeys.

KEY_FINGERPRINT is optional. Resolution order:
  1. positional argument
  2. $KEYFP environment variable
  3. $LOCAL_BACKUP/KEYFP file (default /dev/shm/gpg-new-master/KEYFP)

Steps performed:
  1. Verify $LOCAL_BACKUP/master-secret-key.asc exists.
  2. Confirm with the user.
  3. gpg --delete-secret-keys $KEYFP
  4. gpg --import $LOCAL_BACKUP/master-secret-key.asc
  5. List keys to confirm real ssb (not ssb>) records are present.
EOF
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  usage
  exit 0
fi

if [ "$#" -gt 1 ]; then
  usage
  exit 2
fi

local_backup=${LOCAL_BACKUP:-/dev/shm/gpg-new-master}
keyfp=${1:-${KEYFP:-}}
if [ -z "$keyfp" ] && [ -r "$local_backup/KEYFP" ]; then
  keyfp=$(cat "$local_backup/KEYFP")
fi
if [ -z "$keyfp" ]; then
  printf 'KEY_FINGERPRINT could not be resolved.\n' >&2
  # shellcheck disable=SC2016
  printf 'Pass it as an argument, set $KEYFP, or run gpg-1-create-key first.\n' >&2
  exit 2
fi

master_backup="$local_backup/master-secret-key.asc"
if [ ! -s "$master_backup" ]; then
  printf 'Missing master backup: %s\n' "$master_backup" >&2
  printf 'Cannot re-import without it.\n' >&2
  exit 1
fi

printf 'About to delete the local secret keyring entry for %s and re-import from:\n' "$keyfp"
printf '  %s\n' "$master_backup"
printf 'Continue? [y/N] '
read -r ans
case "$ans" in
  y|Y|yes|YES) ;;
  *) printf 'Aborted.\n'; exit 1 ;;
esac

gpg --batch --pinentry-mode loopback --passphrase '' --yes --delete-secret-keys "$keyfp"
gpg --pinentry-mode loopback --passphrase '' --import "$master_backup"

printf '\nLocal keyring after re-import:\n'
gpg --list-secret-keys --keyid-format LONG --with-subkey-fingerprint "$keyfp"

if gpg --list-secret-keys --keyid-format LONG --with-subkey-fingerprint "$keyfp" 2>/dev/null | grep -q '^ssb>'; then
  printf '\nWarning: ssb> stubs are still present. Re-import may not have replaced them.\n' >&2
  exit 1
fi

printf '\nReady to run: gpg-2-card-policy && gpg-3-load-card && gpg-4-finish-local on the next YubiKey.\n'
