# Solidigm replacement — status and handoff

Updated: **October 22, 2026, after 15:16 CDT**. Host: `nixos` (`/etc/nixos`).

## Current checkpoint

**The Solidigm has been physically replaced, both mirrors reconstructed, and both ESPs populated. A final normal reboot remains unverified.**

- Protected survivor: WD_BLACK SN7100 2TB, serial `25306L805271`, currently `/dev/nvme1n1` (`disk_a`, Btrfs device 2).
- New replacement: WD_BLACK SN7100 2TB, serial `25156Z800969`, currently `/dev/nvme0n1` (`disk_b`, Btrfs device 1).
- Both disks have exact capacity 2,000,398,934,016 bytes. The replacement was confirmed blank and SMART-clean before initialization; no survivor partitions were reformatted or repartitioned.
- The host successfully booted degraded after the physical swap, using the prepared UUID-based root configuration and survivor ESP.
- Only the new disk received a GPT, 1 GiB ESP, 70 GiB swap member, and remaining-space LUKS2 root partition, with the expected `disk_b` partition labels.
- New LUKS2 root has a passphrase plus FIDO2 enrollment in key slot 1. FIDO2 unlocking was verified by closing and reopening only `cryptbtrfs_b`; mapper size is 1,924,145,348,608 bytes.
- Btrfs replacement of missing device **1** completed at **14:58:09 CDT**, with zero write errors and zero uncorrectable read errors. Device **2** was preserved. Normal reconstruction necessarily updated filesystem/RAID metadata on the survivor.
- Existing swap md array UUID and encrypted swap contents were preserved. The new partition joined successfully; synchronization finished at approximately **15:05 CDT**, clean with **`[UU]`**.
- `/boot` remains the survivor ESP; `/boot-fallback` is the new ESP, formatted FAT32 with label `BOOT_B`. Boot files were copied survivor-to-replacement and checksum-based rsync comparison showed no differences, including the EFI fallback loader.
- `systems/nixos/disko.nix` now pins `disk_b.device` to `/dev/disk/by-id/nvme-WD_BLACK_SN7100_2TB_25156Z800969`; `nix eval` confirmed it. No full disko installer or bootloader rebuild was run during this reconstruction.
- Post-replacement scrub started at **15:07:49 CDT**, finished in **7m17s**, and reported zero read/checksum/verify/corrected/uncorrectable errors. This does not checksum-validate NOCOW/nodatasum VM image contents.
- Verification exposed three empty `single` block groups. A filtered `-dconvert=raid1,soft -mconvert=raid1,soft` balance relocated three chunks. At **15:16 CDT**, data, metadata, and system were exclusively RAID1, `Multiple profiles: no`, and `Device missing: 0`.
- New member error counters are all zero. Survivor counters retain four historical corruption errors and zero read/write/flush/generation errors, unchanged from baseline.
- Expected 1 GiB slack remains on the replacement mapper due to the preparatory shrink; resizing is not required.

### Remaining verification

1. Save work and perform a normal reboot with both WDs installed. Have the passphrase and FIDO2 key available.
2. Verify both root containers unlock, both Btrfs members are present, RAID1-only profiles remain, swap is active with `[UU]`, both ESPs mount to their intended disks, and there are no unexpected failed services.
3. A normal boot from the survivor does not prove independent firmware boot selection of the replacement ESP. Actual replacement-ESP boot/failover and hibernation/resume remain untested.
4. Do not reconnect the removed Solidigm as an ordinary filesystem/RAID member: it contains stale metadata and duplicate identities.

No commit or reset has been performed; unrelated existing changes remain preserved.

## Archived pre-swap handoff — October 21, 2026

**The following sections are historical and are superseded by the current checkpoint above. In particular, their statements that the swap has not happened and the old remaining-work sequence no longer describe the live system.**

### Historical checkpoint

**The preparatory Btrfs shrink is complete. The physical swap has NOT happened.**

- Both original NVMe disks remain installed.
- Missing-drive boot configuration is implemented, builds successfully, and has passed disposable VM tests.
- The running system still uses the old boot configuration: its `/etc/fstab` mounts root through `/dev/mapper/cryptbtrfs_b` (the Solidigm).
- Installation and a verification reboot of the prepared generation have **not been confirmed**.
- The guarded **post-swap replacement helper has not been written**.
- **Do not remove the Solidigm yet.** Finish the helper and verify the new boot generation first.

The agreed sequence is **resize first → install boot generation → verification reboot with both original disks → shut down and swap → reconstruct mirrors**. The resize-first step is now done.

## Hardware and storage layout

| Role | Installed disk | Serial | Exact capacity |
| --- | --- | --- | ---: |
| `disk_a`, survivor | WD_BLACK SN7100 2TB | `25306L805271` | 2,000,398,934,016 bytes |
| `disk_b`, to remove | SOLIDIGM SSDPFKNU020TZ | `PHEH308200MD2P0C` | 2,048,408,248,320 bytes |
| Replacement | User's spare WD_BLACK SN7100 2TB | **Not yet identified** | Must be verified |

The Solidigm is about 48 GB larger despite both products being described as 2 TB.

Each original NVMe has:

1. A 1 GiB FAT EFI partition: `/boot` on `disk_a`, `/boot-fallback` on `disk_b`.
2. A 70 GiB md RAID1 member partition. The array contains LUKS `cryptswap`, then swap.
3. A LUKS root member: `cryptbtrfs_a` or `cryptbtrfs_b`. Together they contain Btrfs RAID1 data, metadata, and system chunks.

Important identities:

```text
Btrfs filesystem UUID: 6137e9a6-e9b2-49e6-9ac4-03e044ee845a
Btrfs device 1:        Solidigm / cryptbtrfs_b — replace this member
Btrfs device 2:        WD       / cryptbtrfs_a — preserve this member
Swap md UUID:          25eb788e:0c293850:a21dc655:0086fa90
Swap md name:          /dev/md/swap (kernel name can be md127)
```

Partition labels use `disk-disk_a-{ESP,swap_raid,crypt}` and `disk-disk_b-{ESP,swap_raid,crypt}`. Runtime boot wiring uses these labels; disko also records the physical disks' by-id paths. Never infer a role from `nvme0` versus `nvme1` numbering.

## Completed work

### Kernel and memory

- Linux **7.3** is running.
- Zswap is enabled with LZ4, an on-demand pool capped at 20% of RAM, and its shrinker disabled for the initial experiment.
- Swappiness remains 10; existing encrypted disk swap is retained.
- Graphical autostart configuration was reduced to Firefox and 1Password; other applications remain installed.

### Disk investigation

- The Solidigm and WD receive approximately the same mirrored write volume, but the Solidigm showed much higher write/discard latency and utilization.
- PostgreSQL checkpoints/WAL and `ej_livekit` development/test processes were prominent writers during observation.
- The Solidigm negotiates PCIe Gen4 ×4, has write caching enabled, and received a 78 MiB host-memory buffer. No obvious link/cache misconfiguration was established.
- SMART preflight: both drives passed, with zero media/data-integrity errors and zero recorded warning/critical temperature time. WD endurance used: 3%; Solidigm: 6%.
- Solidigm firmware is 002C; vendor lists 004C. The documented 004C change concerns shutdown-edge-case data safety, not a confirmed fix for current write/TRIM latency. A public P41 Plus 003C changelog was not found. **No firmware was flashed.**

### Boot-resilience implementation

`systems/nixos/initrd-luks-tolerant.nix` now:

- Mounts the root filesystem and its subvolumes by their shared Btrfs UUID rather than depending on the Solidigm mapper.
- Allows either encrypted root member to be absent, with a 30-second source-device timeout.
- Waits for both root unlock attempts before scanning available Btrfs members.
- Overrides systemd's incomplete-Btrfs readiness gate **only for this filesystem UUID**.
- Uses `x-initrd.attach` to keep encrypted mappings attached across the boot handoff.
- Identifies the existing swap RAID by UUID and starts it degraded if necessary. Inactive arrays can report an all-zero sysfs UUID, so the helper also verifies an on-disk member UUID and locates the array holding it.
- Uses a genuine cryptsetup **drop-in**, avoiding the earlier full-unit-shadowing problem recorded in the old recovery notes.
- Makes either EFI partition optional with a bounded timeout and promotes the surviving fallback ESP to `/boot` if the primary ESP is absent.

`systems/nixos/hw-opts.nix` also guards ESP mirroring against an unmounted source or copying a promoted ESP onto itself.

### Live Btrfs shrink — completed

The user ran `sudo bash /etc/nixos/bin/desktop-disk-prepare-size` in an actual terminal at approximately **17:45 CDT on October 21** and confirmed `SHRINK-SOLIDIGM`.

```text
Solidigm Btrfs device 1, before: 1,972,154,400,768 bytes
Solidigm Btrfs device 1, after:  1,923,071,606,784 bytes
WD Btrfs device 2, unchanged:    1,924,145,348,608 bytes
```

The new logical member size leaves 1 GiB below the existing WD's usable encrypted size. This prepares the filesystem's recorded missing-member geometry for replacement with a smaller physical drive.

The operation completed in about eight seconds. **No partitions or LUKS containers were resized, no RAID profiles were converted, and no disks were erased.** Error counters were unchanged: Solidigm all zero; WD four historical corruption errors and zero I/O/generation errors.

## Validation

### Physical host checks

- Preflight showed both root members present and swap RAID1 clean with `[UU]`.
- The October 21 midnight Btrfs scrub finished in 28m15s with zero read, checksum, verification, corrected, or uncorrectable errors.
- Scrub cannot verify the contents of NOCOW/nodatasum VM image data using Btrfs data checksums.
- The user considers the existing restic backup/check regime sufficient; additional restic verification is **not a requested blocker**.

### Disposable VM tests — passed

`tests/mirrored-root.nix` exercises the actual host recovery module using encrypted virtual disks and Linux 7.3. It verifies:

1. Normal boot with both members.
2. WD-equivalent survivor only: boot from its actual ESP, mount encrypted Btrfs degraded, activate encrypted swap degraded.
3. Pre-shrink the larger member, remove it, reconstruct missing Btrfs device 1 onto a smaller encrypted replacement, preserve a fixture file, restore swap `[UU]`, and complete a scrub.
4. Solidigm-equivalent survivor only: boot from its ESP, mount root degraded, promote that ESP to `/boot`, and activate degraded swap.

Missing-member cases are modeled by removing the virtual disk's partitions/signatures before reboot. Tests do not pass through or modify physical host disks.

Evidence for the successful final run:

```text
Test derivation:
/nix/store/7fsackiba3h28rqbjvvx2nvnyj8vqnr0-vm-test-run-desktop-mirrored-root.drv
Test result link:
/tmp/opencode/mirrored-root-migration-test
Host build link:
/tmp/opencode/nixos-missing-drive
Saved test log:
/tmp/opencode/mirrored-root-passed.log
```

These tests do **not** prove real motherboard firmware failover, actual hibernation/resume, FIDO2 interaction with a missing member, or a bootloader rebuild while running on a promoted ESP. Keep the planned physical-host verification checkpoint.

## Remaining work and sequence

### 1. Prepare the post-swap helper BEFORE removing the Solidigm

**Not implemented yet.** It must explicitly select and confirm the replacement's model/serial, validate capacity and health, and refuse to overwrite the surviving WD or unrelated Samsung SATA disk. The spare is not assumed to be blank or healthy.

The helper/procedure needs to:

- Obtain explicit permission to erase the replacement disk's contents.
- Create the replacement `disk_b` ESP, swap member, and root partitions with the expected labels.
- Create/open its LUKS root container with a user-entered passphrase; optionally enroll the YubiKey. Do not store passphrases in scripts or the Nix store.
- Check actual usable mapper size against the now-shrunken Btrfs device 1 size.
- Run `btrfs replace` against **missing device ID 1**, preserving device 2. Do not format the new root partition as a separate Btrfs filesystem first.
- Add the replacement swap partition to the existing md array. **Do not recreate the md array or its LUKS/swap contents.**
- Format/populate only the replacement ESP and restore two bootable ESPs.
- Update `disk_b.device` in `systems/nixos/disko.nix` to the replacement's actual by-id path.
- Verify Btrfs replacement completion, RAID1 profiles, swap synchronization, boot files, error counters, and scrub results.
- Handle partial completion safely; do not blindly rerun destructive initialization.

### 2. Install the tested boot generation

Run in a real terminal (the command harness cannot read sudo passwords):

```bash
sudo nixos-rebuild boot --flake /etc/nixos#nixos
```

This installs the next boot generation without switching the running system. Check that installation and ESP mirroring finish successfully.

### 3. Reboot with BOTH original disks still connected

Save work first. After reboot verify:

- The new boot generation is running.
- `/etc/fstab` uses `/dev/disk/by-uuid/6137e9a6-e9b2-49e6-9ac4-03e044ee845a` for root/subvolumes.
- Both root containers are open, both Btrfs members are present, and swap is active with `[UU]`.
- Both ESPs are mounted and contain the prepared generation.
- The new readiness/promotion services have no unexpected failures.

Do not interpret a successful build alone as confirmation that the host has booted the new configuration.

### 4. Shut down fully and physically exchange disks

Only after the helper is ready and the verification reboot succeeds: power off, remove the **Solidigm**, and install the spare SN7100. Leave the existing WD (`25306L805271`) untouched. Do not hibernate for this operation.

### 5. Boot from the surviving WD and initialize the replacement

Expect a bounded delay for the missing root member. Boot should use the WD's ESP and mount root degraded; the replacement will not join automatically. Run the guarded helper/procedure from step 1, confirming disk identity and entering the encryption passphrase.

### 6. Reconstruct and verify

Allow reconstruction to finish before declaring the migration complete. Avoid heavy writes and inhibit suspend/hibernate during replacement. Recheck health, both mirrors, scrub, ESP contents, and the final NixOS disk identity. Plan a final normal reboot after both disks are ready.

## Safety constraints

- **Do not run the full disko installer** against the installed system. It is not a replacement-disk-only operation.
- Do not remove/reformat the existing WD, recreate the swap array, or change Btrfs RAID1 to `single` for this migration.
- Do not reconnect the removed Solidigm as an ordinary member after the filesystem has accepted degraded writes or replacement. It will contain stale Btrfs/md metadata and duplicate identities; any later reuse needs an explicit isolation/wipe plan.
- Do not promise that an arbitrary blank drive is automatically rebuilt. Replacement initialization requires explicit disk selection and consent.
- Maintain access to the encryption passphrase and recovery media. Firmware boot selection may need manual intervention on the real motherboard.
- Existing unrelated `flake.lock` changes were present before this work and were preserved. No commit or reset has been performed.

## Files and commands

| Path | Purpose |
| --- | --- |
| `systems/nixos/initrd-luks-tolerant.nix` | Missing-drive root, swap, and ESP boot handling |
| `systems/nixos/hw-opts.nix` | Linux 7.3, zswap settings, guarded ESP mirroring |
| `systems/nixos/disko.nix` | Existing disk layout; replacement physical identity still needs updating later |
| `tests/mirrored-root.nix` | Disposable boot and smaller-replacement integration test |
| `bin/desktop-disk-preflight` | Read-only disk/SMART/scrub/array inventory |
| `bin/desktop-disk-prepare-size` | Guarded online shrink; **already completed** |
| `users/jarrett-home-manager/home.nix` | Firefox/1Password-only graphical autostart configuration |

Reproduce validation without modifying live disks:

```bash
nix build --impure --file tests/mirrored-root.nix \
  --out-link /tmp/opencode/mirrored-root-migration-test
nix build .#nixosConfigurations.nixos.config.system.build.toplevel \
  --out-link /tmp/opencode/nixos-missing-drive
```

The test file currently uses `builtins.getFlake "/etc/nixos"`; it is host-repository-specific. New scripts, tests, and this document are currently untracked and must be included if the work is committed or transferred to another checkout.
