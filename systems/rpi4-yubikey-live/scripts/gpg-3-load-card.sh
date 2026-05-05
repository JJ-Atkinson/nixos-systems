#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage:
  gpg-3-load-card [--manual] [--i-have-backups] [--continue-with-stubs] [KEY_FINGERPRINT]

Loads the [E], [S], [A] subkeys onto the inserted YubiKey via gpg --edit-key.
By default the keytocard sequence is driven non-interactively through gpg
--command-fd; you only have to type the OpenPGP Admin PIN at each pinentry
prompt.

KEY_FINGERPRINT is optional. Resolution order:
  1. positional argument
  2. $KEYFP environment variable
  3. $LOCAL_BACKUP/KEYFP file (default /dev/shm/gpg-new-master/KEYFP)

Pre-flight checks:
  - master-secret-key.asc and secret-subkeys.asc exist in $LOCAL_BACKUP.
    Override with --i-have-backups (acknowledges responsibility for backups).
  - The local secret keyring still contains real subkey material, not card
    stubs (ssb>). If stubs are present you must re-import the master from
    backup before another keytocard run. Override with --continue-with-stubs.

Options:
  --manual                Skip non-interactive editor; print the keytocard
                          command sequence and open gpg --edit-key for you to
                          type by hand. Use only if --command-fd misbehaves.
  --i-have-backups        Skip the backup-existence pre-flight.
  --continue-with-stubs   Skip the stub-detection pre-flight.
EOF
}

manual=false
allow_no_backups=false
allow_stubs=false
keyfp=

while [ "$#" -gt 0 ]; do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --manual) manual=true; shift ;;
    --i-have-backups) allow_no_backups=true; shift ;;
    --continue-with-stubs) allow_stubs=true; shift ;;
    --*) usage; exit 2 ;;
    *)
      if [ -n "$keyfp" ]; then usage; exit 2; fi
      keyfp=$1
      shift
      ;;
  esac
done

local_backup=${LOCAL_BACKUP:-/dev/shm/gpg-new-master}

if [ -z "$keyfp" ]; then
  keyfp=${KEYFP:-}
fi
if [ -z "$keyfp" ] && [ -r "$local_backup/KEYFP" ]; then
  keyfp=$(cat "$local_backup/KEYFP")
fi
if [ -z "$keyfp" ]; then
  printf 'KEY_FINGERPRINT could not be resolved.\n' >&2
  # shellcheck disable=SC2016
  printf 'Pass it as an argument, set $KEYFP, or run gpg-1-create-key first.\n' >&2
  exit 2
fi

export GPG_TTY="${GPG_TTY:-$(tty)}"

if [ "$allow_no_backups" = false ]; then
  missing=
  for f in master-secret-key.asc secret-subkeys.asc; do
    if [ ! -s "$local_backup/$f" ]; then
      missing="$missing $f"
    fi
  done
  if [ -n "$missing" ]; then
    printf 'Refusing to run keytocard. Missing plaintext backup file(s) in %s:%s\n' "$local_backup" "$missing" >&2
    printf 'After save, the moved subkey secret material is removed from the local keyring.\n' >&2
    printf 'Without these backups you cannot load this identity onto another YubiKey.\n' >&2
    printf 'Resolve by running gpg-1-create-key first, or pass --i-have-backups if you have an external backup.\n' >&2
    exit 1
  fi
fi

if [ "$allow_stubs" = false ]; then
  if gpg --list-secret-keys --keyid-format LONG --with-subkey-fingerprint "$keyfp" 2>/dev/null | grep -q '^ssb>'; then
    printf 'Local keyring already shows ssb> stubs for this key — secret subkey material is not present locally.\n' >&2
    printf 'Running keytocard now would be a no-op or fail mid-edit.\n' >&2
    printf 'Re-import the master secret first:\n' >&2
    printf '  gpg --delete-secret-keys %s\n' "$keyfp" >&2
    printf '  gpg --import %s/master-secret-key.asc\n' "$local_backup" >&2
    printf 'Or pass --continue-with-stubs to ignore this check.\n' >&2
    exit 1
  fi
fi

printf 'Current card status:\n'
gpg --card-status || true

printf '\nLocal key layout for %s:\n' "$keyfp"
gpg --list-secret-keys --keyid-format LONG --with-subkey-fingerprint "$keyfp"

if [ "$manual" = true ]; then
  printf '\nManual mode: open gpg --edit-key now and run the following commands.\n'
  printf 'Verify subkey order with list before using these commands. Expected order is [E], [S], [A].\n\n'
  cat <<'EOF'
list
key 1
keytocard
2
key 1
key 2
keytocard
1
key 2
key 3
keytocard
3
save
EOF
  printf '\nPress Enter to open gpg --edit-key, or Ctrl-C to abort.\n'
  read -r _
  gpg --edit-key "$keyfp"
else
  printf '\nDriving gpg --edit-key non-interactively. You will be prompted by pinentry-curses for the OpenPGP Admin PIN at each keytocard step.\n'
  printf 'Subkey order assumed: [E], [S], [A].\n'
  printf 'Press Enter to begin, or Ctrl-C to abort.\n'
  read -r _
  gpg --command-fd 0 --status-fd 2 --edit-key "$keyfp" <<'EOF'
list
key 1
keytocard
2
key 1
key 2
keytocard
1
key 2
key 3
keytocard
3
save
EOF
fi

printf '\nPost-load verification:\n'
gpg --card-status
gpg --list-secret-keys --keyid-format LONG --with-subkey-fingerprint "$keyfp"
