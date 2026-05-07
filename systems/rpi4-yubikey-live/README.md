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
- [Common Tasks](#common-tasks)
  - [Mount The Publishing Drive](#mount-the-publishing-drive)
  - [Set The System Clock](#set-the-system-clock)
  - [Reset A YubiKey And Set New PINs](#reset-a-yubikey-and-set-new-pins)
  - [Load Subkeys Onto A Prepared YubiKey](#load-subkeys-onto-a-prepared-yubikey)
  - [Publish A Drive](#publish-a-drive)
  - [Verify A Published Drive](#verify-a-published-drive)
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
  - [9. Load An Additional YubiKey (#2 Now; #3 After §11)](#9-load-an-additional-yubikey-2-now-3-after-11)
  - [10. Replicate The Drive To Drives 2 And 3](#10-replicate-the-drive-to-drives-2-and-3)
  - [11. Reload Working State After Reboot](#11-reload-working-state-after-reboot)
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
gpg-8-restore-state            After a reboot, rehydrate $LOCAL_BACKUP and the keychain from any published drive
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

## Common Tasks

These reusable procedures are referenced from `Fresh Key Runbook` steps below. Each subsection is the single source of truth for that procedure.

- [Mount the publishing drive](#mount-the-publishing-drive)
- [Set the system clock](#set-the-system-clock)
- [Reset a YubiKey and set new PINs](#reset-a-yubikey-and-set-new-pins)
- [Load subkeys onto a prepared YubiKey](#load-subkeys-onto-a-prepared-yubikey)
- [Publish a drive](#publish-a-drive)
- [Verify a published drive](#verify-a-published-drive)

### Mount The Publishing Drive

> [!NOTE]
> Helper scripts: `gpg-0-disk-list`, `gpg-0-disk-mount`.

```bash
gpg-0-disk-list
gpg-0-disk-mount /dev/sdXN /mnt/firstkey
```

`GPG_TTY`, `SSH_AUTH_SOCK`, `GPG_UID`, `LOCAL_BACKUP`, and `MOUNT_DIR` are already exported by the shell — no environment setup needed.

### Set The System Clock

> [!NOTE]
> Helper script: `gpg-0-clock`.

GPG key creation/expiration timestamps and `gpg --import` (after a reboot) both depend on the system clock. Set it before any GPG operation on a freshly-booted Pi.

```bash
gpg-0-clock
```

If the clock is wrong, set it manually (NixOS prevents `timedatectl set-ntp` because services are declarative):

```bash
gpg-0-clock "2026-05-04 22:30:00"
```

### Reset A YubiKey And Set New PINs

> [!WARNING]
> This procedure is **not** automated. PIN entry is a security boundary that should not be scripted. All previous OpenPGP material on the inserted YubiKey will be wiped if you proceed with the reset.

> [!WARNING]
> The `ykman openpgp reset` step is mandatory per YubiKey when loading subkeys onto multiple cards. Skipping it leaves the previous OpenPGP applet state in place — `gpg-3-load-card`'s `keytocard` will refuse to overwrite occupied slots, or worse, will silently leave a mix of old and new subkeys.

Inspect the inserted YubiKey, reset the OpenPGP applet, and change the User and Admin PINs:

```bash
gpgconf --kill all
gpg --card-status
ykman info
ykman openpgp reset
gpg --card-edit
```

Inside `gpg/card>`:

```text
admin
passwd
```

Choose the User PIN and Admin PIN change options, then quit.

Default OpenPGP values immediately after `ykman openpgp reset`:

```text
User PIN: 123456
Admin PIN: 12345678
Reset code: not set
```

### Load Subkeys Onto A Prepared YubiKey

> [!IMPORTANT]
> Run this on a YubiKey that has been reset and has new PINs set (see [Reset a YubiKey and set new PINs](#reset-a-yubikey-and-set-new-pins)).

> [!NOTE]
> Helper scripts: `gpg-2-card-policy`, `gpg-3-load-card`, `gpg-4-finish-local`. Run them in order.

```bash
gpg-2-card-policy
gpg-3-load-card
gpg-4-finish-local
```

What each does:

- **`gpg-2-card-policy`** disables PIV and OTP universally across both USB and NFC. Runs `gpgconf --kill all` and `gpg --card-status` first to release any stale agent/scdaemon hold on the card. Expected enabled applets afterward: FIDO U2F, FIDO2, OATH, OpenPGP. Disabled: Yubico OTP, PIV, YubiHSM Auth.
- **`gpg-3-load-card`** drives `gpg --edit-key` non-interactively to move the `[E]`, `[S]`, and `[A]` subkeys onto the OpenPGP applet. Resolves `KEYFP` from `$LOCAL_BACKUP/KEYFP`. Verifies `master-secret-key.asc` and `secret-subkeys.asc` still exist in `$LOCAL_BACKUP` — without those, the next YubiKey load is impossible after `save` removes the local secret material. Refuses to run if the local secret keyring already shows `ssb>` card stubs (must re-import the master secret first via `gpg-3-reimport-master`). Only the OpenPGP Admin PIN entry remains manual (one pinentry-curses prompt per subkey). If the `--command-fd` path misbehaves on your hardware, fall back to manual editing with `gpg-3-load-card --manual` — this prints the keytocard sequence and opens `gpg --edit-key` for you to type by hand.
- **`gpg-4-finish-local`** adds the `[A]` subkey keygrip to `~/.gnupg/sshcontrol` (idempotent), restarts `gpg-agent`, prints the SSH public key from `ssh-add -L`, and runs a quick GPG signing test through the YubiKey (prompts for the User PIN once).

After a successful `save` inside `gpg-3-load-card`, the local keyring shows `ssb>` stubs:

```text
ssb> rsa4096/... [E]
ssb> rsa4096/... [S]
ssb> rsa4096/... [A]
```

OpenPGP applet slot mapping:

```text
1 = Signature key slot, used by the [S] subkey
2 = Encryption key slot, used by the [E] subkey
3 = Authentication/SSH key slot, used by the [A] subkey
```

### Publish A Drive

> [!IMPORTANT]
> Hardware: a mounted USB drive at `$MOUNT_DIR` (default `/mnt/firstkey`) and a YubiKey holding the loaded subkeys (the master is encrypted to its `[E]` subkey — the helper refuses to run without one).

> [!NOTE]
> Helper script: `gpg-7-publish-drive`. Internally calls `gpg-9-redundant-backup` and prompts for the User PIN once for the encrypted master backup.

```bash
gpg-7-publish-drive
```

Resulting layout on the drive:

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

After publication, run [Verify a published drive](#verify-a-published-drive) before relying on this drive for recovery.

### Verify A Published Drive

> [!IMPORTANT]
> Hardware: drive mounted + a YubiKey holding the loaded subkeys.

```bash
gpg-9-redundant-restore --dry-run /mnt/firstkey/master-bak
gpg-9-redundant-restore --no-encrypt --dry-run /mnt/firstkey/public-bak
```

The dry-run decrypts with your YubiKey but writes nothing. If the encrypted `master-bak` cannot be decrypted, the drive is unusable for recovery — re-create it before storing.

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

Log in, plug in the drive, and run [Mount the publishing drive](#mount-the-publishing-drive).

### 2. Check The Clock

Run [Set the system clock](#set-the-system-clock). GPG key creation and expiration timestamps depend on it.

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
> Hardware: YubiKey 1 inserted (USB or NFC reader).

Run [Reset a YubiKey and set new PINs](#reset-a-yubikey-and-set-new-pins) on YubiKey 1.

### 5. Disable Unused Applets

> [!IMPORTANT]
> Hardware: YubiKey 1 still inserted (the same one you just reset).

```bash
gpg-2-card-policy
```

Disables PIV and OTP across both USB and NFC. See [Load subkeys onto a prepared YubiKey](#load-subkeys-onto-a-prepared-yubikey) for the expected applet result and the next two helpers.

### 6. Move Subkeys To The YubiKey

> [!IMPORTANT]
> Hardware: YubiKey 1 still inserted, with reset OpenPGP applet and your new Admin PIN set.

```bash
gpg-3-load-card
```

Moves the `[E]`, `[S]`, and `[A]` subkeys onto the OpenPGP applet. Prompts for the Admin PIN once per subkey via pinentry-curses. See [Load subkeys onto a prepared YubiKey](#load-subkeys-onto-a-prepared-yubikey) for what the script does, the slot mapping, and the `--manual` fallback.

### 7. Enable SSH And Test

> [!IMPORTANT]
> Hardware: YubiKey 1 still inserted with all three subkeys loaded.

```bash
gpg-4-finish-local
```

Adds the `[A]` keygrip to `sshcontrol`, restarts `gpg-agent`, and runs a signing test (prompts for the User PIN once). See [Load subkeys onto a prepared YubiKey](#load-subkeys-onto-a-prepared-yubikey) for details.

For an explicit encryption test (optional):

```bash
gpg --recipient "$(cat $LOCAL_BACKUP/KEYFP)" --encrypt --output /tmp/yubikey-test.gpg /tmp/yubikey-test.txt
gpg --decrypt /tmp/yubikey-test.gpg
```

### 8. Publish To The Offline Drive

> [!IMPORTANT]
> Hardware: USB drive 1 mounted at `/mnt/firstkey` (from §1) **and** YubiKey 1 inserted.

This is the safety-critical persistence step. Run [Publish a drive](#publish-a-drive), then [Verify a published drive](#verify-a-published-drive) before doing anything destructive.

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

### 9. Load An Additional YubiKey (#2 Now; #3 After §11)

> [!IMPORTANT]
> Hardware: the next YubiKey to load. The previous YubiKey can stay inserted on a different USB port for cross-checking, but the OpenPGP commands operate on whichever single card `gpg --card-status` finds first — keep things unambiguous by inserting one card at a time.

> [!NOTE]
> Recommended cadence: load YubiKey **#2** here, then run §10 (replicate drives) and §11 (reboot + reload working state) **before** loading YubiKey **#3**. Doing §11 between #2 and #3 forces a real-world test of the cold-recovery path while you still have the in-RAM plaintext as a fallback. After §11 returns you to end-of-§7 state, come back here for #3.

For each additional YubiKey:

1. (If the drive was unmounted between steps) Run [Mount the publishing drive](#mount-the-publishing-drive) — `gpg-3-reimport-master` only reads `$LOCAL_BACKUP` (RAM), but having the drive mounted lets you spot-check `/master-bak/` after each load.
2. Re-import the master so subkey material is movable again:
   ```bash
   gpg-3-reimport-master
   ```
3. Physically swap to the next YubiKey, then run [Reset a YubiKey and set new PINs](#reset-a-yubikey-and-set-new-pins) on it.
4. Run [Load subkeys onto a prepared YubiKey](#load-subkeys-onto-a-prepared-yubikey).

`gpg-3-reimport-master` clears the `ssb>` stubs left by the previous load and re-imports the master secret from `$LOCAL_BACKUP/master-secret-key.asc` so `gpg-3-load-card` has real subkey material to move. After the block runs successfully on a YubiKey, the local keyring is back to `ssb>` stubs — re-run `gpg-3-reimport-master` again before the next YubiKey.

> [!WARNING]
> Each `keytocard` round drops the local subkey secret material onto a YubiKey and removes it from the keyring. The plaintext copy in `$LOCAL_BACKUP/master-secret-key.asc` is what makes the next YubiKey load possible. Do not delete `$LOCAL_BACKUP` until every YubiKey you intend to load is loaded.

Do not run `gpg-7-publish-drive` again per YubiKey — the drive layout is identical regardless of which YubiKey loaded it. `gpg-7-publish-drive` is per-drive (§10), not per-YubiKey.

> The `gpg-6-import-public` helper is **not** for this case. It imports only a public key for use with an already-loaded YubiKey on a new machine. See "[Use This Key On A New Machine](#use-this-key-on-a-new-machine-public-only)" below.

### 10. Replicate The Drive To Drives 2 And 3

> [!IMPORTANT]
> Hardware: USB drive N (drive 2 or drive 3) and any one of your loaded YubiKeys. The plaintext working backups in `$LOCAL_BACKUP` (RAM tmpfs) must still be present for Approach A — if you have rebooted, only Approach B (rsync) works.

You want at least two physical copies of the published drive at separate locations, ideally three.

**A. Re-run the publish per drive (recommended while `$LOCAL_BACKUP` is still populated).**

Each drive gets its own independently-encrypted `/master-bak/` (different gpg session keys, identical recoverability) and freshly-generated PAR2 data. Per drive:

1. Insert any loaded YubiKey.
2. Unmount the previous drive: `sudo umount /mnt/firstkey`.
3. Run [Mount the publishing drive](#mount-the-publishing-drive) with the new drive's partition path.
4. Run `gpg --card-status` to confirm the encryption subkey is present.
5. Run [Publish a drive](#publish-a-drive).
6. Run [Verify a published drive](#verify-a-published-drive).

Repeat for drive 3. Each drive ends up self-contained with `/gpg-9-redundant-{backup,restore}.sh`, `/public/`, `/public-bak/`, and `/master-bak/`.

**B. `rsync` from drive 1 (faster, but identical encrypted blobs).**

Useful if you have already shredded `$LOCAL_BACKUP` or rebooted. Each drive ends up with bit-identical contents of `/master-bak/`, which is fine for redundancy but means a single ciphertext is stored in three places:

```bash
gpg-0-disk-mount /dev/sdYN /mnt/seconddrive
sudo rsync -av /mnt/firstkey/ /mnt/seconddrive/
sync
sudo umount /mnt/seconddrive
```

After all drives are written, run [Verify a published drive](#verify-a-published-drive) on each independently before storing.

> [!CAUTION]
> Only after at least two drives verify cleanly should you shred `$LOCAL_BACKUP` and reboot the Pi. A single drive failing in storage years later, with no other copies, is the dominant practical loss path.

### 11. Reload Working State After Reboot

> [!IMPORTANT]
> Hardware: any one published USB drive + any one of your loaded YubiKeys. Use this when you've rebooted the Pi between loading YubiKeys (or when you want to prove end-to-end recoverability before locking everything away).

> [!NOTE]
> Helper script: `gpg-8-restore-state` covers this entire section. It runs `import-keys`, `gpg-9-redundant-restore`, copies the master + revocation cert into `$LOCAL_BACKUP`, imports the master into the local keychain, writes `$LOCAL_BACKUP/KEYFP`, and re-attaches YubiKey stubs.

After a reboot, `/dev/shm` is empty and the gpg keychain is gone. The Pi has no RTC, so the system clock is also wrong on cold boot — gpg will refuse to import a key whose creation date appears to be in the future. Set the clock first.

1. Run [Set the system clock](#set-the-system-clock) — pass an explicit `"YYYY-MM-DD HH:MM:SS"` since there's no NTP source on the offline image.
2. Run [Mount the publishing drive](#mount-the-publishing-drive).
3. Then:
   ```bash
   gpg-8-restore-state
   ```

> [!WARNING]
> If you skip the clock step, `gpg --import` inside `gpg-8-restore-state` will print a "key was created N days in the future — time warp" warning and **the import silently produces zero keys**. Downstream commands will then fail in confusing ways. Always set the clock first on a freshly-rebooted Pi.

When `gpg-8-restore-state` exits cleanly, `$LOCAL_BACKUP` has the same shape it did at the end of §7 (`master-secret-key.asc`, `revocation-certificate.asc`, `public-key.asc`, `KEYFP`), the master is in the local keychain, and `gpg --card-status` shows the inserted YubiKey's stubs.

**Now go back to [§9](#9-load-an-additional-yubikey-2-now-3-after-11) with YubiKey #3.** After #3 finishes, you are done with the runbook — shred `$LOCAL_BACKUP` (or just power off, since it is RAM-backed) and lock the YubiKeys + drives in their respective storage locations.

> [!CAUTION]
> If `gpg-9-redundant-restore` (called from inside `gpg-8-restore-state`) fails to decrypt `master-bak` on this drive, that drive is unusable for recovery — try another. If all drives fail, the YubiKey `[E]` subkey doesn't match what was used at publish time and the encrypted backup is permanently inaccessible.

> [!WARNING]
> After this restores plaintext into `$LOCAL_BACKUP`, treat that directory as sensitive again — it now contains the master and revocation cert. Either proceed straight to §9 to load another YubiKey and then shred per §8's caution, or reboot before stepping away. `$LOCAL_BACKUP` is RAM-backed and vanishes on power-off.

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
