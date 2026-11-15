# NixOS boot recovery — historical record (2026-11-13)

## Resolved: successful normal generation 161 boot

This recovery is complete. This document is retained as a historical record, not an active recovery handoff or a list of pending instructions. Commands and paths below describe the recovery at the time; `/etc/nixos/RECOVERY-HANDOFF.md` has been retired to this file.

- User reported successfully booting the normal default generation 161.
- Live checks confirmed **systemd-boot 260.5**, current/default entry `nixos-generation-161.conf`, and Linux **7.3.3**. Firmware booted the fallback ESP (PARTUUID `8bb8384e-98f1-4bbe-b2ec-51c3fafe8a7d`) through `EFI/BOOT/BOOTX64.EFI`. The ESP mismatch warning reflects inspection of primary `/boot`, not a boot failure.
- `/run/booted-system`, `/run/current-system`, and the system profile all resolve to `/nix/store/46f6f5frr3w0197zdcvcqv2cxdd8jcaq-nixos-system-nixos-26.05.20261108.ac588ef`, the exact G158/G161 closure.
- The normal kernel command line contains no debug-shell or probe unit-mask options.
- The current boot journal records successful FIDO2 presence requests and completed cryptsetup units for **cryptbtrfs_a, cryptbtrfs_b, and cryptswap** at 01:17. The missing `libpcsclite_real.so.1` warning still appeared but did not prevent unlocking.
- `systemctl --failed` reports **zero failed units**. The automatic-upgrade timer is active again; its service was inactive at inspection.
- User ran the evidence helper successfully. Evidence was saved at `/root/nixos-recovery/pre-2605-rebuild-20261113T011107-7Ne5up/after-20261113T011819-gR75yX`. The helper's “Before reboot” footer is generic text, not evidence that reboot is still pending. Live checks above were made after the reboot; the private saved directory was not independently opened by the assistant.

The ordinary 26.05 upgrade and boot now work with the newer loader. **The original failure's cause remains unknown; a systemd-boot regression was not established.** No further rebuild, reinstall, rollback, formatting, or YubiKey reenrollment is indicated by this recovery.

Backups and the standalone EFI restore helper remain in `/root/nixos-recovery/`. Temporary DIAG boot entries have **not** been removed or rechecked in this final session; earlier records describe unauthenticated debug-shell access if those entries are selected. Removing them from both ESPs is separate optional cleanup, not completed work.

---

## Historical handoff (superseded by the successful boot above)

## Latest approved next action
The 26.05 diagnostic boot succeeded. Verified backup completed at `/root/nixos-recovery/pre-2605-rebuild-20261113T011107-7Ne5up`. Saved 26.05 configuration was restored onto master. **`nixos-rebuild boot` succeeded, creating G161 with EXACTLY the same system closure as G158 and updating the EFI loader to 260.5. Final checks passed at 01:15: both ESP loader paths match 260.5, both file defaults select G161, and EFI default/one-shot were set to G161. Index permissions repaired. Ready for normal reboot; G161 unlock under the newer loader is NOT yet boot-tested.** See **Preparation for ordinary 26.05 rebuild and reboot** at the end for evidence and live-USB restore instructions. Earlier "what to do next" sections are historical.

## Situation
Installed desktop failed to unlock its encrypted mirrored storage during boot AFTER upgrading to 26.05 with `sudo nixos-rebuild boot` and rebooting. Before that upgrade, 25.11 worked. Once the upgrade had been installed/booted, selecting tested older generations ALSO failed; this is not evidence that those generations failed independently before the upgrade. Correct longstanding YubiKey PIN was entered; boot skipped/failed without normal touch interaction. Photos showed failed cryptsetup units for cryptbtrfs_a, cryptbtrfs_b, cryptswap; then mirrored-root-ready failed and dependent root/nix/log mounts failed. Normal emergency console was unusable because root is locked.

## Layout
- LUKS root A UUID 7441e082-69c7-4961-8f78-c3e05cceb966 (currently nvme1n1p3)
- LUKS root B UUID 32849391-1cb2-4ff5-88df-bd9686148480 (currently nvme0n1p3)
- Both decrypted devices form Btrfs UUID 6137e9a6-e9b2-49e6-9ac4-03e044ee845a, label cryptbtrfs.
- Subvolumes: @ (root), @home, @nix, @log, @vm-images, @vm-shared.
- Primary ESP UUID 39D8-C2B4 (currently nvme1n1p1); fallback CC3A-6251 (nvme0n1p1).
- Swap partitions form healthy md RAID1 UUID 25eb788e:0c293850:a21dc655:0086fa90, /dev/md/swap (live /dev/md127); LUKS swap UUID 73967146-7a93-4d6c-8b92-d330f1d2fd70. No need to enable live swap.

## Existing generations
157: /nix/store/643jm8wga6q7rkgcjqg8cdnljw59p5lx-nixos-system-nixos-25.11.20260630.b6018f8, Linux 7.2.15, systemd 258.7, libfido2 1.16.0.
158: /nix/store/46f6f5frr3w0197zdcvcqv2cxdd8jcaq-nixos-system-nixos-26.05.20261108.ac588ef, Linux 7.3.3, systemd 260.5, libfido2 1.17.0.
Both cryptsetup 2.8.6. User previously used Linux 7.3.1; kernel version alone is not strong evidence.

## Findings
- Root LUKS headers readable; passphrase unlock succeeded in live environment.
- Btrfs mounted read-only with rescue=nologreplay; root files accessible. No filesystem repair performed.
- Extracted initrds have IDENTICAL crypttab. Root readiness service and script logic are unchanged between 157 and 158 (only package paths differ).
- Current git working-tree diff includes a substantial initrd-luks-tolerant.nix rewrite BUT it was ALREADY present in generation 157. Do not attribute failure to this diff alone.
- Persisted last successful boot journal (Nov 12 06:53 UTC) shows systemd 258.7 successfully requesting YubiKey presence for all 3 volumes. Failed initrd boot journal was not persisted to installed /var/log.
- Controlled live tests of old and new full software stores, and new initrd-only store, all authenticated the YubiKey and reached successful keyslot 1/digest 0 verification. Subsequent mapping creation failed because the physical disk was already mapped/mounted by rescue; this is NOT an authentication failure.
- Initial test script stdin mistake caused password-agent broadcasts instead of a terminal prompt; corrected to use bash -c and /dev/tty. Do not confuse that test-harness issue with original boot failure.
- New initrd-only test warned missing libpcsclite_real.so.1, but USB FIDO2 authentication still succeeded. This is not established as causal.
- Boot device partlabel paths and /dev/md/swap resolve correctly in live environment.
- No exact underlying failed-boot cryptsetup error identified yet. Boot environment, parallel unlocks, hardware/firmware state and kernel remain possibilities; do not claim a confirmed regression.

## User-approved recovery plan
Preserve current /etc/nixos tracked and untracked config on a rescue git branch; return to original master (there is NO main branch). Preserve logs and this handoff, not photos. Reinstall PRIOR FULL SYSTEM using nixos-install --root <mounted-install> --system <generation-157-store-path> with correct /nix and EFI mounts, not merely select old generation. No formatting, LUKS reenrollment, or generation deletion. Preserve generation 158 and create a separate one-shot/debug boot option. Keep unauthenticated debug shell disabled in normal default entry. Reinstallation may not fix a failure shared by all existing generations.

## Debug route if still needed
New initrd includes systemd-debug-generator and debug-shell.service. On boot menu select entry, press e, append rd.systemd.debug_shell=1, Enter. Ctrl+Alt+F9 accesses independent unauthenticated root shell even if normal emergency shell is locked. After failure run:
  journalctl -b -u 'systemd-cryptsetup@*' --no-pager -n 100
This is security-sensitive; only use temporarily with physical supervision. Actual boot failure logs are the most useful next diagnostic.

## Live paths before writable transition
/mnt/rescue = Btrfs top-level (subvolid=5); /mnt/rescue/@/etc/nixos repo.
/mnt/rescue/@nix/store = installed store (NOT live /nix/store).
/dev/mapper/rescue-a and rescue-b initially read-only; /mnt/boot-a and /mnt/boot-b initially read-only ESP mounts.
Live test logs /home/nixos/fido-*.log, script /home/nixos/test-fido-unlock.sh. Copy these to installed recovery directory before reboot. Photos deliberately omitted.

## Repository before recovery
Branch master HEAD a6f12d2. Modified: flake.lock, flake.nix, modules/desktop.nix, systems/nixos-framework/hw-opts.nix, systems/nixos/disko.nix, systems/nixos/hw-opts.nix, systems/nixos/initrd-luks-tolerant.nix, users/jarrett-home-manager/home.nix. Untracked: bin/desktop-disk-preflight, bin/desktop-disk-prepare-size, docs/solidigm-replacement-status.md, tests/mirrored-root.nix. Preserve all these. Original master configuration predates disk B replacement: do not run disko or partition/format anything.

## Recovery performed
- Reopened rescue-a and rescue-b writable with user-entered passphrases, mounted Btrfs top-level at /mnt/rescue.
- Saved complete config archive, both pre-install EFI backups, test script and diagnostic logs to installed /root/nixos-recovery/ (photos omitted).
- Committed all listed working-tree changes and initial handoff to rescue/pre-reinstall-20261113, commit 7cd4c87. Commit identity Recovery assistant <recovery@localhost>. Returned to master at a6f12d2. RECOVERY-HANDOFF.md is intentionally untracked on master.
- Mounted installed root @ at /mnt/installed, plus @nix, @home, @log, @vm-images, @vm-shared and both ESPs at boot and boot-fallback.
- Ran successfully: sudo nixos-install --root /mnt/installed --system /nix/store/643jm8wga6q7rkgcjqg8cdnljw59p5lx-nixos-system-nixos-25.11.20260630.b6018f8 --no-root-password --no-channel-copy --option substituters 'http://192.168.50.171 https://cache.nixos.org'
- Cache reachable; no downloads reported. Installer rewrote systemd-boot EFI binaries with systemd 258.7 and mirrored primary ESP to fallback. Output saved /root/nixos-recovery/nixos-install.log.
- Installer created generation 159 pointing to the SAME old 25.11 system closure as generation 157. Default loader entry is nixos-generation-159.conf, timeout 5. Generation 158 preserved.
- Separate manual entry nixos-recovery-debug.conf prepared for both ESPs: title 'NixOS 25.11 RECOVERY DEBUG (root shell on tty9)'. Uses old 25.11 closure/initrd with rd.systemd.debug_shell=1 rd.systemd.log_level=debug. Normal default entry has NO debug shell. Debug entry allows unauthenticated local root access; select only under physical supervision and remove after diagnosis. Future rebuild may remove this manual entry.
- Firmware boot order still puts live USB first. Choose internal NVMe UEFI OS in firmware boot menu or remove live USB for installed boot. EFI variables were not reordered.

## What to do next
Try normal default generation 159 after clean unmount. If it fails, select RECOVERY DEBUG, press Ctrl+Alt+F9, then run journalctl -b -u 'systemd-cryptsetup@*' --no-pager -n 100. Photograph actual cryptsetup errors. If journal shows no unit output, inspect journalctl -b --no-pager and systemctl --failed. If debug shell does not open, report that rather than assuming it is available.
On next session ask assistant to read /etc/nixos/RECOVERY-HANDOFF.md and /root/nixos-recovery/. From a live image unlock both disks and mount Btrfs @ to access those paths. Do not format, run disko, or reenroll the YubiKey. Root account password was NOT changed by installer.

## Successful installed boot and automatic-upgrade complication
- Installed boot succeeded normally on Nov 13 at 00:04, selecting generation 159, kernel 7.2.15, systemd-boot 258.7. Kernel command line had no debug-shell option. YubiKey authentication unlocked cryptbtrfs_a, cryptswap and cryptbtrfs_b successfully. The missing libpcsclite_real.so.1 warning also occurred during this successful boot; it did not prevent authentication.
- Btrfs reports both expected mapper devices, with no missing member in `btrfs filesystem show /`. This is not a full filesystem health check.
- Firmware booted the fallback ESP (PARTUUID 8bb8384e-98f1-4bbe-b2ec-51c3fafe8a7d, mounted /boot-fallback). `bootctl` warns because its inspected /boot ESP has PARTUUID 35e64c04-c3ba-4b86-b570-2ac3c2b7fd5f. Both ESPs contain generation 159.
- Automatic upgrade ran shortly after login against old master, updated the unstable input in flake.lock, built generation 160 (/nix/store/xkmbihbjx2nzl4i7z26hlwrxf87c324s-nixos-system-nixos-25.11.20260630.b6018f8, kernel 7.1.2), installed it as default on both ESPs and switched userspace configuration. Generation 160 has NOT been boot-tested.
- Activation returned status 4 after failing to restart home.mount and var-log.mount. The systemd exit label NOPERMISSION is not evidence of a permission error. Both paths were subsequently confirmed mounted on their expected Btrfs subvolumes.
- At 00:14 the user stopped nixos-upgrade.timer and nixos-upgrade.service, changed BOTH loader.conf defaults back to nixos-generation-159.conf and ran bootctl set-default for that entry. Verification showed timer inactive and both file defaults correct. The timer stop does NOT survive reboot; unattended upgrades still need a durable hold.
- Current repo remains master a6f12d2, with modified flake.lock and untracked handoff. Preserve these before branch changes. The saved rescue branch also includes a full 26.05 input upgrade, not just disk-replacement fixes; restoring it is not equivalent to reconstructing the known-working 25.11 generation.
- Temporary unauthenticated debug entry remains present; retire it on BOTH ESPs once diagnostic access is no longer needed. Do not rebuild or switch merely to clean up boot entries.
- Original boot failure cause is still unknown. Do not attribute success specifically to bootloader replacement, reinstall, or hardware reset without further evidence.

## Controlled 26.05 probe preparation (subsequently boot-tested; see below)
- User wants to diagnose and run 26.05, NOT stabilize on 25.11. Do not prepare another 25.11 build.
- Actual generation 157/158 installer programs have essentially identical logic (apart from irrelevant devicetree handling and package paths); both use bootctl update when a newer version is available, with --no-variables configured. Generation 158 changes the shared EFI loader from 258.7 to 260.5. This is a testable suspect, not a confirmed cause.
- `bin/desktop-2605-boot-probe` prepares a separate manual entry for the exact existing generation 158 under the currently installed 258.7 EFI loader. Requires `sudo bash`; verifies both ESP identities, both kernel/initrd copies against store originals, and both loader paths against the 258.7 store binary BEFORE writing entries.
- Probe enables temporary initrd debug-shell access and stage-2 masks for automatic upgrade and systemd-boot-update. Does not change defaults, EFI binaries, system profile, repository branch, or initiate reboot. These masks apply ONLY when the probe entry is booted.
- If 26.05 probe succeeds, the 26.05 initrd can boot under the old loader; investigate shared loader/hardware state next. It would not by itself prove a 260.5 loader regression. If it fails, capture actual failed initrd journal on the ESP using the commands printed by the helper, before retrying unlock.
- At 00:29 the user successfully ran `sudo bash /etc/nixos/bin/desktop-2605-boot-probe`. Both probe entries were installed; both ESP kernel/initrd copies matched generation 158 store originals, and both loader paths on both ESPs matched systemd-boot 258.7. Defaults and EFI binaries were not changed. Next action is manual boot of the probe entry under physical supervision.
- User clarified original failure behavior: a PIN prompt accepted Enter but repeatedly prompted again; YubiKey never blinked/requested touch and no volume unlocked. Exact prompt wording is not yet captured, so distinguish FIDO2 token PIN from a LUKS recovery passphrase prompt. On recurrence, avoid repeated PIN submissions (retry lockout risk), switch to tty9 and capture logs BEFORE manual unlock attempts. Focus on errors before successful token-presence interaction, not just downstream mount failures.

## Successful 26.05 diagnostic boot
- User successfully booted the probe on Nov 13, with cryptsetup activity around 00:53, and reports YubiKey PIN entry successfully unlocked the disks. Boot menu titles were shortened on both ESPs for identification: probe is `DIAG 26.05 - F9 SHELL`, old debug entry is `DIAG 25.11 - F9 SHELL`, generation entries use `G<number> - <release> - K<kernel>`.
- Both /run/booted-system and /run/current-system resolve to exact generation 158 closure /nix/store/46f6f5frr3w0197zdcvcqv2cxdd8jcaq-nixos-system-nixos-26.05.20261108.ac588ef; running kernel is 7.3.3.
- User-provided privileged bootctl output confirms Current Boot Loader systemd-boot 258.7, Current Entry nixos-2605-probe.conf, booted from fallback ESP PARTUUID 8bb8384e-98f1-4bbe-b2ec-51c3fafe8a7d via EFI/BOOT/BOOTX64.EFI. Its ESP mismatch warning reflects inspection of primary /boot, not evidence of an unlock failure.
- Both loader.conf defaults and bootctl Default Entry remain nixos-generation-159.conf (25.11). No EFI binaries or defaults changed in this session.
- Current command line includes the three probe stage-2 masks, rd.systemd.debug_shell=1 and rd.systemd.log_level=debug. All three masked units were independently verified LoadState=masked, ActiveState=inactive.
- Supplied journal tail explicitly shows cryptswap FIDO2 token 0/keyslot 1 verification, successful mapper creation, `Volume cryptswap activated with a LUKS token`, and exit status 0/SUCCESS. Both root cryptsetup units show `Changed dead -> exited`; tail is dominated by swap debug traffic, not the complete root unlock sequence.
- This establishes that the exact 26.05 kernel/initrd and YubiKey authentication CAN work under the preserved 258.7 EFI loader. It does NOT establish a 260.5 loader regression or explain why older entries also failed originally. Debug logging/timing and hardware state remain uncontrolled differences.
- An intermediate non-debug probe was suggested but user declined as excessively cautious. Superseded by the approved ordinary rebuild/boot plan below.
- Debug journal includes raw FIDO2 protocol traffic; preserve diagnostic logs privately and avoid publishing unreviewed full debug dumps.

## Preparation for ordinary 26.05 rebuild and reboot

### Scope and status
- User approved preparation of working EFI backups, today's successful boot journal and a usable recovery route, then the normal 26.05 rebuild/boot test. Do not use `switch`. No additional probe boot is wanted.
- Helpers: `/etc/nixos/bin/desktop-2605-rebuild-recovery` (`prepare` / `after`) and `/etc/nixos/bin/desktop-restore-2587-efi`. Run with `sudo bash`; executable bits are not required. The standalone restore helper is copied into each backup so repo changes cannot remove the recovery tool.
- Preparation completed: user ran the helper at Nov 13 01:11; it printed `READY: /root/nixos-recovery/pre-2605-rebuild-20261113T011107-7Ne5up`. All reported checksums passed, including both complete ESP archives, repository archive, journals and standalone restore helper. The relative `latest-pre-2605-rebuild` link was created. No EFI binaries/defaults/profile were changed by preparation.
- Validation: both helpers pass `bash -n` and ShellCheck 0.11.0. A temporary-directory restore test with mocked mount/EFI-variable tools passed restoration of both loaders/defaults, tab-separated options/masks, preservation of newer files, and refusal of wrong UUIDs, wrong FAT masks and corrupt backups. Actual backup and archive comparisons subsequently succeeded; a real restore has NOT been attempted.
- Configuration restoration completed after the verified backup: `git restore --source=rescue/pre-reinstall-20261113 --staged --worktree -- . ':!RECOVERY-HANDOFF.md'`. Branch remains master, HEAD a6f12d2; 12 saved config files/additions are staged, with NO differences from rescue/pre-reinstall-20261113 except the intentionally preserved handoff/untracked recovery helpers. Confirmed nixpkgs and Home Manager URLs are 26.05; staged whitespace validation passed. No commit created. There is no main branch.
- Rebuild completed at Nov 13 01:12 using `boot`, NOT `switch`. Output explicitly reports systemd-boot update from 258.7 to 260.5 on /boot and successful rsync mirror to fallback. Output closure is EXACTLY /nix/store/46f6f5frr3w0197zdcvcqv2cxdd8jcaq-nixos-system-nixos-26.05.20261108.ac588ef (G158). Independently verified system profile now points through system-161-link to this closure; booted/current paths still match it. Thus rebuilt system identity introduces no additional software/config difference from the successful probe. Reboot remains pending.
- Build log is `nixos-rebuild-boot.log` in the verified backup directory. After-state capture completed at `after-20261113T011256-51WgMm/`. Boot warnings (dirty Git tree, unused flake-utils override, package deprecations) did not prevent successful rebuild.
- Root-run Git inspection under umask 077 apparently refreshed `.git/index` as root:root mode 0600, causing the later user direnv/libgit2 failure and `git status` permission error. This is separate from boot installation, NOT evidence of a failed rebuild. Helper now exports `GIT_OPTIONAL_LOCKS=0` to prevent index refresh. Repair ONLY this index's ownership/mode, not the entire repository, using the final check command below.
- The pre-restoration modified lockfile and all untracked files are in `etc-nixos.tar`. Archived handoff/status copies may predate these results; this current `/etc/nixos/RECOVERY-HANDOFF.md` supersedes them.

### 1. Back up the known-working state (COMPLETED)
```bash
sudo bash /etc/nixos/bin/desktop-2605-rebuild-recovery prepare
```
The helper:
- Requires current and booted systems to be generation 158 and upgrade/update units to be masked and inactive.
- Verifies both ESP UUIDs, both EFI loader paths against the known 258.7 store binary, generation 158 kernel/initrd, and the complete normal generation 159 entry/kernel/initrd against the known 25.11 closure.
- Creates a private `/root/nixos-recovery/pre-2605-rebuild-<timestamp>-<suffix>/`; prints its actual path. Relative symlink `/root/nixos-recovery/latest-pre-2605-rebuild` points to it.
- Saves complete ESP file archives `boot.tar` and `boot-fallback.tar` (except random seed), compares archives against mounted source files, saves 258.7 binary and standalone `restore-efi.sh`.
- Saves entire `/etc/nixos`, including `.git`, modified lockfile, tracked/untracked config and current handoff, as `etc-nixos.tar`.
- Saves current successful boot's full journal and cryptsetup journal, boot list, loader status/list, all EFI/entry hashes, mount identities, unit states, git status/diff and booted/current/profile closure paths under `before/`.
- GC-roots both known-good closures (25.11 G157/G159 and 26.05 G158). Does not change the system profile or install any boot files.
- Writes/verifies `SHA256SUMS`, marks `PREPARED`, then prints `READY`. If it fails, stop and inspect; do not rebuild on the strength of a partial backup. Capture logs contain sensitive FIDO2 debug traffic; do not publish them wholesale.

### 2. Restore the saved 26.05 configuration onto master (COMPLETED)
After successful backup, as the normal repo owner, from `/etc/nixos`:
```bash
git restore --source=rescue/pre-reinstall-20261113 --staged --worktree -- . ':!RECOVERY-HANDOFF.md'
git status --short
git diff --cached --stat
```
This retains master, restores the rescue branch's tracked 26.05 configuration and lockfile (including disk-replacement fixes), and deliberately preserves this newer handoff. The new helpers remain untracked and present. The prior modified lockfile and all other current contents are preserved in the backup. Do NOT run `git reset --hard`, `git clean`, disko, `nix flake update`, partitioning, formatting, or YubiKey enrollment. Review the restored input URLs as 26.05 before rebuilding. This restores saved configuration; it does not guarantee an identical output closure to G158.

### 3. Rebuild for the next boot, log output, capture result (COMPLETED)
```bash
sudo bash -c '
set -euo pipefail
b=$(readlink -f /root/nixos-recovery/latest-pre-2605-rebuild)
test -f "$b/PREPARED"
umask 077
export GIT_OPTIONAL_LOCKS=0
cp /etc/nixos/RECOVERY-HANDOFF.md "$b/HANDOFF-LATEST.md"
nixos-rebuild boot --flake /etc/nixos#nixos --no-update-lock-file 2>&1 |
  tee "$b/nixos-rebuild-boot.log"
bash /etc/nixos/bin/desktop-2605-rebuild-recovery after "$b"
'
```
Do not reboot if rebuild fails. This installs a boot generation without switching current userspace/kernel or retesting LUKS. It may update the shared EFI loader to 260.5 on BOTH ESPs, despite the running probe's systemd-boot-update.service mask (the installer updates it directly). An older generation entry alone does NOT preserve the old EFI loader.

Before reboot, review the new `after-*/` evidence against `before/`:
- New system profile path versus exact G158 closure; if different, software/config differences are additional variables.
- On-disk EFI loader versions/hashes on BOTH ESPs; before reboot `Current Boot Loader` still reports the already-running 258.7 boot, NOT the version next boot will use.
- New default entry on BOTH ESPs and its kernel/initrd/options. Installer may regenerate the shortened generation titles; do not rely on old title text or assume next generation number.
- Normal new entry must not contain `rd.systemd.debug_shell=1`. Probe masks/debug flags are NOT inherited automatically into the normal entry. Restored config must be 26.05 before automatic upgrades resume after reboot.
- Confirm generation 159 and diagnostic entries remain usable, and have a live USB and LUKS recovery passphrases available. If installer removes manual diagnostics, the menu edit route below can enable a temporary debug shell.

Only after these checks, user reboots normally into the new 26.05 default. No additional diagnostic test boot is required.

Final pre-reboot command for the completed G161 build (pending execution): repairs index permissions, verifies BOTH on-disk 260.5 loader paths, validates G161's closure/no-debug option and both file defaults, sets the EFI menu default to G161 (old explicit G159 variable could otherwise override loader.conf), and saves the updated handoff. No rebuild:
```bash
sudo bash -c '
set -euo pipefail
chown --reference=/etc/nixos/.git /etc/nixos/.git/index
chmod 644 /etc/nixos/.git/index
loader=/nix/store/y3fqx697649kqv1a9c0z1jsk4wy2zlqa-systemd-260.5/lib/systemd/boot/efi/systemd-bootx64.efi
system=/nix/store/46f6f5frr3w0197zdcvcqv2cxdd8jcaq-nixos-system-nixos-26.05.20261108.ac588ef
for spec in /boot:39D8-C2B4 /boot-fallback:CC3A-6251; do
  esp=${spec%:*}; uuid=${spec##*:}
  test "$(findmnt -rn -o UUID --mountpoint "$esp")" = "$uuid"
  cmp "$loader" "$esp/EFI/BOOT/BOOTX64.EFI"
  cmp "$loader" "$esp/EFI/systemd/systemd-bootx64.efi"
  entry="$esp/loader/entries/nixos-generation-161.conf"
  grep -qF "init=$system/init" "$entry"
  if grep -q "debug_shell" "$entry"; then
    printf "Unexpected debug shell in %s\n" "$entry" >&2
    exit 1
  fi
  grep -Eq "^default[[:space:]]+nixos-generation-161.conf[[:space:]]*$" "$esp/loader/loader.conf"
  printf "Verified G161 and both 260.5 EFI loader paths on %s\n" "$esp"
done
bootctl set-default nixos-generation-161.conf
bootctl set-oneshot nixos-generation-161.conf
cp /etc/nixos/RECOVERY-HANDOFF.md /root/nixos-recovery/latest-pre-2605-rebuild/HANDOFF-LATEST.md
sync
printf "Ready to reboot into G161 (26.05).\n"
'
```
Final checks completed by user at Nov 13 01:15: command verified both 260.5 loader paths on both ESPs, G161 entry presence and both file defaults, repaired index ownership/mode, successfully set EFI default and one-shot to G161, copied the then-current handoff to HANDOFF-LATEST.md, and printed `Ready to reboot into G161 (26.05).` The executed command did not separately inspect G161 init/options; the matching rebuilt closure is established above. No reboot outcome yet. After a successful normal boot, record actual loader/entry and unlock success, then retire both temporary DIAG entries without rebuilding.

### 4. Evidence after reboot, or capture on recurrence
On success, record which entry/EFI loader actually booted, current/booted/profile paths, and successful unlock journals:
```bash
sudo bash /etc/nixos/bin/desktop-2605-rebuild-recovery after
```
Then update this handoff with the actual outcome and backup directory name. Success with confirmed 260.5 loader means the normal upgrade works now; it does not explain the original failure. Retire temporary debug entries on BOTH ESPs after recovery access is no longer needed.

If prompts repeat without touch interaction, avoid repeated PIN attempts. A normal entry does not expose tty9. Reboot to the menu if needed, edit the failing entry (`e`), append `rd.systemd.debug_shell=1 rd.systemd.log_level=debug`, boot under physical supervision and try Ctrl+Alt+F9. This captures a subsequent diagnostic attempt, not the already-lost first failed boot. If the debug shell does not open, report it; do not assume it exists.

From the initrd debug shell, BEFORE manual unlock attempts, save logs to the primary ESP:
```bash
mkdir -p /run/recovery-esp
mount /dev/disk/by-uuid/39D8-C2B4 /run/recovery-esp
cat /proc/cmdline > /run/recovery-esp/26.05-failed-cmdline.txt
journalctl -b --no-pager > /run/recovery-esp/26.05-failed-journal.txt
journalctl -b -u 'systemd-cryptsetup@*' --no-pager > /run/recovery-esp/26.05-failed-cryptsetup.txt
systemctl --failed --no-pager > /run/recovery-esp/26.05-failed-units.txt
sync
umount /run/recovery-esp
```
Logs on an unencrypted ESP may contain sensitive debugging data; move to private recovery storage after diagnosis. If falling back to a prior entry, remember it still uses the updated shared loader until EFI files are restored.

### 5. Restore the known-good 258.7 EFI boot environment if needed
From the running installed system (e.g. rebuild completed but reboot not yet attempted):
```bash
sudo bash /root/nixos-recovery/latest-pre-2605-rebuild/restore-efi.sh \
  /root/nixos-recovery/latest-pre-2605-rebuild
```
This overlays the old full ESP contents on BOTH disks without formatting or deleting newer files, verifies restored file hashes and both loader paths, sets G159 as normal recovery default, and adds upgrade/update masks to G159 so old master cannot trigger another unattended switch. It attempts to set EFI default/one-shot to G159; if EFI variables are unavailable, manually choose G159. It does not reset the system profile, installed configuration, LUKS headers or running system.

If no installed entry boots, use a live USB. The following is a fresh live session; if mappings/mounts already exist, inspect and reuse them rather than opening/mounting twice. Use LUKS recovery PASSPHRASES at the cryptsetup prompts, not the YubiKey PIN:
```bash
sudo cryptsetup open /dev/disk/by-uuid/7441e082-69c7-4961-8f78-c3e05cceb966 rescue-a
sudo cryptsetup open /dev/disk/by-uuid/32849391-1cb2-4ff5-88df-bd9686148480 rescue-b
sudo btrfs device scan /dev/mapper/rescue-a /dev/mapper/rescue-b
sudo mkdir -p /mnt/installed
sudo mount -o subvol=@ /dev/mapper/rescue-a /mnt/installed
sudo mount -o subvol=@nix /dev/mapper/rescue-a /mnt/installed/nix
sudo mount -o rw,umask=0077 /dev/disk/by-uuid/39D8-C2B4 /mnt/installed/boot
sudo mount -o rw,umask=0077 /dev/disk/by-uuid/CC3A-6251 /mnt/installed/boot-fallback
sudo ls -ld /mnt/installed/root/nixos-recovery/pre-2605-rebuild-*
```
Use the actual timestamped directory printed by step 1, replacing `<BACKUP>` below. Both the script and backup argument must be paths INSIDE the mounted installed root; the final argument supplies that root prefix:
```bash
sudo bash /mnt/installed/root/nixos-recovery/<BACKUP>/restore-efi.sh \
  /mnt/installed/root/nixos-recovery/<BACKUP> /mnt/installed
sudo sync
sudo umount -R /mnt/installed
sudo cryptsetup close rescue-b
sudo cryptsetup close rescue-a
```
FAT extraction requires writable ESP mounts with `fmask=0077,dmask=0077` (the `umask=0077` commands above supply these). Restore refuses unexpected UUIDs/mount options before writing. No chroot, reinstall, formatting, md/swap changes or YubiKey reenrollment is needed for EFI restoration. Boot the internal NVMe and select G159; its upgrade/update masks keep recovery stable while diagnosing.
