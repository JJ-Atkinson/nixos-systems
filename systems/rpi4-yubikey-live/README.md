# Raspberry Pi 4 YubiKey Admin Image

This system defines a minimal Raspberry Pi 4 image for YubiKey, GPG, SSH, and secure key-maintenance work:

```bash
nixosConfigurations.rpi4-yubikey-live
```

The image is configured for `aarch64-linux`, includes the Raspberry Pi 4 hardware module, and builds a compressed SD/USB image named `rpi4-yubikey-live.img`.

## Table Of Contents

- [Operating Constraints](#operating-constraints)
- [Master Key Strategy](#master-key-strategy)
- [Included Tools](#included-tools)
- [Helper Scripts](#helper-scripts)
- [Build And Flash](#build-and-flash)
- [Boot Notes](#boot-notes)
- [Login](#login)
- [Existing Key Reference](#existing-key-reference)
- [Fresh Key Runbook](#fresh-key-runbook)
  - [1. Prepare The Session](#1-prepare-the-session)
  - [2. Check The Clock](#2-check-the-clock)
  - [3. Generate The Master Key And Subkeys](#3-generate-the-master-key-and-subkeys)
  - [4. Prepare The YubiKey](#4-prepare-the-yubikey)
  - [5. Disable Unused Applets](#5-disable-unused-applets)
  - [6. Move Subkeys To The YubiKey](#6-move-subkeys-to-the-yubikey)
  - [7. Enable SSH And Test](#7-enable-ssh-and-test)
  - [8. Publish To The Offline Drive](#8-publish-to-the-offline-drive)
  - [9. Repeat For YubiKeys 2 And 3](#9-repeat-for-yubikeys-2-and-3)
  - [10. Replicate The Drive To Drives 2 And 3](#10-replicate-the-drive-to-drives-2-and-3)
- [Restore Master For Maintenance Operations](#restore-master-for-maintenance-operations)
- [Use This Key On A New Machine (Public Only)](#use-this-key-on-a-new-machine-public-only)
- [YubiKey Applet Policy](#yubikey-applet-policy)
- [Redundant Cold-Storage Files](#redundant-cold-storage-files)
- [Safety Notes](#safety-notes)

## Operating Constraints

The image is intended for keyboard-only use on the Pi console. There is no clipboard. The helper scripts exist primarily to remove typing — long fingerprints, keygrips, and paths are read from environment variables and a `KEYFP` file written by `gpg-1-create-key`, not retyped.

The runbook assumes you will own multiple YubiKeys — at least two, ideally three — distributed across different physical locations. The master key strategy below depends on that assumption.

## Master Key Strategy

The master key is generated with **no passphrase**. The plaintext master secret never leaves RAM-backed storage (`/dev/shm`). Persistence is exclusively via `gpg-7-publish-drive`, which uses `gpg-9-redundant-backup` to encrypt the master to the inserted YubiKey's encryption subkey and writes 40 redundant copy sets with PAR2 recovery data to the USB drive.

This means:

- Master operations (extend expiry, add or revoke subkeys, certify another key) require an unrevoked YubiKey + Admin PIN to decrypt the backup.
- If you ever rotate the YubiKey OpenPGP encryption subkey, every existing `/master-bak/` becomes unreadable. **Re-create `/master-bak/` immediately after any encryption-subkey rotation, while the previous YubiKey is still available to decrypt the old backup.**
- If all YubiKeys are destroyed or lost simultaneously, the master is unrecoverable. With 3 YubiKeys at 3 locations the probability is small enough to accept.

If you would prefer a passphrase-protected master that survives total YubiKey loss, the runbook does not currently cover that variant.

## Included Tools

The image includes the core administration tools needed by the GPG/YubiKey workflow:

- `gnupg`, `pinentry-curses`, `paperkey`
- `pcscd`, `ccid`, GPG smartcard support
- `yubikey-manager`, `yubikey-personalization`, `libfido2`, `opensc`
- `git`, `openssh`, `curl`, `wget`, `rsync`, `magic-wormhole`
- `age`, `sops`, `cryptsetup`, partition and filesystem tools
- `par2cmdline-turbo` plus helper commands for redundant cold-storage backups
- `vim`, `tmux`, `jq`, `usbutils`, `dnsutils`, and basic diagnostics

## Helper Scripts

Installed command names (all live under `systems/rpi4-yubikey-live/scripts/` in the repo):

```text
gpg-0-disk-list                List disks, filesystems, and mount points
gpg-0-disk-mount               Mount a USB partition, with FAT/exFAT user-friendly options
gpg-0-disk-fsck                Repair supported unmounted filesystems
gpg-0-clock                    Check or manually set live-system time
gpg-1-create-key               Create passwordless RSA4096 master + subkeys, export plaintext working backups, generate revocation cert, and write KEYFP
gpg-2-card-policy              Disable unused OTP/PIV applets on USB and NFC
gpg-3-load-card                Drive gpg --edit-key non-interactively to load subkeys onto the YubiKey OpenPGP applet
gpg-3-reimport-master          Re-import the master secret key for the next additional YubiKey (clears ssb> stubs)
gpg-4-finish-local             Add auth keygrip to sshcontrol and run a signing test
gpg-5-export-public            Export GitHub-ready GPG and SSH public key files
gpg-6-import-public            Import a public key and associate the inserted YubiKey
gpg-7-publish-drive            Publish /public, /public-bak, /master-bak, and the redundant-backup scripts onto the mounted USB drive
gpg-9-redundant-backup         Create many checksummed PAR2-protected copy sets
gpg-9-redundant-restore        Recover the first valid or repairable copy set
```

The shell environment (`environment.shellInit`) auto-exports:

```text
GPG_TTY        — current tty
SSH_AUTH_SOCK  — gpg-agent SSH socket
GPG_UID        — default identity for gpg-1-create-key
LOCAL_BACKUP   — /dev/shm/gpg-new-master (plaintext working backups, RAM-backed)
MOUNT_DIR      — /mnt/firstkey (default mount point for the publishing drive)
```

so most helper invocations need no arguments.

It also configures GPG for Linux smartcard use:

- Enables `pcscd`
- Enables the GPG agent with SSH support
- Uses `pinentry-curses`
- Sets `disable-ccid` for `scdaemon` so `pcscd` owns YubiKey access
- Sets `use-keyboxd` for GnuPG 2.4+
- Sets shell defaults for `GPG_TTY` and `SSH_AUTH_SOCK`

The `gpg-agent` is configured with 24-hour TTLs (`pinentry-timeout`, `default-cache-ttl`, `max-cache-ttl`, and the `-ssh` variants) so a single login session does not re-prompt for the YubiKey PIN repeatedly. This is intentional for a single-purpose maintenance image.

## Build And Flash

> [!NOTE]
> Helper script: `systems/rpi4-yubikey-live/build-and-flash.sh` covers both steps. Run with no arguments to see `lsblk` output and instructions; re-invoke under `sudo` with a whole-disk path to build the image and flash it to that device.

> [!CAUTION]
> Flashing overwrites the entire target device. Always pass a whole-disk path (`/dev/sdX`, `/dev/nvme0n1`, `/dev/mmcblk0`) — never a partition path (`/dev/sdX1`). The helper refuses partition arguments and asks you to type `FLASH` to confirm before running `dd`.

Quick path:

```bash
./systems/rpi4-yubikey-live/build-and-flash.sh
# review output, pick the target device, then:
sudo ./systems/rpi4-yubikey-live/build-and-flash.sh /dev/sdX
```

The script builds as `$SUDO_USER` (so the Nix store stays user-owned), unmounts any auto-mounted partitions on the target, runs `zstdcat | dd | sync`, and cleans up its temporary result symlink.

### Manual Equivalent

If you want to perform the steps by hand, the equivalent is:

```bash
nix build .#nixosConfigurations.rpi4-yubikey-live.config.system.build.sdImage
ls result/sd-image                                          # confirm *.img.zst filename
lsblk                                                       # identify whole-disk path
sudo umount /dev/sdX*                                       # unmount any mounted partitions
zstdcat result/sd-image/*.img.zst | sudo dd of=/dev/sdX bs=4M status=progress conv=fsync
sync
```

If the new image files are not yet tracked by git, replace the build flake reference with `'path:/etc/nixos#nixosConfigurations.rpi4-yubikey-live.config.system.build.sdImage'`.

## Boot Notes

The Raspberry Pi 4 can boot from USB only if its EEPROM bootloader is configured for USB boot. If USB boot is not enabled, flash the same image to a microSD card instead.

If an SD card is inserted and the Pi keeps booting from it instead of USB, remove the SD card or configure the Pi EEPROM `BOOT_ORDER` to prefer USB before SD.

## Login

This image is intended for offline, console-only operation. SSH is disabled. There is no remote login path.

Local console login is intentionally passwordless for live-image recovery and key maintenance:

```text
login: jarrett
password: press Enter
```

The `root` account remains locked. The `jarrett` user has passwordless `sudo` through the `wheel` group.

The live image hostname is:

```text
rpi4-yubikey-live
```

## Existing Key Reference

Use this as the compatibility reference when generating a replacement or backup key so the new key is not accidentally created with different capabilities.

Current key identity:

```text
UID: Jarrett R Atkinson (Master SSH GPG Key) <jarrett@freeformsoftware.dev>
Master key: rsa4096/E7A699A45DC0DD8A
Master fingerprint: 129C4A67BB9B6E293E29D2F7E7A699A45DC0DD8A
Created: 2022-05-28
Expires: 2026-05-27
Master capabilities: [SC]
```

Current subkeys:

```text
Encryption subkey: rsa4096/841C678FCEDB379A
Encryption fingerprint: 5C291A10D1CDE021C289FFCA841C678FCEDB379A
Capabilities: [E]
YubiKey card serial: 0006 19026974

Signing subkey: rsa4096/B3E3086C8D881E3E
Signing fingerprint: CF10C199ABBCA149719B344EB3E3086C8D881E3E
Capabilities: [S]
YubiKey card serial: 0006 19026974

Authentication/SSH subkey: rsa4096/04D5BA72721941C2
Authentication fingerprint: FD38A2622F8FECD9E233BAE404D5BA72721941C2
Capabilities: [A]
YubiKey card serial: 0006 19026974
```

To match the existing key layout when starting from scratch, create:

```text
Master: RSA 4096 with Sign + Certify capabilities [SC]
Subkey 1: RSA 4096 Encrypt [E]
Subkey 2: RSA 4096 Sign [S]
Subkey 3: RSA 4096 Authenticate [A]
UID: Jarrett R Atkinson (Master SSH GPG Key) <jarrett@freeformsoftware.dev>
```

The stricter modern layout from the guide is certify-only master `[C]` plus `[S]`, `[E]`, and `[A]` subkeys, usually using ed25519/cv25519. That is valid but intentionally differs from the existing key.

## Fresh Key Runbook

End-to-end flow for creating a new RSA4096 OpenPGP master key, backing it up, loading the subkeys onto each YubiKey, and publishing the redundant cold-storage drive.

The intended key layout is:

```text
Master: RSA4096 [SC]    (passwordless, persisted only as YubiKey-encrypted backup)
Subkey 1: RSA4096 [E]
Subkey 2: RSA4096 [S]
Subkey 3: RSA4096 [A]
```

Do not move the master key to the YubiKey. Only move the `[E]`, `[S]`, and `[A]` subkeys.

> [!IMPORTANT]
> The full runbook (steps 1–10) needs: 3 YubiKeys (or however many you intend to load) and 3 USB drives (or however many separate physical copies of `/master-bak` you want stored). Sections below repeat this hardware list scoped to that step.

### 1. Prepare The Session

> [!IMPORTANT]
> Hardware: USB drive 1 (the publishing drive), inserted and freshly formatted. No YubiKey required yet.

> [!NOTE]
> Helper scripts: `gpg-0-disk-list`, `gpg-0-disk-mount` cover this section automatically.

Log in, plug a freshly-formatted USB drive in, and mount it at `/mnt/firstkey`:

```bash
gpg-0-disk-list
sudo gpg-0-disk-mount /dev/sdXN /mnt/firstkey
```

`GPG_TTY`, `SSH_AUTH_SOCK`, `GPG_UID`, `LOCAL_BACKUP`, and `MOUNT_DIR` are already exported by the shell — no environment setup needed.

### 2. Check The Clock

> [!NOTE]
> Helper script: `gpg-0-clock` covers this section automatically.

GPG key creation and expiration timestamps use the system clock, so set it before generating keys:

```bash
gpg-0-clock
```

If the clock is wrong, set it manually (NixOS prevents `timedatectl set-ntp` because services are declarative):

```bash
gpg-0-clock "2026-05-04 22:30:00"
```

### 3. Generate The Master Key And Subkeys

> [!NOTE]
> Helper script: `gpg-1-create-key` covers this section automatically. Master + subkeys are created in RAM on the Pi only.

```bash
gpg-1-create-key
```

This:

1. Creates a passwordless RSA4096 `[SC]` master with the default 4-year expiry.
2. Adds `[E]`, `[S]`, and `[A]` RSA4096 subkeys.
3. Exports `public-key.asc`, `master-secret-key.asc`, and `secret-subkeys.asc` into `$LOCAL_BACKUP` (default `/dev/shm/gpg-new-master`).
4. Generates `revocation-certificate.asc` (reason: key compromised — the most useful default for an emergency revocation cert).
5. Writes the master fingerprint to `$LOCAL_BACKUP/KEYFP`.

All downstream helpers read `$LOCAL_BACKUP/KEYFP` automatically. There is no manual `export KEYFP=...` step.

To use a different expiry or UID:

```bash
gpg-1-create-key 2 "Some Other Identity <other@example.com>"
```

### 4. Prepare The YubiKey

> [!IMPORTANT]
> Hardware: YubiKey 1 inserted (USB or NFC reader). All previous OpenPGP material on this YubiKey will be wiped if you proceed with the reset.

> [!WARNING]
> This section is **not** fully automated. `gpg-2-card-policy` only handles the OTP/PIV applet policy in step 5. The OpenPGP reset and PIN changes here are deliberately manual — PIN entry is a security boundary that should not be scripted.

Inspect the inserted YubiKey:

```bash
gpgconf --kill all
gpg --card-status
ykman info
```

Reset the OpenPGP applet only when you are certain the inserted YubiKey is the target:

```bash
ykman openpgp reset
```

Default OpenPGP values after reset:

```text
User PIN: 123456
Admin PIN: 12345678
Reset code: not set
```

Change the User PIN and Admin PIN before relying on the key:

```bash
gpg --card-edit
```

Inside `gpg/card>`:

```text
admin
passwd
```

Choose the User PIN and Admin PIN change options, then quit.

### 5. Disable Unused Applets

> [!IMPORTANT]
> Hardware: YubiKey 1 still inserted (the same one you just reset).

> [!NOTE]
> Helper script: `gpg-2-card-policy` covers this section automatically. It also runs `gpgconf --kill all` and `gpg --card-status` first to release any stale agent/scdaemon hold on the card.

```bash
gpg-2-card-policy
```

This disables PIV and OTP universally across both USB and NFC, leaving NFC and the used applets enabled.

Expected enabled applets:

```text
FIDO U2F
FIDO2
OATH
OpenPGP
```

Expected disabled applets:

```text
Yubico OTP
PIV
YubiHSM Auth
```

### 6. Move Subkeys To The YubiKey

> [!IMPORTANT]
> Hardware: YubiKey 1 still inserted, with reset OpenPGP applet and your new Admin PIN set.

> [!NOTE]
> Helper script: `gpg-3-load-card` drives `gpg --edit-key` non-interactively. Only the OpenPGP Admin PIN entry remains manual (one pinentry-curses prompt per subkey).

```bash
gpg-3-load-card
```

The script:

- Resolves `KEYFP` automatically from `$LOCAL_BACKUP/KEYFP`.
- Verifies the plaintext backups (`master-secret-key.asc`, `secret-subkeys.asc`) still exist in `$LOCAL_BACKUP`. If not, it refuses to run — without those backups you cannot load the same identity onto another YubiKey after `save` removes the local secret material.
- Detects whether the local secret keyring already shows `ssb>` card stubs. If yes, it refuses to run because `keytocard` would either no-op or fail; you must re-import the master secret first.
- Drives `gpg --edit-key` non-interactively through `gpg --command-fd`. The keytocard command sequence is built in.
- Runs `gpg --card-status` and lists the local secret keys after the editor exits.

If the `--command-fd` path misbehaves on your hardware, fall back to manual editing:

```bash
gpg-3-load-card --manual
```

This prints the keytocard sequence and opens `gpg --edit-key` for you to type by hand.

After a successful `save`, the local keyring shows `ssb>` stubs:

```text
ssb> rsa4096/... [E]
ssb> rsa4096/... [S]
ssb> rsa4096/... [A]
```

The slot mapping is:

```text
1 = Signature key slot, used by the [S] subkey
2 = Encryption key slot, used by the [E] subkey
3 = Authentication/SSH key slot, used by the [A] subkey
```

### 7. Enable SSH And Test

> [!IMPORTANT]
> Hardware: YubiKey 1 still inserted with all three subkeys loaded.

> [!NOTE]
> Helper script: `gpg-4-finish-local` covers this section automatically. The signing test prompts for the User PIN once.

```bash
gpg-4-finish-local
```

This:

- Reads `KEYFP` automatically.
- Adds the `[A]` subkey keygrip to `~/.gnupg/sshcontrol` (idempotent).
- Restarts `gpg-agent`.
- Prints the SSH public key from `ssh-add -L`.
- Runs a quick GPG signing test through the YubiKey.

For an explicit encryption test (optional):

```bash
gpg --recipient "$(cat $LOCAL_BACKUP/KEYFP)" --encrypt --output /tmp/yubikey-test.gpg /tmp/yubikey-test.txt
gpg --decrypt /tmp/yubikey-test.gpg
```

### 8. Publish To The Offline Drive

> [!IMPORTANT]
> Hardware: USB drive 1 mounted at `/mnt/firstkey` (from step 1) **and** YubiKey 1 inserted (the master is encrypted to its `[E]` subkey).

> [!NOTE]
> Helper script: `gpg-7-publish-drive` covers this section automatically. The internal `gpg-9-redundant-backup` runs prompt for the User PIN once for the encrypted master backup.

```bash
gpg-7-publish-drive
```

This is the safety-critical persistence step. It publishes the identity onto the mounted USB drive at `$MOUNT_DIR` (default `/mnt/firstkey`) in the following layout:

```text
/mnt/firstkey/
├── gpg-9-redundant-backup.sh         # portable copy of backup script
├── gpg-9-redundant-restore.sh        # portable copy of restore script
├── public/
│   ├── import-keys                    # portable script to import on a new machine
│   ├── public-key-gpg                 # armored GPG public key
│   ├── public-key-ssh                 # ssh-add -L line for the [A] subkey
│   └── fingerprint.txt                # master + subkey fingerprint summary
├── public-bak/                        # gpg-9-redundant-backup --no-encrypt of /public
│   └── copy-001/ ... copy-040/
└── master-bak/                        # gpg-9-redundant-backup of master + revocation, encrypted to YubiKey
    └── copy-001/ ... copy-040/
```

Pre-flight refuses to run if `$MOUNT_DIR` is on tmpfs/overlay/ramfs/rootfs, if `/public`, `/public-bak`, or `/master-bak` already exists, if required plaintext files are missing from `$LOCAL_BACKUP`, or if the inserted YubiKey has no encryption subkey.

After publication, verify both backups before shredding any plaintext:

```bash
gpg-9-redundant-restore --dry-run /mnt/firstkey/master-bak
gpg-9-redundant-restore --no-encrypt --dry-run /mnt/firstkey/public-bak
```

The plaintext working backups in `$LOCAL_BACKUP` live on RAM-backed tmpfs and vanish on reboot. They can also be shredded explicitly:

```bash
find /dev/shm/gpg-new-master -type f -exec shred -vuz -- {} +
find /dev/shm/gpg-new-master -depth -type d -empty -delete
```

> [!CAUTION]
> Do not shred `$LOCAL_BACKUP` until you have verified at least one `/master-bak/` copy decrypts cleanly with a YubiKey, and ideally until you have written drives 2 and 3 in step 10. Once the plaintext is gone, the only path back to a usable master goes through a YubiKey + `/master-bak/`.

The files needed for GitHub upload (and any other public distribution) are now sitting on the drive at:

```text
/mnt/firstkey/public/public-key-gpg    # paste into Settings > SSH and GPG keys > New GPG key
/mnt/firstkey/public/public-key-ssh    # paste into Settings > SSH and GPG keys > New SSH key
```

Upload these later from any online machine — the offline Pi never needs network access. They are public-only and contain no secret material.

### 9. Repeat For YubiKeys 2 And 3

> [!IMPORTANT]
> Hardware: the next YubiKey (e.g. YubiKey 2). USB drive 1 should be re-mounted at `/mnt/firstkey` if you unmounted it between steps — `gpg-3-reimport-master` reads `$LOCAL_BACKUP` (RAM), but having the drive mounted means you can spot-check `/master-bak/` after each YubiKey loads. The previous YubiKey can stay inserted on a different USB port for cross-checking, but the OpenPGP commands operate on whichever single card `gpg --card-status` finds first — keep things unambiguous by inserting one card at a time.

> [!NOTE]
> Helper scripts: `gpg-0-disk-list`, `gpg-0-disk-mount` (only if the drive was unmounted), then `gpg-3-reimport-master`, `gpg-2-card-policy`, `gpg-3-load-card`, `gpg-4-finish-local`. Repeat the block once per additional YubiKey. The PIN-entry steps from §4 (OpenPGP reset, PIN change) still apply per YubiKey; do them between `gpg-3-reimport-master` and `gpg-2-card-policy`.

If the drive is not currently mounted at `/mnt/firstkey`, remount it first:

```bash
gpg-0-disk-list
sudo gpg-0-disk-mount /dev/sdXN /mnt/firstkey
```

Then for each additional YubiKey:

```bash
gpg-3-reimport-master
# Then physically swap to the next YubiKey, run §4 manual reset+PIN-change on it,
# then continue:
gpg-2-card-policy
gpg-3-load-card
gpg-4-finish-local
```

`gpg-3-reimport-master` clears the `ssb>` stubs left by the previous load and re-imports the master secret from `$LOCAL_BACKUP/master-secret-key.asc` so `gpg-3-load-card` has real subkey material to move. After step 9's full block runs successfully on a YubiKey, the local keyring is back to `ssb>` stubs — re-run `gpg-3-reimport-master` again before the next YubiKey.

> [!WARNING]
> Each `keytocard` round drops the local subkey secret material onto a YubiKey and removes it from the keyring. The plaintext copy in `$LOCAL_BACKUP/master-secret-key.asc` is what makes the next YubiKey load possible. Do not delete `$LOCAL_BACKUP` until every YubiKey you intend to load is loaded.

Do not run `gpg-7-publish-drive` again per YubiKey — the drive layout is identical regardless of which YubiKey loaded it. `gpg-7-publish-drive` is per-drive (step 10), not per-YubiKey.

> The `gpg-6-import-public` helper is **not** for this case. It imports only a public key for use with an already-loaded YubiKey on a new machine. See "[Use This Key On A New Machine](#use-this-key-on-a-new-machine-public-only)" below.

### 10. Replicate The Drive To Drives 2 And 3

> [!IMPORTANT]
> Hardware: USB drive N (drive 2 or drive 3) and any one of your loaded YubiKeys. The plaintext working backups in `$LOCAL_BACKUP` (RAM tmpfs) must still be present — if you have rebooted, you cannot use the publish path; use rsync instead.

> [!NOTE]
> Helper script: `gpg-7-publish-drive` re-runs cleanly per drive. Each invocation produces fresh PAR2 sets and a freshly encrypted master backup.

You want at least two physical copies of the published drive at separate locations, ideally three. Two approaches:

**A. Re-run `gpg-7-publish-drive` per drive (recommended while `$LOCAL_BACKUP` is still populated).**

Each drive gets its own independently-encrypted `/master-bak/` (different gpg session keys, identical recoverability) and freshly-generated PAR2 data:

```bash
sudo umount /mnt/firstkey
gpg-0-disk-list
sudo gpg-0-disk-mount /dev/sdYN /mnt/firstkey
gpg-7-publish-drive
gpg-9-redundant-restore --dry-run /mnt/firstkey/master-bak
gpg-9-redundant-restore --no-encrypt --dry-run /mnt/firstkey/public-bak
```

Repeat for drive 3. Each drive ends up self-contained with `/gpg-9-redundant-{backup,restore}.sh`, `/public/`, `/public-bak/`, and `/master-bak/`.

**B. `rsync` from drive 1 (faster, but identical encrypted blobs).**

Useful if you have already shredded `$LOCAL_BACKUP` or rebooted. Each drive ends up with bit-identical contents of `/master-bak/`, which is fine for redundancy but means a single ciphertext is stored in three places:

```bash
sudo gpg-0-disk-mount /dev/sdYN /mnt/seconddrive
sudo rsync -av /mnt/firstkey/ /mnt/seconddrive/
sync
sudo umount /mnt/seconddrive
```

After all drives are written, verify each independently. Insert any loaded YubiKey, mount the drive, and run:

```bash
gpg-9-redundant-restore --dry-run /mnt/firstkey/master-bak
gpg-9-redundant-restore --no-encrypt --dry-run /mnt/firstkey/public-bak
```

The dry-run decrypts with your YubiKey but writes nothing. If the encrypted master cannot be decrypted, the drive is unusable for recovery — re-create it before storing.

> [!CAUTION]
> Only after at least two drives verify cleanly should you shred `$LOCAL_BACKUP` and reboot the Pi. A single drive failing in storage years later, with no other copies, is the dominant practical loss path.

## Restore Master For Maintenance Operations

> [!IMPORTANT]
> Hardware: any one of your loaded YubiKeys + any one of your published drives.

When you need to extend the master expiry, add or revoke a subkey, certify another key, or otherwise touch the master, do this on a trusted, networked workstation (not the live image — though the live image works too). With one of your YubiKeys inserted:

```bash
sudo mount /dev/sdXN /mnt/firstkey
mkdir -p /dev/shm/restored-master
gpg-9-redundant-restore /mnt/firstkey/master-bak /dev/shm/restored-master
gpg --import /dev/shm/restored-master/gpg-master-bak/master-secret-key.asc
# do the maintenance op (gpg --edit-key, gpg --quick-set-expire, etc.)
# then refresh the encrypted backup before wiping plaintext:
gpg --armor --export-secret-keys "$KEYFP" > /dev/shm/restored-master/gpg-master-bak/master-secret-key.asc
gpg-9-redundant-backup /dev/shm/restored-master/gpg-master-bak /mnt/firstkey/master-bak.new 40 30
# verify, then atomically replace:
mv /mnt/firstkey/master-bak /mnt/firstkey/master-bak.old
mv /mnt/firstkey/master-bak.new /mnt/firstkey/master-bak
gpg-9-redundant-restore --dry-run /mnt/firstkey/master-bak  # sanity
rm -rf /mnt/firstkey/master-bak.old
find /dev/shm/restored-master -type f -exec shred -vuz -- {} +
```

After this completes on drive 1, propagate the new `/master-bak/` to drives 2 and 3 (rsync each new `/master-bak/` over, then dry-run-restore each).

> [!WARNING]
> If you rotate the YubiKey OpenPGP encryption subkey at any point, `/master-bak/` becomes unreadable to the new YubiKey. Re-create `/master-bak/` immediately afterward, while a YubiKey holding the old encryption subkey is still available — otherwise the encrypted backup is permanently inaccessible.

## Use This Key On A New Machine (Public Only)

> [!IMPORTANT]
> Hardware: any published drive + a YubiKey that already holds the loaded subkeys.

When sitting at a fresh machine that has gnupg installed but does not have this identity yet, plug in the published USB drive and run:

```bash
sh /path/to/drive/public/import-keys
```

Use `sh` explicitly because FAT/exFAT drives auto-mounted by desktop environments are typically mounted `noexec` (and FAT cannot store the executable mode bit anyway), so direct `./import-keys` invocation will fail with "permission denied" on most workstations. The path is wherever your OS mounts the drive — for example `/run/media/$USER/JarrBak1/public/import-keys` on KDE/GNOME, or `/Volumes/JarrBak1/public/import-keys` on macOS.

This portable POSIX script imports the GPG public key, sets ultimate trust on it, and prints SSH setup hints. If a YubiKey holding the matching subkeys is inserted, it also adds the `[A]`-subkey keygrip to `~/.gnupg/sshcontrol`. After running it, you can sign commits and use the YubiKey-backed SSH key normally.

This script does not import any secret material. The new machine still requires a YubiKey with the loaded subkeys to actually sign, decrypt, or authenticate.

`gpg-6-import-public` is the equivalent helper for the live image itself if you ever boot the Pi against a fresh keyring.

## YubiKey Applet Policy

The primary key currently uses these applets:

```text
FIDO U2F/FIDO2: NixOS login, sudo, polkit, and LUKS boot unlock
OpenPGP: GPG signing, encryption, and SSH authentication through gpg-agent
OATH: enabled for authenticator/TOTP use
NFC: enabled
```

The primary key does not use these applets:

```text
PIV: no keys in slots 9A, 9C, 9D, or 9E
OTP: legacy Yubico OTP/challenge-response slots are programmed but not part of the current NixOS/GPG/SSH/LUKS flow
```

For new or backup keys, disable unused PIV and OTP universally across both USB and NFC while leaving the transport and used applets enabled:

```bash
ykman config usb --disable OTP --disable PIV
ykman config nfc --disable OTP --disable PIV
```

Verify the resulting applet policy:

```bash
ykman info
ykman config usb --list
ykman config nfc --list
```

Expected enabled applets after this policy:

```text
FIDO U2F
FIDO2
OATH
OpenPGP
```

Expected disabled applets:

```text
Yubico OTP
PIV
YubiHSM Auth
```

## Redundant Cold-Storage Files

> [!NOTE]
> Helper scripts: `gpg-9-redundant-backup` and `gpg-9-redundant-restore`. They are called automatically by `gpg-7-publish-drive` and can also be run standalone for ad-hoc archives.

For multi-year USB storage, do not rely on one copy of one file. Each backup-set directory contains 40 independent copy directories, each with a tarball, SHA256 checksum, BLAKE2 checksum, and PAR2 recovery data. Encrypted backups target the inserted YubiKey's encryption subkey by default; pass `--no-encrypt` for public data.

Standalone use:

```bash
gpg-9-redundant-backup /dev/shm/gpg-new-master /mnt/firstkey/extra-bak 40 30
gpg-9-redundant-backup --no-encrypt ./public-docs /mnt/firstkey/public-docs-bak 40 30
gpg-9-redundant-restore --dry-run /mnt/firstkey/extra-bak
```

Resulting directory layout:

```text
extra-bak/
  MANIFEST.txt                              # informational record of source/checksums; not consulted by restore
  copy-001/
    gpg-new-master.tar.gz.gpg
    gpg-new-master.tar.gz.gpg.sha256
    gpg-new-master.tar.gz.gpg.b2
    gpg-new-master.tar.gz.gpg.par2
    gpg-new-master.tar.gz.gpg.vol*.par2
  copy-002/
  ...
```

`gpg-9-redundant-restore` finds the first copy set that verifies cleanly, decrypts with the inserted YubiKey, and extracts to the output directory. Verification order per copy: SHA256 → BLAKE2 fallback → PAR2 repair → SHA256 again → BLAKE2 again. PAR2 data covers the payload **and** the SHA256/BLAKE2 sidecars, so a corrupted checksum file by itself does not condemn the copy. The restore helper works in a temporary directory, does not modify the stored copy sets, and deletes intermediate files on exit.

## Safety Notes

The flashing command overwrites the entire target device. Double-check the device path with `lsblk` before running `dd`.

Plaintext private GPG master key material exists only in `/dev/shm` while a session is active. It must never be copied to non-tmpfs storage. The helper scripts enforce this.

The revocation certificate is sensitive. Anyone with it can revoke the public key and cause denial-of-service for that identity. It is deliberately stored only inside the YubiKey-encrypted `/master-bak/` set, which means producing the revocation cert requires an unrevoked YubiKey. If you anticipate a scenario where you'd need to publish a revocation cert without YubiKey access (for example, after suspected compromise where you've already destroyed the YubiKeys), keep an extra paper or air-gapped plaintext copy of `revocation-certificate.asc` at your discretion — at the cost of accepting that anyone who finds that copy can DoS your identity.
