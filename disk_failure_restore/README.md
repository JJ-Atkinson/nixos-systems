# Disk Failure Recovery — 2026-05-21

Documentation and tooling for restoring this NixOS system from restic after
the btrfs metadata corruption inherited from the defective WD_BLACK SN7100
(SN 25326Y800788, RMA in progress as of 2026-05-21).

This folder exists because the previous restore plan (boot the recovery ISO,
delete `@nix`, reinstall) failed: deleting `@nix` triggered the kernel's
deferred `btrfs_drop_snapshot` cleanup, which walked into unreadable
extent-tree blocks at logical bytenr 544531529728 (and others) and forced
the whole filesystem read-only. The damage is metadata-level, baked into
the bytes that were cloned from the defective WD onto the new Solidigm.
The Solidigm itself is healthy; the filesystem on it is not.

## Table of contents

- [What is on this disk vs. what is in restic](#what-is-on-this-disk-vs-what-is-in-restic)
- [Inventory of available restic snapshots](#inventory-of-available-restic-snapshots)
- [Known irrecoverable losses](#known-irrecoverable-losses)
- [Files included in this folder](#files-included-in-this-folder)
- [Prerequisites for restoring](#prerequisites-for-restoring)
- [Step 1 — boot a working environment](#step-1--boot-a-working-environment)
- [Step 2 — partition and create the target filesystem](#step-2--partition-and-create-the-target-filesystem)
- [Step 3 — set up the restic environment](#step-3--set-up-the-restic-environment)
- [Step 4 — restore the latest snapshot](#step-4--restore-the-latest-snapshot)
- [Step 5 — gap-fill from older snapshots](#step-5--gap-fill-from-older-snapshots)
- [Step 6 — move data into the subvolume layout](#step-6--move-data-into-the-subvolume-layout)
- [Step 7 — install NixOS](#step-7--install-nixos)
- [Verification checklist](#verification-checklist)
- [Troubleshooting](#troubleshooting)
- [Appendix: snapshot detail](#appendix-snapshot-detail)

## What is on this disk vs. what is in restic

**Restic backup server**: `192.168.50.45:8800` (local LAN, `rest-server`).
Credentials and repo URI are encrypted in
`secrets/host_nixos/restic.yaml` (see [Step 3](#step-3--set-up-the-restic-environment)).

**The post-corruption disk has been backed up to restic** with the new
`rescue-2026-05-21`-tagged snapshot before any destructive recovery action
was attempted. That snapshot is the primary source for the restore. It
contains roughly 4.9M files / 433 GiB across `/etc/nixos`, `/home/jarrett`,
and `/vm-storage/images` — minus the 26,169 files whose extents pointed
into corrupted metadata and could not be read (see `skipped-files.txt` for
the exhaustive list, and below for the irrecoverable subset).

## Inventory of available restic snapshots

As of 2026-05-21, the repository contains:

| ID | Date (local) | Tags | Paths | Size | Notes |
|---|---|---|---|---|---|
| `d654a4ea` | 2025-10-20 19:43 | — | `/etc/nixos` | 239 KiB | Initialization. Not useful for /home. |
| `557f18c5` | 2026-05-18 01:00 | — | `/etc/nixos` + `/home/jarrett` | 239.1 GiB | Pre-incident daily. Probably the cleanest /home snapshot. |
| `fcef6128` | 2026-05-18 17:27 | `pre-rma-vm-images-2026-05-18` | `/vm-storage/images` | 231.0 GiB | Manual pre-RMA VM-images snapshot. |
| `64786595` | 2026-05-19 01:00 | — | `/etc/nixos` + `/home/jarrett` | 231.7 GiB | Daily; may share gaps with later dailies. |
| `6ed1863f` | 2026-05-20 01:00 | — | `/etc/nixos` + `/home/jarrett` | 230.8 GiB | Daily. |
| `72f6264b` | 2026-05-21 01:00 | — | `/etc/nixos` + `/home/jarrett` | 231.2 GiB | Daily; ran before the rescue work began. |
| **`f23d3e9a`** | **2026-05-21 16:40** | **`rescue-2026-05-21`** | `/etc/nixos` + `/home/jarrett` + `/vm-storage/images` | **433.8 GiB** | **Primary restore source.** Made from `/mnt` (ro) during recovery. |

Snapshots are listed with `restic snapshots`. The two best fallback
candidates for gap-filling are `72f6264b` (most recent daily, less likely
to have on-disk state newer than f23d3e9a) and `557f18c5` (oldest
comprehensive daily, most likely to have clean copies of files that have
been silently corrupt since 2026-05-18).

## Known irrecoverable losses

These categories of files were unreadable on the disk and may also have
been unreadable in earlier daily backups. After the gap-fill step, audit
these specifically:

- **`/home/jarrett/.ssh/`** — `config`, `ejabberd{,.pub}`, `google_compute_engine{,.pub}`. The YubiKey-backed primary SSH identity (gpg-agent + `[A]` subkey) is NOT in `.ssh` and is unaffected. These are alternate keys; regenerate and re-upload to the respective services (GCE, ejabberd).
- **`/home/jarrett/.config/Signal/sql/db.sqlite`** plus seven attachments under `attachments.noindex/`. If older snapshots also failed to read this (likely — Signal's DB is touched constantly so corruption surfaces quickly), the chat history for the affected period is gone. Signal re-syncs message history from the device pairing, not from the desktop DB.
- **`/home/jarrett/.config/chromium/Default/History`**, **`Favicons`**, plus some IndexedDB blobs. Browser history loss only.
- **A few Obsidian plugin/theme files** under `Documents/*/.obsidian/plugins/*/main.js` and `themes/*.css`. Plugins re-download themselves from the Obsidian community catalog on next launch.
- **One git object** in `/etc/nixos/.git/objects/bc/e40ffbee4d3e3dc6c8527853ac0c44f6f4447e`. The remote at `git@github.com:JJ-Atkinson/nixos-systems.git` has a complete object graph, so cloning from the remote during install gives a clean repo regardless of the on-disk state.

Everything else in `skipped-files.txt` falls into one of these
categories, all auto-regenerable:

- Browser caches (Brave, Chrome, Chromium, Firefox, Code Cache, GPUCache, Service Worker, IndexedDB blobs)
- Build artifacts (`code/*/target/`, `code/*/node_modules/`, `code/*/.cljs-runtime/`)
- Git pack files (`.git/objects/pack/*.pack`) — re-fetched on `git fetch --all`
- Package caches (`.bun/install/cache/`, `.cargo`, `.rustup`, `.tldrc`, mesa shader cache, `nix/eval-cache`, `nix/tarball-cache`)
- VS Code extensions (under `.config/Code/CachedExtensionVSIXs/` and `.haystack-editor/extensions/`)
- Container layer files (`.local/share/containers/storage/overlay/`)
- Flatpak repo objects (`.local/share/flatpak/repo/objects/`)
- Trash files
- One swap file (`/home/jarrett/.swp`)

## Files included in this folder

- **`README.md`** — this document
- **`restore.sh`** — executable runbook that performs Steps 3-5 with sane defaults
- **`restic-backup.log`** — full 7 MB log from the 2026-05-21 16:40 backup; includes every error line
- **`skipped-files.txt`** — 26,169 unique paths, one per line, suitable for `restic restore --include-file`

## Prerequisites for restoring

1. **A working Linux environment.** The NixOS recovery ISO at
   `systems/recovery-live/` is purpose-built for this. Boot from USB.
2. **Network access** to `192.168.50.45:8800`. Confirm with
   `curl -sf -o /dev/null http://192.168.50.45:8800/ && echo OK`.
3. **The host's age key** for sops decryption, at
   `/var/lib/sops-nix/keys.txt` on the corrupted disk. If the corrupted
   disk is still readable, copy this out before mkfs. If not, the key
   will need to be reconstituted from offline backup. Without it, you
   cannot decrypt restic credentials from the flake.
4. **The `restic` and `sops` binaries.** On the recovery ISO:

   ```bash
   nix shell --extra-experimental-features 'nix-command flakes' \
     nixpkgs#restic nixpkgs#sops
   ```

   Or pin to specific store paths if doing this offline; see the
   restic and sops manuals for offline derivations.

## Step 1 — boot a working environment

Boot the recovery ISO. The Solidigm at `/dev/nvme0n1` is healthy and
needs no replacement; only its filesystem is being recreated.

Unlock the existing LUKS container (if you still want to read the old FS
for the age key):

```bash
sudo cryptsetup luksOpen /dev/nvme0n1p3 cryptroot-old
sudo mkdir -p /mnt-old
sudo mount -o ro,subvol=@ /dev/mapper/cryptroot-old /mnt-old
sudo cp /mnt-old/var/lib/sops-nix/keys.txt /tmp/age-key.txt
sudo chown $(id -u) /tmp/age-key.txt
chmod 600 /tmp/age-key.txt
sudo umount /mnt-old
sudo cryptsetup luksClose cryptroot-old
```

## Step 2 — partition and create the target filesystem

The existing partition layout is fine to reuse:

- `nvme0n1p1` — 1 GiB vfat ESP (do **not** wipe — boot loader lives here, can be reinitialized but no need)
- `nvme0n1p2` — 1 GiB ext4, currently empty (legacy /boot, unused by the `nixos` config)
- `nvme0n1p3` — 1.8 TiB LUKS container

To preserve LUKS headers (avoids needing to re-enroll keys/yubikeys):

```bash
sudo cryptsetup luksOpen /dev/nvme0n1p3 cryptbtrfs
# This wipes ONLY the btrfs filesystem inside the LUKS container.
# The LUKS header itself is untouched.
sudo mkfs.btrfs -L root -f /dev/mapper/cryptbtrfs

sudo mount /dev/mapper/cryptbtrfs /mnt
for sv in @ @home @nix @log @swap; do
  sudo btrfs subvolume create /mnt/$sv
done
sudo umount /mnt
```

Subvolume layout matches `systems/nixos/fs-opts.nix`. The two VM-storage
subvolumes (`@vm-images`, `@vm-shared`) live on `nvme1n1` and are not
recreated here unless that drive is also being reset.

To remake from scratch with a new LUKS header (changes the
`boot.initrd.luks.devices."cryptbtrfs".device` UUID in `fs-opts.nix` —
update the flake before installing):

```bash
sudo cryptsetup luksFormat /dev/nvme0n1p3       # new UUID
sudo cryptsetup luksOpen /dev/nvme0n1p3 cryptbtrfs
sudo mkfs.btrfs -L root -f /dev/mapper/cryptbtrfs
# ...same subvolume creation as above
```

## Step 3 — set up the restic environment

Decrypt the sops-encrypted restic credentials:

```bash
export SOPS_AGE_KEY_FILE=/tmp/age-key.txt

# Assuming /etc/nixos is cloned from GitHub already; if not:
#   git clone git@github.com:JJ-Atkinson/nixos-systems.git /tmp/flake
#   cd /tmp/flake

sops --decrypt secrets/host_nixos/restic.yaml > /tmp/restic-creds.yaml
chmod 600 /tmp/restic-creds.yaml

export RESTIC_REPOSITORY=$(awk '/^remote_repo_uri:/ {print $2}' /tmp/restic-creds.yaml)
export RESTIC_PASSWORD=$(awk '/^remote_repo_secret:/ {print $2}' /tmp/restic-creds.yaml)
export RESTIC_CACHE_DIR=/tmp/restic-cache
mkdir -p "$RESTIC_CACHE_DIR"
```

Sanity-check the repo is reachable:

```bash
restic snapshots --latest 1
# should print f23d3e9a (or whatever the most recent snapshot is)
```

If `restic snapshots` hangs or reports `circuit breaker open for file
<snapshot/...>`, it means a transient REST API failure tripped restic's
in-process retry breaker. Re-run with a **fresh cache** (different
`RESTIC_CACHE_DIR` or `rm -rf` and recreate) — a new restic process
resets the breaker state.

## Step 4 — restore the latest snapshot

Mount the new btrfs and decide on a staging area. Two options:

**Option A: Restore directly into the target subvolumes** — fastest, less
disk-shuffling, but mixes the staging step with the final layout. If gap-fill
finds nothing or you discover a problem, you may need to restart.

```bash
sudo mount -o subvol=@,ssd,noatime /dev/mapper/cryptbtrfs /mnt
sudo mkdir -p /mnt/{nix,home,var/log,swap,boot}
sudo mount -o subvol=@nix,compress=zstd,ssd,noatime /dev/mapper/cryptbtrfs /mnt/nix
sudo mount -o subvol=@home,ssd,noatime              /dev/mapper/cryptbtrfs /mnt/home
sudo mount -o subvol=@log,compress=zstd,ssd,noatime /dev/mapper/cryptbtrfs /mnt/var/log
sudo mount -o subvol=@swap,compress=no,ssd,noatime  /dev/mapper/cryptbtrfs /mnt/swap

# Restic will recreate /mnt/etc/nixos and /mnt/home/jarrett etc.
sudo --preserve-env=RESTIC_REPOSITORY,RESTIC_PASSWORD,RESTIC_CACHE_DIR \
  restic restore f23d3e9a --target /mnt --overwrite always
```

**Option B: Restore into a staging area, audit, then copy** — slower but
keeps the new filesystem untouched while you sanity-check the restore.

```bash
sudo mkdir -p /recovery
sudo --preserve-env=RESTIC_REPOSITORY,RESTIC_PASSWORD,RESTIC_CACHE_DIR \
  restic restore f23d3e9a --target /recovery --overwrite always
# … verify, then in Step 6 mv/rsync /recovery/* into the mounted subvolumes
```

The 433 GiB restore takes a few hours on a 1 Gbps LAN — the bottleneck is
network I/O to the rest-server. The restore is resumable: if interrupted,
re-run the same command. Restic verifies and skips already-restored files.

## Step 5 — gap-fill from older snapshots

Two approaches.

### 5a (simple, recommended) — layered restore with `--overwrite never`

Replay older snapshots into the same target; each pass only writes files
that don't already exist. Order: newest to oldest.

```bash
TARGET=/mnt  # or /recovery if you chose Option B
for SNAP in 72f6264b 6ed1863f 64786595 557f18c5; do
  echo "==> gap-fill from $SNAP"
  sudo --preserve-env=RESTIC_REPOSITORY,RESTIC_PASSWORD,RESTIC_CACHE_DIR \
    restic restore "$SNAP" --target "$TARGET" --overwrite never
done

# /vm-storage/images is in f23d3e9a already; if it had errors, fall back:
# sudo restic restore fcef6128 --target $TARGET --overwrite never
```

Side effect: any file you deliberately deleted between 2026-05-18 and
2026-05-21 will be resurrected at the target, with the mtime from
whichever snapshot supplied it. Audit after the fact if this matters:

```bash
find /mnt/home/jarrett -newer /tmp/restic-backup.log -not -newer /tmp/restic-creds.yaml \
  ! -path '*/.cache/*' ! -path '*/Cache/*' -mmin +60 2>/dev/null | head -50
```

For this corruption-recovery situation the resurrection cost is small
because most skipped files were caches that have been gone since 2026-05-18
anyway.

### 5b (precise) — gap-fill only the known-skipped files

Uses `skipped-files.txt` as `--include-file`. Only paths in that file are
restored from older snapshots, and only if missing at target.

```bash
TARGET=/mnt
GAP_LIST=/etc/nixos/disk_failure_restore/skipped-files.txt   # or wherever
                                                              # this folder is mounted

for SNAP in 72f6264b 6ed1863f 64786595 557f18c5; do
  echo "==> precise gap-fill from $SNAP"
  sudo --preserve-env=RESTIC_REPOSITORY,RESTIC_PASSWORD,RESTIC_CACHE_DIR \
    restic restore "$SNAP" --target "$TARGET" \
      --include-file "$GAP_LIST" \
      --overwrite never
done

# Audit remaining gaps
while read -r p; do
  [ -e "$TARGET$p" ] || echo "still missing: $p"
done < "$GAP_LIST" | tee /tmp/still-missing.txt
wc -l /tmp/still-missing.txt
```

Performance note: 26k include patterns against a 4.9M-file snapshot is
slower than the simple approach. If unacceptable, split `skipped-files.txt`
into per-top-level-directory chunks and run separate passes; or fall back
to 5a.

## Step 6 — move data into the subvolume layout

If you used Option A in Step 4, files are already in the right
subvolumes — skip to Step 7.

If you used Option B and restored into `/recovery`:

```bash
sudo rsync -aHAXS --info=progress2 /recovery/etc/nixos/      /mnt/etc/nixos/
sudo rsync -aHAXS --info=progress2 /recovery/home/jarrett/   /mnt/home/jarrett/
sudo rsync -aHAXS --info=progress2 /recovery/vm-storage/images/ \
                                   /vm-storage/images/   # nvme1n1 subvol, if applicable
```

`-aHAXS` preserves hardlinks, ACLs, xattrs, and sparse files. The
Windows VM qcow2 is sparse — `-S` is required to keep it sparse on the
new filesystem.

## Step 7 — install NixOS

Clone the flake (the on-disk `/etc/nixos` from restic is restored, but a
fresh clone guarantees no inherited damage to the git object store):

```bash
# back up the restored /etc/nixos in case you want to inspect uncommitted state
sudo mv /mnt/etc/nixos /mnt/etc/nixos.from-restic
sudo git clone git@github.com:JJ-Atkinson/nixos-systems.git /mnt/etc/nixos

# diff if you want to recover uncommitted edits
sudo diff -r /mnt/etc/nixos.from-restic /mnt/etc/nixos | head -200
```

Install:

```bash
sudo nixos-install --root /mnt --flake /mnt/etc/nixos#nixos --no-root-passwd
```

If `nixos-install` complains about "dubious ownership" of the git
repository (the flake.nix), set:

```bash
sudo git config --global --add safe.directory '*'
```

before re-running. This is required when root operates on a non-root-owned
checkout.

The install populates a fresh `/mnt/nix/store` from `cache.nixos.org`
according to the flake.lock pins. Expect 30-90 minutes depending on
cache hit rate.

## Verification checklist

After the install completes, before rebooting:

- [ ] `ls /mnt/etc/nixos/flake.nix` exists and is intact (`git status` clean
      if you cloned fresh).
- [ ] `/mnt/home/jarrett/.config/sops/age/keys.txt` or equivalent age key
      restored, if you use one for user-level sops.
- [ ] `/mnt/var/lib/sops-nix/keys.txt` present (host age key — needed for
      decrypting host-level sops secrets on first boot).
- [ ] `/mnt/home/jarrett/code/humble/hai{,-blue,-grey,-purple}` have intact
      `.git` directories. Check `git status` in each.
- [ ] `/mnt/home/jarrett/.gnupg/private-keys-v1.d/` is empty (yubikey-only
      identity — no on-disk private subkeys). Verify with `gpg --card-status`
      after first boot.
- [ ] VM images present and openable: `qemu-img info /vm-storage/images/windows11.flattened-*.qcow2`
- [ ] `/mnt/boot` ESP contents present (systemd-boot files). If empty,
      `bootctl install --esp-path=/mnt/boot` from inside a chroot.
- [ ] `skipped-files.txt` cross-checked against `/mnt` — anything still
      missing logged in `/tmp/still-missing.txt`. Decide per-file whether
      it matters.

After first boot:

- [ ] `gpg --card-status` recognizes the yubikey.
- [ ] `restic snapshots` works (sops-decrypted creds at boot time).
- [ ] `systemctl status restic-remote-backup.timer` is `active (waiting)`.
- [ ] `systemctl status btrfs-scrub@-.timer` and similar — the
      `modules/btrfs-scrub.nix` jobs are scheduled.

## Troubleshooting

**"circuit breaker open" during `restic snapshots`**
A previous restic invocation hit transient REST errors. Use a fresh
`RESTIC_CACHE_DIR` and a fresh restic process. Does not indicate repo
corruption.

**Restic restore drops connection partway through**
Re-run the same command. Restic resumes from where it left off; already-
restored files are detected and skipped (or overwritten if they were
in-progress).

**`mkfs.btrfs` refuses to wipe the existing FS**
Add `-f`. Confirm you actually intend to destroy the existing filesystem
first. The LUKS container's contents WILL be unrecoverable after this.

**`nixos-install` fails with "Git tree is dirty"**
The flake's working tree has uncommitted changes. Either `git stash`, or
add `--impure` to nixos-install if you need the dirty state.

**`bootctl install` fails with "Failed to access EFI variables"**
Expected: `boot.loader.efi.canTouchEfiVariables = false` in `hw-opts.nix`.
The bootloader files are still written to the ESP; the NVRAM entry
created by the previous install is preserved.

**Sops decryption fails ("no key could be found")**
The host age key in `/var/lib/sops-nix/keys.txt` is either missing or
doesn't match the secrets' encryption keys. Verify it matches the
`age:` key in `.sops.yaml` (`age1e0td9nmh795pl2ptlpyhqsas9de406pgs4hglrje5kc070dt9c3q70u2wu`
for `host_nixos`). If lost, the secrets must be re-encrypted by someone
with the PGP master key (jarrett's offline yubikey).

## Appendix: snapshot detail

To inspect what's in any snapshot before restoring:

```bash
# Count files in a snapshot
restic stats <SNAPSHOT_ID>

# List contents of a path within a snapshot
restic ls <SNAPSHOT_ID> /home/jarrett

# Search across snapshots for a specific path
restic find --snapshot <SNAPSHOT_ID> /path/to/file

# Diff two snapshots
restic diff <OLD_SNAPSHOT> <NEW_SNAPSHOT> | head -50
```

To run an integrity check on the repository itself (slow — verifies
all data and metadata):

```bash
restic check --read-data-subset=5%   # the daily backup job already does this
```

To prune old snapshots (DON'T do this until restoration is complete and
verified):

```bash
restic forget --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune
```
