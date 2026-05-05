#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage:
  gpg-4-finish-local [KEY_FINGERPRINT]

Adds the [A] subkey keygrip to ~/.gnupg/sshcontrol, restarts gpg-agent, and runs
a quick GPG signing test through the inserted YubiKey.

KEY_FINGERPRINT is optional. Resolution order:
  1. positional argument
  2. $KEYFP environment variable
  3. $LOCAL_BACKUP/KEYFP file (default /dev/shm/gpg-new-master/KEYFP)
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

export GPG_TTY="${GPG_TTY:-$(tty)}"
export SSH_AUTH_SOCK="${SSH_AUTH_SOCK:-$(gpgconf --list-dirs agent-ssh-socket)}"

auth_keygrip=$(gpg --list-keys --with-colons --with-keygrip "$keyfp" | awk -F: '
  /^sub:/ { cap=$12; want=(cap ~ /a/) }
  /^grp:/ && want { print $10; exit }
')

if [ -z "$auth_keygrip" ]; then
  printf 'Could not find [A] authentication subkey keygrip for %s\n' "$keyfp" >&2
  exit 1
fi

mkdir -p "$HOME/.gnupg"
chmod 700 "$HOME/.gnupg"
touch "$HOME/.gnupg/sshcontrol"
chmod 600 "$HOME/.gnupg/sshcontrol"

if ! grep -qx "$auth_keygrip" "$HOME/.gnupg/sshcontrol"; then
  printf '%s\n' "$auth_keygrip" >> "$HOME/.gnupg/sshcontrol"
fi

gpgconf --kill gpg-agent
printf 'SSH public keys exposed by gpg-agent:\n'
ssh-add -L

printf '\nSigning test:\n'
printf 'test\n' > /tmp/yubikey-test.txt
rm -f /tmp/yubikey-test.txt.asc
gpg --local-user "$keyfp" --armor --detach-sign /tmp/yubikey-test.txt
gpg --verify /tmp/yubikey-test.txt.asc /tmp/yubikey-test.txt
