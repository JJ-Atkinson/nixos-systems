# Plan B — Follow-up observability for the new RAID1 layout

## Context

This is the follow-up plan to `plan-a-disko-raid1-install.md`. Plan A installs a RAID1 btrfs across WD + Solidigm with mdadm-mirrored ESP and swap. Plan A is **self-contained for bootability and disk-loss survival** — what it does *not* do is observably surface degradation while the system is running. Given this desktop's 90+ day uptime profile and the prior WD SN7100 incident pattern (silent media-error growth → eventual btrfs forced-RO → crash), runtime observability is essential.

Plan B is additive, no-data-risk, and can be done in pieces after the migration is verified.

**Working tree location:** `~/nixos/`.

Per recorded preferences: **no filesystem snapshots** (restic offsite is sufficient).

## B.1 Goal

After Plan B: any disk degradation, missing-device event, mdadm degradation, or btrfs forced-RO transition surfaces a critical desktop notification to the logged-in user(s) within minutes — not weeks. Tuned for this machine's 90+ day uptime profile, where boot-time notifications alone are insufficient. Plus cleanup of the existing scrub/SMART modules for the new layout.

Existing infrastructure (do not duplicate):

- `modules/smart-error-watch.nix` — hourly poll of SMART "Media and Data Integrity Errors" per drive, notifies on growth. Already adequate for slow-degradation detection. The `notifyScript` shell pattern in this file is the canonical desktop-notification implementation in this repo.
- `modules/btrfs-scrub.nix` — weekly scrub + post-scrub error-stats delta check via its `checkScript`, notifies on growth.

Gaps Plan B closes:

| Failure signal | Current coverage | Plan B addition |
|---|---|---|
| btrfs forced read-only event | none | `btrfs-ro-watch` — journald follower |
| mdadm array degradation | none | `mdadm-degraded-watch` — wraps `mdadm --monitor` |
| Missing/dropped device at boot | none | `boot-disk-presence-check` — oneshot + hourly timer |
| btrfs `device stats` growth between weekly scrubs | only after weekly scrub | Opportunistic timer (~hourly) reusing the existing state file |
| Disk silently dropped during long uptime | partial — `smart-error-watch` would skip missing device silently | Same `boot-disk-presence-check` covers it via hourly timer |

## B.2 New module: `modules/disk-fleet-watch.nix`

A single module exporting four small services, each reusing a shared `notifyScript` factored out of `modules/btrfs-scrub.nix` and `modules/smart-error-watch.nix` (or duplicated — pick at implementation time; both existing copies are nearly identical).

### B.2.a `btrfs-ro-watch.service`

`Type=simple` (long-running). Follows the kernel journal with `journalctl -k -f -o cat -g 'BTRFS.*(forced read.?only|aborting transaction|error_stats)'`. On any match, calls `notifyScript` with critical urgency and the matched line; also `logger -t btrfs-ro-watch`. Restart=always.

Catches the exact event class that's been crashing the desktop on the failing SN7100. Even if RAID1 reduces the likelihood, when it does happen the user knows immediately and can `mount -o remount,rw,degraded` and start recovery.

### B.2.b `mdadm-degraded-watch.service`

`Type=simple`. Wraps `mdadm --monitor --scan --program=<notify-wrapper>`. mdadm calls the wrapper on every event (`DegradedArray`, `FailSpare`, `Fail`, etc.) with the array and device as positional args; the wrapper translates that to a `notifyScript` call. Restart=always.

### B.2.c `boot-disk-presence-check.service` + `.timer`

Oneshot. Runs after `multi-user.target` on every boot, and again hourly via timer. Checks:

- `btrfs filesystem show /` lists the expected two devices, both with non-zero size.
- `cat /proc/mdstat` shows both `md/boot` and `md/swap` with `[UU]` (or warns on `[U_]` / `[_U]`).
- Each expected serial number (recorded once at first run into `/var/lib/disk-fleet-watch/expected-sns`) is present in `lsblk -o SERIAL`.

On any divergence: `notifyScript` critical + `logger`. Hourly cadence handles the "uptime 30 days, disk silently dropped two days ago" case — without this, `smart-error-watch` would skip the missing drive without raising any alarm.

### B.2.d `btrfs-stats-watch.service` + `.timer`

Hourly. Wraps the same `btrfs device stats` delta logic that `modules/btrfs-scrub.nix`'s `checkScript` already implements (lines 51–87). Read the same state file (`/var/lib/btrfs-scrub-notifier/root.stats`) to avoid maintaining a second baseline. On growth between scrubs, `notifyScript` critical.

Implementation note: factor the delta-check awk snippet out of `btrfs-scrub.nix:checkScript` into a shared shell function/script so both modules call the same logic.

## B.3 Adjustments to existing modules

### `modules/btrfs-scrub.nix`

Current state (post-Plan-A): the module's `services.btrfs.autoScrub.fileSystems` lists `/` and `/vm-storage/images` as two separate mountpoints. In the new layout these are subvolumes of the same btrfs filesystem; scrubbing one scrubs all data on the underlying devices. Listing both causes redundant scrub runs.

Changes:

- Drop `/vm-storage/images` from `fileSystems`. Scrubbing `/` covers everything.
- Drop the stagger override for `btrfs-scrub-vm\\x2dstorage-images` (no longer a separate timer).
- Drop the daily-scrub override on `/` (line ~120 of the existing module). That override exists specifically because of the failing SN7100; once RAID1 is in place and the failing drive is RMA'd, weekly is appropriate.
- Verify the per-scrub `checkScript` ExecStopPost still hooks correctly to the single remaining scrub unit.

### `modules/smart-error-watch.nix`

Current state: device list defaults to `[ "/dev/nvme0n1" "/dev/nvme1n1" ]`. The script reads each drive's serial at runtime, so device-name churn (e.g., Solidigm becoming nvme0n1) is already handled — no functional change required.

Optional polish:

- Switch the default `devices` list to `/dev/disk/by-id/nvme-<MODEL>_<SERIAL>*` paths so the config is self-documenting about *which* drives are expected. Provides a hint that gets caught at config-eval time if a drive is renamed.
- Add the third "expected" check: alert if a drive in the list is no longer present at all (currently the script `continue`s silently on missing devices). This overlaps with `boot-disk-presence-check.service` in B.2.c — either consolidate there or duplicate; pick at implementation.

## B.4 Verification (Plan B)

For each new service, simulate the signal and confirm the notification fires:

- **btrfs-ro-watch:** `mount -o remount,ro /tmp-test-mount` on a scratch btrfs (or trigger via `btrfs check --readonly --force` style write-after-failed-injection). Confirm critical notify-send arrives on the desktop session.
- **mdadm-degraded-watch:** `mdadm --fail /dev/md/swap <member>` then `mdadm --remove`; confirm critical notify-send. Re-add with `mdadm --add` to restore.
- **boot-disk-presence-check:** with one disk deleted via `echo 1 > /sys/block/.../device/delete`, run the service manually and confirm notify-send fires. Confirm the hourly timer is `active (waiting)`.
- **btrfs-stats-watch:** dd a small write to a known bad-block area (or wait for natural growth; alternatively, `btrfs scrub start` then immediately stop to bump a counter). Confirm notify-send.

For the module cleanups:

- `systemctl list-timers | grep btrfs-scrub` after Plan B should show one timer, weekly, no per-mountpoint override.
- `systemctl status smart-error-watch.timer` continues to show hourly.

## B.5 Out of scope for Plan B

- Email/SMS alerting on top of desktop notify-send. Notify-send to logged-in users is sufficient given the user-presence pattern (this is a personal desktop).
- Centralizing the three nearly-identical `notifyScript` shell blocks into a single nix-store helper. Worth doing as a small refactor before B.2 lands; tracked as a sub-step but not load-bearing for the resilience properties.
- Snapshot-based recovery — explicitly excluded per recorded preference.
