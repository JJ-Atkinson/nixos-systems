#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC2154
trap 'rc=$?; printf "\nERROR: %s exited %d at %s:%d (cmd: %s)\n" "$(basename "$0")" "$rc" "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

printf 'Releasing GPG agent and scdaemon hold on the card...\n'
gpgconf --kill all 2>/dev/null || true

printf '\nGPG card status:\n'
card_status_file=$(mktemp -p /dev/shm gpg-card-status.XXXXXX)
if ! timeout 10s gpg --card-status >"$card_status_file" 2>&1; then
  printf '\ngpg --card-status failed or timed out. Output:\n' >&2
  sed 's/^/  /' "$card_status_file" >&2
  rm -f "$card_status_file"
  exit 1
fi
cat "$card_status_file"
rm -f "$card_status_file"

printf '\nInserted YubiKey before changes:\n'
ykman info

printf '\nThis will disable OTP and PIV over both USB and NFC. It will not disable NFC itself.\n'
printf 'Press Enter to continue, or Ctrl-C to abort.\n'
read -r _

ykman config usb --disable OTP --disable PIV
ykman config nfc --disable OTP --disable PIV

printf '\nInserted YubiKey after changes:\n'
ykman info
printf '\nOpenPGP info:\n'
ykman openpgp info
