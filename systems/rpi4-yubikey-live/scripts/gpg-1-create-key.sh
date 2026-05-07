#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC2154
trap 'rc=$?; printf "\nERROR: %s exited %d at %s:%d (cmd: %s)\n" "$(basename "$0")" "$rc" "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

usage() {
  cat >&2 <<'EOF'
Usage:
  gpg-1-create-key [YEARS] [UID]

Generates a passwordless RSA4096 [SC] master with [E], [S], [A] RSA4096 subkeys,
exports plaintext working backups to $LOCAL_BACKUP, and generates a revocation
certificate. Plaintext secrets stay in $LOCAL_BACKUP (RAM-backed by default) and
never touch removable media. Persistence is handled later by gpg-7-publish-drive,
which encrypts the master to the inserted YubiKey.

Defaults:
  YEARS = 4
  UID   = $GPG_UID (set by shellInit)

Environment:
  LOCAL_BACKUP   plaintext export directory (default /dev/shm/gpg-new-master)
  GPG_UID        default identity if UID positional is omitted
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

years=${1:-4}
gpg_uid=${2:-${GPG_UID:-}}
local_backup=${LOCAL_BACKUP:-/dev/shm/gpg-new-master}

if [ -z "$gpg_uid" ]; then
  printf 'GPG_UID is not set. Pass UID as the 2nd argument or export GPG_UID.\n' >&2
  exit 2
fi

case "$years" in
  ''|*[!0-9]*) printf 'YEARS must be a positive integer\n' >&2; exit 2 ;;
esac

export GPG_TTY="${GPG_TTY:-$(tty)}"
export SSH_AUTH_SOCK="${SSH_AUTH_SOCK:-$(gpgconf --list-dirs agent-ssh-socket)}"

mkdir -p "$local_backup"
chmod 700 "$local_backup"

before=$(mktemp)
after=$(mktemp)
cleanup() {
  rc=$?
  if [ "$rc" -ne 0 ]; then
    printf 'Failure (rc=%d). Fingerprint diff temp files were:\n  before=%s\n  after=%s\n' "$rc" "$before" "$after" >&2
  fi
  rm -f "$before" "$after"
}
trap cleanup EXIT

gpg --list-secret-keys --with-colons --fingerprint | awk -F: '/^fpr:/ { print $10 }' | sort > "$before"

printf 'Creating passwordless RSA4096 [SC] master for: %s\n' "$gpg_uid"
gpg --batch --pinentry-mode loopback --passphrase '' \
    --quick-generate-key "$gpg_uid" rsa4096 cert,sign "${years}y"

gpg --list-secret-keys --with-colons --fingerprint | awk -F: '/^fpr:/ { print $10 }' | sort > "$after"
keyfp=$(comm -13 "$before" "$after" | head -n 1)

if [ -z "$keyfp" ]; then
  printf 'Could not determine newly-created fingerprint. List keys manually with:\n' >&2
  printf '  gpg --list-secret-keys --keyid-format LONG --with-subkey-fingerprint\n' >&2
  exit 1
fi

printf 'New master fingerprint: %s\n' "$keyfp"
printf 'Adding passwordless RSA4096 [E], [S], and [A] subkeys...\n'
gpg --batch --pinentry-mode loopback --passphrase '' \
    --quick-add-key "$keyfp" rsa4096 encr "${years}y"
gpg --batch --pinentry-mode loopback --passphrase '' \
    --quick-add-key "$keyfp" rsa4096 sign "${years}y"
gpg --batch --pinentry-mode loopback --passphrase '' \
    --quick-add-key "$keyfp" rsa4096 auth "${years}y"

printf 'Exporting plaintext working backups to RAM: %s\n' "$local_backup"
gpg --armor --export "$keyfp" > "$local_backup/public-key.asc"
[ -s "$local_backup/public-key.asc" ] || { printf 'gpg --armor --export %s produced empty output\n' "$keyfp" >&2; exit 1; }
gpg --armor --export-secret-keys "$keyfp" > "$local_backup/master-secret-key.asc"
[ -s "$local_backup/master-secret-key.asc" ] || { printf 'gpg --armor --export-secret-keys %s produced empty output\n' "$keyfp" >&2; exit 1; }
gpg --armor --export-secret-subkeys "$keyfp" > "$local_backup/secret-subkeys.asc"
[ -s "$local_backup/secret-subkeys.asc" ] || { printf 'gpg --armor --export-secret-subkeys %s produced empty output\n' "$keyfp" >&2; exit 1; }

printf 'Generating revocation certificate (reason: key compromised)...\n'
gpg --pinentry-mode loopback --passphrase '' \
    --command-fd 0 --status-fd 2 \
    --output "$local_backup/revocation-certificate.asc" \
    --gen-revoke "$keyfp" <<'EOF'
y
1

y
EOF

printf '%s\n' "$keyfp" > "$local_backup/KEYFP"
chmod 600 "$local_backup"/*

printf '\nKey layout:\n'
gpg --list-secret-keys --keyid-format LONG --with-subkey-fingerprint "$keyfp"

printf '\nFiles in %s:\n' "$local_backup"
ls -lh "$local_backup"

printf '\nFingerprint stored at %s/KEYFP — downstream helpers read it automatically.\n' "$local_backup"
printf '\nNext commands (no args needed):\n'
printf '  gpg-2-card-policy\n'
printf '  gpg-3-load-card\n'
printf '  gpg-4-finish-local\n'
printf '  gpg-5-export-public\n'
printf '  gpg-7-publish-drive\n'
