#!/usr/bin/env sh
# Portable script. Lives on the published drive at /public/import-keys.
# Requires: gpg (gnupg 2.x). Optional: an already-inserted YubiKey holding the
# subkeys for this identity.
#
# Imports the GPG public key from the same /public/ directory, sets ultimate
# trust on it, and prints next-step hints for SSH and YubiKey association.

set -eu

self_dir=$(cd "$(dirname "$0")" && pwd)
public_key="$self_dir/public-key-gpg"
ssh_key="$self_dir/public-key-ssh"
fingerprint_file="$self_dir/fingerprint.txt"

if [ ! -r "$public_key" ]; then
  printf 'Cannot read %s\n' "$public_key" >&2
  printf 'This script expects to live in /public next to public-key-gpg.\n' >&2
  exit 1
fi

if ! command -v gpg >/dev/null 2>&1; then
  printf 'gpg is not in PATH. Install gnupg first.\n' >&2
  exit 1
fi

printf 'Importing %s\n' "$public_key"
gpg --import "$public_key"

keyfp=$(gpg --import-options show-only --with-colons --import "$public_key" 2>/dev/null \
  | awk -F: '/^fpr:/ { print $10; exit }')

if [ -z "$keyfp" ]; then
  printf 'Could not determine fingerprint of imported key.\n' >&2
  exit 1
fi

printf '\nSetting ultimate trust on %s\n' "$keyfp"
gpg --command-fd 0 --status-fd 2 --edit-key "$keyfp" >/dev/null 2>&1 <<EOF
trust
5
y
quit
EOF

if [ -r "$fingerprint_file" ]; then
  printf '\nIdentity summary:\n'
  cat "$fingerprint_file"
fi

printf '\n--- Next steps ---\n'
printf '\n1. Insert the YubiKey holding the subkeys for this identity.\n'
printf '2. Run: gpg --card-status\n'
printf '   This populates card stubs (ssb>) in your local keyring.\n'

if gpg --card-status >/dev/null 2>&1; then
  printf '\nYubiKey detected. Running gpg --card-status now ...\n'
  gpg --card-status >/dev/null
fi

if [ -r "$ssh_key" ]; then
  printf '\n3. SSH via gpg-agent: append the [A]-subkey keygrip to ~/.gnupg/sshcontrol.\n'
  auth_keygrip=$(gpg --list-keys --with-colons --with-keygrip "$keyfp" 2>/dev/null | awk -F: '
    /^sub:/ { cap=$12; want=(cap ~ /a/) }
    /^grp:/ && want { print $10; exit }
  ')
  if [ -n "$auth_keygrip" ]; then
    sshcontrol="$HOME/.gnupg/sshcontrol"
    mkdir -p "$HOME/.gnupg"
    chmod 700 "$HOME/.gnupg"
    touch "$sshcontrol"
    chmod 600 "$sshcontrol"
    if grep -qx "$auth_keygrip" "$sshcontrol" 2>/dev/null; then
      printf '   Already present in %s — nothing to do.\n' "$sshcontrol"
    else
      printf '%s\n' "$auth_keygrip" >> "$sshcontrol"
      printf '   Added %s to %s.\n' "$auth_keygrip" "$sshcontrol"
    fi
    printf '   Then enable gpg-agent SSH support and restart it:\n'
    printf '     echo "enable-ssh-support" >> ~/.gnupg/gpg-agent.conf\n'
    printf '     gpgconf --kill gpg-agent\n'
    # shellcheck disable=SC2016
    printf '     export SSH_AUTH_SOCK="$(gpgconf --list-dirs agent-ssh-socket)"\n'
    printf '     ssh-add -L\n'
  else
    printf '   Could not detect [A]-subkey keygrip yet. Run gpg --card-status with the YubiKey inserted, then re-run this script.\n'
  fi

  printf '\n   Public SSH key for reference (also at %s):\n' "$ssh_key"
  printf '   '
  cat "$ssh_key"
fi

printf '\n4. To recover the master key for maintenance ops (extend expiry, add subkeys, certify), restore from /master-bak using gpg-9-redundant-restore on a trusted machine.\n'
