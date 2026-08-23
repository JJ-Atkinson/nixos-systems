# Disk write volume — investigation & follow-up

Date opened: 2026-08-11  
Host: `nixos` (btrfs RAID1 on dual NVMe, LUKS)

## What we saw

### Device-level volume (since boot)

From `/proc/diskstats` after ~19h uptime:

| Device   | Written since boot | Approx rate |
|----------|--------------------|-------------|
| nvme0n1  | ~1500 GB           | ~79 GB/h    |
| nvme1n1  | ~1500 GB           | ~79 GB/h    |

The two drives match because root is **btrfs RAID1** (`cryptbtrfs_a` + `cryptbtrfs_b`): every logical write is mirrored, so host write amplification is ~2× logical data.

Mount options (relevant): `compress=zstd:3`, `ssd`, `discard=async`, `noatime`, `degraded`.

btrfs device stats at check time: no write/read/flush IO errors; `cryptbtrfs_a` had a small `corruption_errs` count (4) — separate from write volume, but worth watching.

### Important limitation of the first look

Attribution used **live** counters only:

- `/proc/diskstats` — cumulative sectors since boot (good for *how much*)
- `/proc/<pid>/io` `write_bytes` — cumulative per *still-running* process (no history for exited PIDs)

There was **no** retained “who wrote the 1.5 TB” log. Quiet at sample time (dirty pages low, ~0 MB/s delta) does not mean the boot was quiet overall.

### Strong leads (application side)

Under the scoria dev tree:

| Path | Notes |
|------|--------|
| `~/code/ogc/scoria/.scoria-dev/obs/obs.db` | ~46 GB SQLite; mtime advancing during investigation |
| `…/obs/obs.db-wal` | WAL active |
| `…/system/scoria.db` | ~400 MB, also active |
| `…/workspaces/**/index/lmdb`, `proximum/mmap` | Large index/mmap artifacts |
| `…/.scoria-dev` total | ~58 GB |

Related long-lived processes observed:

- OpenJDK / `shadow.cljs.devtools.cli --npm watch app portfolio` (cwd: scoria)
- `clamd` with config under `.scoria-dev/.clamav/`
- Various browsers/editors (secondary vs DB/index path)

**Hypothesis to confirm with logging:** scoria observability SQLite (`obs.db`) and/or LMDB/index writers, possibly plus clamd scanning, drive sustained write traffic; RAID1 doubles device bytes.

## Monitoring added (this repo)

Module: [`modules/disk-diagnostics.nix`](modules/disk-diagnostics.nix)  
Imported from both `nixos` and `nixos-framework` flakes.

Enabled by default via `services.diskWriteWatch.enable` (mkDefault true).

### 1. Text delta log — `disk-write-watch`

- **Timer:** every `intervalSeconds` (default 60s)
- **Log:** `/var/log/disk-write-watch/writes-YYYY-MM-DD.log`
- **State:** `/var/lib/disk-write-watch/`
- **Retention:** 7 days (configurable)
- Each sample records:
  - Per-device read/write MB **this interval** (from `diskstats`)
  - Top processes by `write_bytes` delta (default top 20, min 1 MB)
  - Size/mtime of watched files (obs.db, WAL, scoria.db)

```bash
sudo systemctl status disk-write-watch.timer
sudo tail -f /var/log/disk-write-watch/writes-$(date +%F).log
```

### 2. Binary history — `atop`

- **Service:** `atop.service` (manual unit; nixpkgs here has no `services.atop`)
- **Logs:** `/var/log/atop/atop_YYYYMMDD`
- **Rotate:** `atop-rotate.timer` (daily restart → new day file)
- **Cleanup:** `atop-cleanup.timer` (delete older than retentionDays)

```bash
sudo systemctl status atop
sudo atop -r /var/log/atop/atop_$(date +%Y%m%d)   # press 'd' to sort by disk
```

### 3. Packages on PATH

`iotop`, `sysstat` (`iostat`/`pidstat`/`sar`), `atop`, plus existing `smartmontools` / `nvme-cli` / `smartd`.

### Activate

```bash
sudo nixos-rebuild switch
sudo systemctl status disk-write-watch.timer atop
```

### After 1–2 days — triage commands

```bash
# Highest process deltas from text logs
sudo grep -E 'MB  pid=' /var/log/disk-write-watch/writes-*.log \
  | sort -k1 -nr | head -50

# Device spikes
sudo grep -E 'nvme|dm-' /var/log/disk-write-watch/writes-*.log | less

# obs.db growth annotations
sudo grep watchfile /var/log/disk-write-watch/writes-*.log | less

# Interactive process/disk history
sudo atop -r /var/log/atop/atop_YYYYMMDD
```

## Config knobs

In NixOS config (or override in the module):

```nix
services.diskWriteWatch = {
  enable = true;
  intervalSeconds = 60;       # use 10 for finer grain (more log volume)
  topN = 20;
  minDeltaMB = 1;
  retentionDays = 7;
  watchFiles = [
    "/home/jarrett/code/ogc/scoria/.scoria-dev/obs/obs.db"
    "/home/jarrett/code/ogc/scoria/.scoria-dev/obs/obs.db-wal"
    "/home/jarrett/code/ogc/scoria/.scoria-dev/system/scoria.db"
  ];
};
```

## Likely next steps once logs identify the writer

1. **If `obs.db` / scoria Java:** check observability retention, SQLite journal mode, vacuum/checkpoint policy, whether metrics are unbounded append.
2. **If LMDB/index paths:** compaction, rebuild frequency, mmap write patterns under btrfs.
3. **If clamd:** exclude heavy DB/index dirs from live scan if safe; scan on schedule instead.
4. **btrfs:** note RAID1 write amp; optional `compsize` on hot files; avoid assuming host TB written == logical user data TB.
5. **SMART:** continue via existing `smartd` / `smartErrorWatch`; high host writes accelerate SSD wear — check `nvme smart-log` media/percentage used after confirmation.

## Non-goals / out of scope for the logger

- Does not capture page-cache-only dirty traffic that never hits `write_bytes` the same way (rare for DBs).
- `write_bytes` is kernel accounting of bytes to storage; compressed btrfs may write fewer device bytes than process `write_bytes` (or more with COW/RAID).
- Exited processes only appear in intervals while they lived; short spikes need ≤60s interval or catch in atop raw file.
