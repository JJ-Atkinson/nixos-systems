# Plan A — Imminent build: disko + bootable NixOS wiring for RAID1 `nixos`

## Context

The desktop system `nixos` currently uses a hand-rolled `systems/nixos/fs-opts.nix` with manually-specified `fileSystems.*`, `boot.initrd.luks.devices.*`, and `swapDevices`, all on a single LUKS-encrypted btrfs on `/dev/nvme0n1` (a WD_BLACK SN7100 with media errors, pending RMA). VM storage already lives on a second SN7100 (`/dev/nvme1n1`) with its own `@vm-images` / `@vm-shared` subvolumes.

Both 2 TB drives (WD + Solidigm) are already physically installed. Goal: replace the hand-rolled layout with a single declarative disko-driven config in which either disk can fail without data loss, hibernation continues to work, boot survives a missing disk without dropping to emergency shell, and (per Plan B, later) the user is notified within hours when a disk is degrading. The migration is destructive; recovery path is restic.

Per recorded preferences: **no filesystem snapshots** (restic offsite is sufficient).

**Working tree location:** `~/nixos/` (fresh clone synced with the remote).

Plan A is self-contained: after it's done, the system boots and survives single-disk loss. Existing `smart-error-watch.nix` and `btrfs-scrub.nix` continue to work unchanged. Observability cleanup and additional monitors are deferred to `plan-b-observability-followup.md`.

## A.1 Goal

After Plan A:

- The system boots from RAID1 storage (data + metadata) across WD + Solidigm.
- One typed passphrase unlocks all three LUKS containers (two btrfs legs + cryptswap), via systemd's initrd password cache.
- Hibernation works (cryptswap holds the resume image; `boot.resumeDevice` auto-set by disko's `resumeDevice = true`).
- With one disk physically missing, boot proceeds via the survivor: mdadm arrays auto-degrade, btrfs mounts `degraded`, and the cryptsetup unit for the missing disk fails quickly without blocking boot.
- Existing `smart-error-watch.nix` / `btrfs-scrub.nix` continue to function (with mountpoint touch-up deferred to Plan B).

## A.2 Canonical disko patterns being followed

| Concern | Source example (disko rev `9165064`) |
|---|---|
| Empty LUKS on disk_a + LUKS-with-btrfs-content on disk_b, joined via `mkfs.btrfs` extraArgs | `example/luks-btrfs-raid.nix` |
| Dual ESP via mdadm RAID1 with `metadata=1.0` so UEFI can read either half | `example/boot-raid1.nix` |
| Interactive passphrase (`askPassword = true`) | already used in `systems/nixos-framework/disko.nix` |
| Subvolume layout | already used in `systems/nixos-framework/disko.nix` |

Note from `luks-btrfs-raid.nix`: *"Devices will be mounted and formatted in alphabetical order, and btrfs can only mount raids when all devices are present"* — attribute names (`disk_a`, `disk_b`) determine which disk gets the empty LUKS and which carries the btrfs config. Load-bearing.

## A.3 Files

### New: `systems/nixos/disko.nix`

```nix
{
  disko.devices = {
    disk = {
      # disk_a: WD — by-id path filled in at install time, NOT /dev/nvmeXnY
      disk_a = {
        type = "disk";
        device = "/dev/disk/by-id/nvme-WDC_…";
        content.type = "gpt";
        content.partitions = {
          ESP = { size = "1G"; type = "EF00";
            content = { type = "mdraid"; name = "boot"; }; };
          swap_raid = { size = "70G";
            content = { type = "mdraid"; name = "swap"; }; };
          crypt = { size = "100%";
            content = {
              type = "luks";
              name = "cryptbtrfs_a";
              askPassword = true;
              settings.allowDiscards = true;
              # NOTE: no btrfs content here — disko opens this LUKS first;
              # mkfs runs from disk_b and references /dev/mapper/cryptbtrfs_a.
            };
          };
        };
      };

      # disk_b: Solidigm — carries the btrfs filesystem definition
      disk_b = {
        type = "disk";
        device = "/dev/disk/by-id/nvme-SOLIDIGM_…";
        content.type = "gpt";
        content.partitions = {
          ESP = { size = "1G"; type = "EF00";
            content = { type = "mdraid"; name = "boot"; }; };
          swap_raid = { size = "70G";
            content = { type = "mdraid"; name = "swap"; }; };
          crypt = { size = "100%";
            content = {
              type = "luks";
              name = "cryptbtrfs_b";
              askPassword = true;
              settings.allowDiscards = true;
              content = {
                type = "btrfs";
                extraArgs = [ "-L cryptbtrfs" "-d raid1" "-m raid1"
                              "/dev/mapper/cryptbtrfs_a" ];
                subvolumes = {
                  "@"      = { mountpoint = "/";
                               mountOptions = [ "compress=zstd" "ssd" "noatime" "degraded" ]; };
                  "@home"  = { mountpoint = "/home";
                               mountOptions = [ "compress=zstd" "ssd" "noatime" "degraded" ]; };
                  "@nix"   = { mountpoint = "/nix";
                               mountOptions = [ "compress=zstd" "ssd" "noatime" "degraded" ]; };
                  "@log"   = { mountpoint = "/var/log";
                               mountOptions = [ "compress=zstd" "ssd" "noatime" "degraded" ]; };
                  "@vm-images" = {
                    mountpoint = "/vm-storage/images";
                    mountOptions = [ "ssd" "noatime" "degraded" ];  # NO compress
                    postCreateHook = ''
                      MNT=$(mktemp -d)
                      mount -o subvol=@vm-images /dev/mapper/cryptbtrfs_b "$MNT"
                      ${pkgs.e2fsprogs}/bin/chattr +C "$MNT"
                      umount "$MNT" && rmdir "$MNT"
                    '';
                  };
                  "@vm-shared" = {
                    # Pre-RAID this held qcow2 images; same nodatacow/no-compress treatment as @vm-images.
                    mountpoint = "/vm-storage/shared";
                    mountOptions = [ "ssd" "noatime" "degraded" ];
                    postCreateHook = ''
                      MNT=$(mktemp -d)
                      mount -o subvol=@vm-shared /dev/mapper/cryptbtrfs_b "$MNT"
                      ${pkgs.e2fsprogs}/bin/chattr +C "$MNT"
                      umount "$MNT" && rmdir "$MNT"
                    '';
                  };
                };
              };
            };
          };
        };
      };
    };

    mdadm = {
      # Dual-ESP mirror — UEFI sees either half because metadata=1.0
      boot = {
        type = "mdadm";
        level = 1;
        metadata = "1.0";
        content = {
          type = "filesystem";
          format = "vfat";
          mountpoint = "/boot";
          mountOptions = [ "umask=0077" ];
        };
      };

      # Mirrored, encrypted, hibernation-capable swap.
      # mdadm RAID1 (modern metadata=1.2) → LUKS w/ same passphrase as the
      # btrfs pair → swap. `resumeDevice = true` makes disko set boot.resumeDevice.
      swap = {
        type = "mdadm";
        level = 1;
        metadata = "1.2";
        content = {
          type = "luks";
          name = "cryptswap";
          askPassword = true;
          settings.allowDiscards = true;
          content = {
            type = "swap";
            resumeDevice = true;
          };
        };
      };
    };
  };
}
```

### Modified: `systems/nixos/fs-opts.nix`

Strip everything filesystem-related (disko owns it now). Keep:

- `boot.initrd.availableKernelModules`, `boot.initrd.kernelModules`, `boot.kernelModules`, `boot.extraModulePackages`
- `boot.initrd.systemd.enable = true;` — required for the systemd-cryptsetup password cache that deduplicates the LUKS prompt across all three containers
- `powerManagement.enable`
- `hardware.cpu.intel.updateMicrocode`

Remove:

- All `fileSystems.*` entries (`/`, `/home`, `/nix`, `/var/log`, `/swap`, `/vm-storage/images`, `/vm-storage/shared`)
- `boot.initrd.luks.devices."cryptbtrfs".*`
- `swapDevices`

### Unchanged: `systems/nixos/hw-opts.nix`

Not touched by Plan A. Of particular note, the NVMe HMB cap carries over verbatim:

```nix
boot.kernelParams = [ "nvme.max_host_mem_size_mb=512" ];
```

This was tuned for two SN7100s (hmpre=78 MiB / hmmin=32 MiB each) to avoid the partial-allocation regression that contributed to the 2026-05-18 csum-error incident. The cap is a ceiling, not a floor, so the Solidigm will draw its own preferred amount up to 512 MiB independently. Post-install, confirm with `nvme id-ctrl /dev/nvme{0,1} | grep -iE 'hmpre|hmmin'` that the Solidigm's reported preferences are within the cap and that both controllers achieve their preferred allocation under load. If the Solidigm reports very different HMB needs the cap may want re-tuning — track as a Plan B follow-up only if the post-install check reveals an issue.

### Modified: `flake.nix` — nixosConfigurations.nixos block (around lines 76–84)

Mirror what the framework already does (lines 149/151):

```nix
modules = [
  disko.nixosModules.disko                       # new
  ./systems/nixos/disko.nix                      # new
  ./systems/nixos/initrd-luks-tolerant.nix       # new (see below)
  ./systems/nixos/fs-opts.nix                    # trimmed, but stays
  ./systems/nixos/hw-opts.nix
  ./systems/nixos/etc.nix
  …
];
```

`disko` is already an input (flake.nix:13–14) and already destructured (line 35) — no `inputs` edits needed.

### New: `systems/nixos/initrd-luks-tolerant.nix` — degraded-boot guard

A small NixOS module that ensures a missing LUKS leg fails quickly and does not block boot. Without this, `systemd-cryptsetup@cryptbtrfs_a.service` waits the default ~90 s on its source `.device` unit, then fails, and the resulting failure mode may drop to emergency shell depending on target dependencies.

Concretely:

```nix
{ lib, ... }:
{
  boot.initrd.systemd.services."systemd-cryptsetup@cryptbtrfs_a" = {
    unitConfig.JobTimeoutSec = "30s";
    # Don't propagate failure: btrfs `degraded` mount will pick up the survivor.
    unitConfig.OnFailure = lib.mkForce [ ];
  };
  boot.initrd.systemd.services."systemd-cryptsetup@cryptbtrfs_b" = {
    unitConfig.JobTimeoutSec = "30s";
    unitConfig.OnFailure = lib.mkForce [ ];
  };

  # cryptsetup.target by default Wants= (not Requires=) its members in NixOS,
  # so one failing member should not fail the target. Verify in failure drill;
  # if it does fail, override here.

  # btrfs `degraded` mount option must be present at first mount, not added
  # later — already in disko.nix mountOptions above.
}
```

Add to the imports in flake.nix alongside the disko import (shown above).

**This module's correctness is verified by the failure drill in A.5.** If the drill reveals the system still drops to emergency shell, the override is adjusted before declaring Plan A done.

### Device-name strategy

Use `/dev/disk/by-id/nvme-<MODEL>_<SERIAL>` in `disko.nix`, not `/dev/nvmeXnY`. NVMe enumeration is not stable across reboots in this kernel; pinning to physical identity prevents a future reseat/RMA from silently swapping the disk_a / disk_b roles. Resolve the actual `by-id` strings at install time with `lsblk -o NAME,MODEL,SERIAL,WWN` (or `ls -la /dev/disk/by-id/`).

## A.4 Post-install procedure

1. Boot installer USB. Make `~/nixos` available (clone fresh or mount from local backup).
2. `lsblk -o NAME,MODEL,SERIAL` → fill the two `by-id` paths into `~/nixos/systems/nixos/disko.nix`.
3. `sudo nix run github:nix-community/disko/latest -- --mode destroy,format,mount ~/nixos/systems/nixos/disko.nix` — prompts for the same passphrase three times at format (once per LUKS container).
4. `sudo nixos-install --flake ~/nixos#nixos`.
5. **Place the host age key** so sops-nix can decrypt secrets on first boot (otherwise `std-backup-restic.nix` and `modules/pgadmin.nix` fail to activate — both reference `/var/lib/sops-nix/keys.txt`):
   ```
   sudo install -d -m 0700 -o root -g root /mnt/var/lib/sops-nix
   sudo install -m 0400 -o root -g root \
     /run/media/rescue/FIRMWARE/host-age-key.txt \
     /mnt/var/lib/sops-nix/keys.txt
   ```
   The USB mount point (`/run/media/rescue/FIRMWARE`) is whatever the installer auto-mounted the FIRMWARE-labeled stick at — adjust if the label/mount differs.
6. Reboot. Confirm a single passphrase prompt unlocks all three containers (cache hit on the second and third). Confirm `systemctl status sops-nix.service` is `active (exited)` and `journalctl -u restic-remote-backup` shows no decrypt failures next time the timer fires.
7. Enroll YubiKey FIDO2 — symmetric default:
   ```
   sudo systemd-cryptenroll /dev/disk/by-partlabel/disk-disk_a-crypt --fido2-device=auto
   sudo systemd-cryptenroll /dev/disk/by-partlabel/disk-disk_b-crypt --fido2-device=auto
   sudo systemd-cryptenroll /dev/md/swap                              --fido2-device=auto
   ```
   Three touches per cold boot. Asymmetric (single-touch via cache) alternative documented in A.6 — choose after first boot.
8. Restore from restic:
   ```
   restic-remote restore latest --target / --include /home/jarrett --include /etc/nixos
   ```
9. Re-attach VM images from backup / libvirt pool definitions to `/vm-storage/{images,shared}`.

## A.5 Verification (all must pass before declaring Plan A complete)

- `btrfs filesystem df /` → `Data, RAID1` and `Metadata, RAID1`
- `btrfs filesystem show` → both devices listed under one UUID
- `lsattr -d /vm-storage/images /vm-storage/shared` → `C` flag present on both
- `mount | grep btrfs` → `degraded` present in options for all subvolumes
- `cat /proc/mdstat` → both `md/boot` and `md/swap` active, both legs `[UU]`
- `swapon --show` → cryptswap mapper listed as active swap
- `cat /sys/power/resume` → matches the cryptswap device (proves `boot.resumeDevice` set)
- `bootctl status` → systemd-boot installed, finds entries on `/boot`
- **Cold-boot test:** single passphrase prompt; all three LUKS open; system reaches login.
- **Hibernate test:** `systemctl hibernate`, wait for power-off, power on → session restored.
- **Failure drill (critical for Plan A correctness):** with both disks healthy, simulate disk_a loss via `echo 1 > /sys/block/<nvmeN>/device/delete`, reboot, confirm:
  - Boot proceeds past `systemd-cryptsetup@cryptbtrfs_a` failure within ~30 s, no emergency shell.
  - Surviving cryptbtrfs_b opens, btrfs mounts via `degraded`.
  - `md/boot` and `md/swap` come up degraded `[U_]`, system still boots and swap activates.
  - System reaches login.
  - `journalctl -b -p warning` shows the failure but boot continued.

  If emergency shell is reached, adjust `initrd-luks-tolerant.nix` until it isn't. Repeat for disk_b loss.

  Recovery after re-attach: `mdadm --add /dev/md/boot <part>` and `mdadm --add /dev/md/swap <part>` for the mdadm legs, then `btrfs replace start <missing-devid> /dev/mapper/cryptbtrfs_a /` (or balance with `-dconvert=raid1 -mconvert=raid1` if single-profile chunks were written while degraded).

- Existing `services.btrfsScrubNotifier` and `services.smartErrorWatch` still function (scrub now runs on one filesystem instead of two; SMART module reads SNs at runtime so no device-list edit needed). Touch-up of these modules is **Plan B**.
- **HMB sanity check:** `nvme id-ctrl /dev/nvme{0,1} | grep -iE 'hmpre|hmmin'` shows both controllers' preferences; `cat /sys/module/nvme/parameters/max_host_mem_size_mb` shows `512`; no `nvme: HMB allocation failed` or partial-allocation warnings in `dmesg`.

## A.6 FIDO2 touch-count tradeoff (post-install decision)

- **3-touch symmetric (default):** enrol on all three containers. Either disk can fail without changing the boot UX.
- **1-touch asymmetric:** enrol only on `cryptbtrfs_a` (say). systemd's password cache then unlocks the other two from the FIDO2-derived passphrase. Cleaner UX but the `cryptbtrfs_a` disk becomes the "primary" — if it's the one that fails, you fall through to typed passphrase.

This is purely a `systemd-cryptenroll` choice, no disko changes. Re-evaluate after first cold boot.

## A.7 Explicitly NOT in Plan A (see `plan-b-observability-followup.md`)

- New runtime monitors for btrfs forced-RO transitions, mdadm degradation, and missing-device-at-boot
- Consolidating `btrfs-scrub.nix` to one filesystem (currently lists two mountpoints that will become subvolumes of the same FS)
- Reviewing `smart-error-watch.nix` device list and considering by-id paths
- Snapshots — out per recorded preference
