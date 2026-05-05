#!/usr/bin/env bash
set -euo pipefail

printf 'Releasing GPG agent and scdaemon hold on the card...\n'
gpgconf --kill all 2>/dev/null || true

printf '\nGPG card status:\n'
gpg --card-status || true

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
