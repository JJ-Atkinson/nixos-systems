# Recovery live ISO — operating notes

This ISO was built for one specific machine and one specific job: cloning a
defective WD_BLACK SN7100 onto a healthy Solidigm so the WD can go back for
RMA. It is also a generally useful rescue environment afterwards.

The values below are pinned to drive **serial numbers** captured 2026-05-20.
Always re-verify by serial before doing anything destructive — Linux device
names (`/dev/nvme0n1` vs `nvme1n1`) re-enumerate between boots and are not safe
to trust.

## Drives in this machine

```
Source — defective, clone FROM this drive:
  Model:   WD_BLACK SN7100 2TB
  Serial:  25326Y800788
  Path:    /dev/disk/by-id/nvme-WD_BLACK_SN7100_2TB_25326Y800788
  Layout:  p1 = ESP   (vfat, ~1 GiB)
           p2 = boot  (~1 GiB)
           p3 = LUKS container (~1.8 TiB) → cryptbtrfs (btrfs root)
  Status:  ~6,235 lifetime SMART Media Errors as of 2026-05-20 (growing ~2.5/h)

Target — recipient, clone TO this drive:
  Model:   SOLIDIGM SSDPFKNU020TZ
  Serial:  PHEH308200MD2P0C
  Path:    /dev/disk/by-id/nvme-SOLIDIGM_SSDPFKNU020TZ_PHEH308200MD2P0C
  State:   2.04 TiB raw. Stale GPT + partitions present (old install).
           They WILL be overwritten by the full-disk clone.

DO NOT TOUCH — vm-storage drive (production data):
  Model:   WD_BLACK SN7100 2TB
  Serial:  25306L805271
  Path:    /dev/disk/by-id/nvme-WD_BLACK_SN7100_2TB_25306L805271
```

## Step-by-step

### 1. Boot from this USB on Ventoy

Pick `nixos-recovery.iso` from the Ventoy menu. Auto-login to user `rescue`,
GNOME starts, ghostty in the dash. Open ghostty.

### 2. Identify the drives in this boot

```sh
nvme list
lsblk -d -o NAME,MODEL,SERIAL,SIZE
ls -l /dev/disk/by-id/ | grep nvme
```

You should see exactly three NVMe drives with the three serials above. If any
are missing or unfamiliar, stop and investigate before continuing.

### 3. Quick SMART check

```sh
sudo smartctl -a /dev/disk/by-id/nvme-WD_BLACK_SN7100_2TB_25326Y800788 \
  | grep -E 'Serial|Media and Data|Power On|Critical'
sudo smartctl -a /dev/disk/by-id/nvme-SOLIDIGM_SSDPFKNU020TZ_PHEH308200MD2P0C \
  | grep -E 'Serial|Media and Data|Power On|Critical'
```

Confirm: source has the expected (large, growing) Media Errors count; target
has 0.

### 4. Run the clone

`ddrescue` handles bad LBAs by skipping + retrying with a map file. `dd`
would abort on the first bad block — do not use it for this.

```sh
sudo ddrescue --force -d -r3 \
  /dev/disk/by-id/nvme-WD_BLACK_SN7100_2TB_25326Y800788 \
  /dev/disk/by-id/nvme-SOLIDIGM_SSDPFKNU020TZ_PHEH308200MD2P0C \
  /home/rescue/clone-25326Y800788.map
```

- `--force` accepts that the target has existing data.
- `-d` uses direct I/O, bypassing the host page cache.
- `-r3` does three retry passes over bad regions.
- The map file lets the run resume if interrupted (just re-run the same
  command and it picks up).

Expected runtime: 30 minutes to 2 hours, depending on how many bad LBAs the
source has accumulated.

### 5. Check the map

```sh
ddrescue --status /home/rescue/clone-25326Y800788.map
```

Non-trivial "non-tried" / "non-trimmed" / "errsize" totals are worth a second
pass. All historically known uncorrectable LBAs on the source were inside the
deleted `Win11_25H2_English_x64.iso` extent — those regions are unused space
in the cloned btrfs, so unrecoverable bytes there are fine.

### 6. Power off and physically remove the defective WD

After the clone finishes:

1. `sudo poweroff`
2. Open the case, pull the WD with serial `25326Y800788`.
3. Set it aside intact for the SanDisk RMA (do not wipe it).

The cloned filesystem on the Solidigm uses the same partition GUIDs, the same
LUKS UUID, and the same btrfs UUID as the original. If both drives stay in the
chassis at once, the kernel may mount the wrong one. Pulling the defective
drive eliminates the ambiguity.

### 7. Boot from the Solidigm

Pick the Solidigm in the UEFI one-time boot menu if needed. The cloned ESP
should boot directly. If UEFI cannot find the boot entry, drop back into this
recovery USB, `nixos-enter` into the Solidigm's root, and run `bootctl install`
to re-register.

Once you are booted into your normal system:

```sh
findmnt /                                # root should be on a Solidigm partition
lsblk -d -o NAME,MODEL,SERIAL,SIZE       # confirm root is on PHEH308200MD2P0C
sudo btrfs scrub start -B /              # full integrity sweep
sudo btrfs scrub status /
sudo smartctl -a /dev/nvme*n1 | grep 'Media and Data Integrity'
```

Expect: zero scrub errors, Solidigm Media Errors still 0.

### 8. Optional — grow into the extra ~40 GiB on the Solidigm

The Solidigm is 2.04 TiB; the source WD was 2.00 TiB. After the clone there is
unused space at the tail of the disk.

```sh
sudo parted /dev/disk/by-id/nvme-SOLIDIGM_SSDPFKNU020TZ_PHEH308200MD2P0C resizepart 3 100%
sudo cryptsetup resize cryptbtrfs
sudo btrfs filesystem resize max /
```

### 9. Tell smart-error-watch the defective drive is gone

```sh
sudo rm /var/lib/smart-error-watch/25326Y800788
sudo systemctl start smart-error-watch.service
```

That re-seeds the baseline for the drives that remain.

## If something goes sideways

- **ddrescue stalls or times out repeatedly on bad regions**: rerun it with a
  shorter retry budget (`-r1`) and a smaller minimum block size (`-c 1`) to
  squeeze more good data out, then accept the unrecoverable tail.
- **Cloned system won't boot, UEFI menu empty**: from this recovery ISO,
  decrypt the cloned LUKS, mount the cloned btrfs `@` subvol at `/mnt`, mount
  the cloned ESP at `/mnt/boot`, then `nixos-enter --root /mnt` and run
  `nixos-rebuild boot --flake /etc/nixos#nixos` to refresh boot entries.
- **You want to compare files between source and target after a partial
  clone**: don't. The clone is a block-level copy — even a partial copy
  produces a filesystem the kernel may try to auto-mount with a conflicting
  UUID. Treat the target as untouchable until the clone is complete and the
  source is unplugged.

## Toolkit inventory on this ISO

`ddrescue` (`gddrescue` package), `smartctl`, `nvme`, `hdparm`, `parted`,
`sgdisk`/`gdisk`, `cryptsetup`, `btrfs`, `mkfs.{ext4,xfs,vfat}`, `rsync`,
`git`, `neovim`, `curl`, `wget`, `htop`, `iotop`, `lspci`, `lsusb`, `lsblk`,
`file`, `lsof`, `tmux`, `ghostty`.
