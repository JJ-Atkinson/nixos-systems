# Looking Glass Stutter Scratch Notes

Date: 2026-05-06

Goal: preserve the current findings so the investigation can resume quickly after reboot or context reset.

## Context

- Host repo: `/etc/nixos`
- VM config of interest: `/etc/nixos/systems/nixos/vms/Windows11.xml`
- Main NixOS virtualization config: `/etc/nixos/systems/nixos/virtualization-opts.nix`
- Looking Glass / VirtioFS overlay: `/etc/nixos/modules/virtiofsd-looking-glass.nix`
- User uses a physical HDMI dongle on the passed-through secondary GPU.
- IDD / IddSampleDriver should not be treated as the default suspect, although repo docs still mention it.

## Active Runtime Snapshot

- `virsh -c qemu:///system list --all` showed `Windows11` running as domain id `3`.
- Plain `virsh` did not see the domain; use `qemu:///system` explicitly.
- `looking-glass-client` was running from `looking-glass-client-B7`.
- `/dev/kvmfr0` existed with `root:kvm` ownership and `0660` permissions.
- `kvmfr` was loaded and used.

## Strong Suspects

### 1. Looking Glass Client Competes With VM CPUs

Observed with:

```bash
ps -T -p 694750 -o pid,tid,psr,cls,rtprio,pri,ni,pcpu,stat,comm
taskset -pc 694750
```

Findings:

- `looking-glass-client` affinity was `0-27`, so it can run anywhere.
- Several LG threads were observed on VM-pinned CPUs:
- `renderThread` on CPU10
- `frameThread` on CPU16
- `cursorThread` on CPU5
- Some trace / GL / shared-memory threads were also on VM CPUs.

Why it matters:

- The VM pins vCPUs to `2-13,16-19`.
- If the LG client runs on those same CPUs, display capture/rendering can fight with guest vCPU scheduling and create frame pacing spikes.

Fast test:

```bash
taskset -c 20-27 looking-glass-client
```

Alternative test, leaving some E-cores and host P-core siblings available:

```bash
taskset -c 0,1,14,15,20-27 looking-glass-client
```

### 2. Host IRQs Land On VM CPUs

Observed with:

```bash
cat /proc/interrupts
```

Findings:

- Host `amdgpu` IRQ line had heavy counts on CPU17, which is assigned to VM vCPU13.
- `/vm-storage/images` is on `/dev/nvme2n1` mounted as btrfs; `nvme2` IRQs are spread across many CPUs including VM CPUs.
- Network and USB IRQs also appear on CPU ranges that overlap VM cores.

Why it matters:

- vCPU pinning does not stop host IRQ handlers from interrupting those CPUs.
- Looking Glass stutter can show up as intermittent frame pacing jitter even if average CPU usage is low.

Likely next checks:

```bash
cat /proc/interrupts
for f in /proc/irq/*/smp_affinity_list; do printf '%s ' "$f"; cat "$f"; done
```

Potential direction:

- Keep VM vCPUs on `2-13,16-19` only if IRQ affinity is moved off that set.
- Otherwise choose a simpler CPU split and reserve clean host CPUs for compositor, LG client, disk IRQs, and GPU IRQs.

### 3. Deep qcow2 Snapshot Chain

Active XML showed disk path:

```text
/vm-storage/images/windows11.snapshot-20260205-015646
```

The active QEMU command line showed a long backing chain:

```text
windows11.snapshot-20260205-015646
windows11.snapshot-20260127-035655
windows11.snapshot-20260124-231520
windows11.snapshot-20260124-231005
windows11.snapshot-20260124-222852
windows11.snapshot-20260124-222408
windows11.snapshot-20260124-221051
windows11.snapshot-20260124-214449
windows11.snapshot-20260124-210227
windows11.fresh-install
windows11.qcow2
```

The checked-in XML is stale compared with runtime: checked-in top image was `windows11.snapshot-20260124-231520`; runtime top image was `windows11.snapshot-20260205-015646`.

Why it matters:

- Deep qcow2 chains add lookup and write amplification latency.
- This is worse for random I/O and can create hitching if the guest touches storage during interactive use.
- VM storage is on btrfs (`/vm-storage/images`), and QEMU is using buffered `cache=writeback` rather than direct/native I/O.

Observed block stats:

```text
vda rd_bytes ~= 7.9 GB
vda wr_bytes ~= 1.2 GB
vda flush_operations ~= 4290
```

Possible direction:

- Consolidate / flatten the chain after taking a backup.
- Consider raw image or qcow2 with shallow snapshots only.
- Consider `cache=none` / native I/O if compatible with the storage setup.

### 4. No Host CPU Isolation Parameters

Observed from `/proc/cmdline`:

```text
intel_iommu=on iommu=pt root=fstab loglevel=4 lsm=landlock,yama,bpf
```

Missing:

- `isolcpus`
- `nohz_full`
- `rcu_nocbs`
- explicit IRQ-affinity strategy

Why it matters:

- Pinning controls where QEMU vCPU threads may run.
- It does not isolate those CPUs from host scheduler work, kernel timers, RCU callbacks, IRQs, or unrelated processes.

Potential direction:

- Add isolation for the VM CPU set if committing to that split.
- Or reduce VM CPU set first, then isolate only the chosen set.

### 5. Hybrid CPU Topology Presented As Homogeneous SMT

CPU topology:

- Host has i7-14700KF-style layout documented in repo.
- P-core threads: CPUs `0-15`, pairs by core.
- E-cores: CPUs `16-27`, one thread each.

VM XML exposes:

```xml
<topology sockets='1' dies='1' clusters='1' cores='8' threads='2'/>
```

But the pinned CPUs are:

```text
2-13,16-19
```

Why it matters:

- This tells Windows it has 8 SMT cores, but the last 4 vCPUs are actually E-cores with no SMT sibling.
- Windows may schedule latency-sensitive work onto the wrong virtual topology.

Potential direction:

- Test a simpler P-core-only VM: 12 vCPUs on CPUs `2-13`, topology `cores=6 threads=2`.
- Keep host/LG/compositor/IRQs on `0,1,14,15,16-27` initially.
- If E-cores are needed, expose them more intentionally instead of pretending they are SMT siblings.

## Things That Look Less Likely

### IDD / Virtual Display Driver

- User reports IDD was previously installed but removed.
- Current desired display path is physical HDMI dongle on the passed-through GPU.
- Host-side evidence points to scheduling, IRQ, disk, and topology issues first.
- Docs still mention `IddSampleDriver`; that documentation may be stale but is not proof it is active.

### KVMFR Size / Permissions

- `/dev/kvmfr0` exists and permissions look sane.
- Config uses `kvmfr static_size_mb=128`, matching 128 MiB IVSHMEM in VM XML.
- Size is plausible for 4K SDR according to existing docs.

## Commands Worth Re-running After Reboot

```bash
virsh -c qemu:///system list --all
virsh -c qemu:///system dumpxml Windows11
virsh -c qemu:///system vcpuinfo Windows11
virsh -c qemu:///system domstats --vcpu --block Windows11
pgrep -af qemu-system-x86_64
pgrep -af looking-glass-client
ps -T -p <qemu-pid> -o pid,tid,psr,cls,rtprio,pri,ni,pcpu,stat,comm
ps -T -p <lg-pid> -o pid,tid,psr,cls,rtprio,pri,ni,pcpu,stat,comm
taskset -pc <qemu-pid>
taskset -pc <lg-pid>
cat /proc/cmdline
cat /proc/interrupts
mount
stat /dev/kvmfr0
lsmod
```

## Recommended Investigation Order

1. Pin Looking Glass client away from VM CPUs and test stutter.
2. Move host IRQ affinity away from VM CPUs and test again.
3. Flatten or simplify the VM disk snapshot chain.
4. Test P-core-only CPU topology.
5. Add boot-time CPU isolation once the desired CPU split is proven.

## Runtime Test Log

### 2026-05-06 Test 1: Pin Existing LG Client Off VM CPUs

VM vCPU set confirmed with `virsh -c qemu:///system vcpuinfo Windows11`:

```text
VM CPUs: 2-13,16-19
```

Existing LG PID:

```text
694750 /nix/store/agm8fkcn2fh2ixpf8ayfbyj3wl24y3qs-looking-glass-client-B7/bin/looking-glass-client
```

Applied live, reversible affinity change:

```bash
taskset -acp 20-27 694750
```

Result:

```text
pid 694750 affinity changed from 0-27 to 20-27, including all current threads
```

Notes:

- This avoids all VM vCPU cores.
- This also avoids host P-core siblings `0,1,14,15`; the test intentionally uses E-cores only to make overlap removal clear.
- If LG is restarted, this runtime affinity change is lost. Relaunch for the same test with:

```bash
taskset -c 20-27 looking-glass-client
```

User result: same or slightly improved; hard to tell.

### 2026-05-06 Test 2 Prep: Host IRQ Affinity

Target IRQs selected for the next runtime test:

- `nvme2` IRQs `152 155 157 160 162 164 167 169 171 173 176 178 180 181 182 183 184 185 186 187 188 189 190 191 192 193 194 195 196`
- host `amdgpu` IRQ `241`

Target host-only CPU set:

```text
0,1,14,15,20-27
```

Initial attempt to write `/proc/irq/*/smp_affinity_list` failed because root is required and this session cannot answer the sudo password prompt.

Created helper script:

```bash
/etc/nixos/looking-glass-irq-affinity-test.sh
```

Commands:

```bash
./looking-glass-irq-affinity-test.sh status
sudo bash ./looking-glass-irq-affinity-test.sh apply
sudo bash ./looking-glass-irq-affinity-test.sh restore
```

The script only changes runtime IRQ affinity. Reboot also resets it.

Follow-up:

- `sudo -v` briefly succeeded after YubiKey attachment, but later sudo commands again required an interactive terminal prompt unavailable to the tool.
- First apply attempt changed IRQ `152` to `0-1,14-15,20-27`, then failed on IRQ `155` with `Operation not permitted`.
- This suggests many `nvme2` queue IRQs are managed MSI-X IRQs that the kernel will not let us move at runtime.
- Updated helper script to make apply/restore best-effort and continue after kernel-rejected IRQs.
- Next local command to run in a real terminal:

```bash
cd /etc/nixos
sudo bash ./looking-glass-irq-affinity-test.sh apply
```

Expected behavior: some `nvme2` IRQs may print `skipped IRQ ...`; movable IRQs such as host `amdgpu` should still be moved if the kernel permits it.

Applied after sudo/YubiKey attention:

```bash
sudo -v && sudo bash ./looking-glass-irq-affinity-test.sh apply
```

Result:

- `nvme2` queue IRQs `155..196` were rejected by the kernel as non-movable managed IRQs.
- IRQ `152` changed to `0-1,14-15,20-27`.
- Host `amdgpu` IRQ `241` changed to `0-1,14-15,20-27`.
- Therefore the meaningful active runtime part of test 2 is host GPU IRQ isolation from VM CPUs; storage IRQ isolation did not apply for managed queues.

Current combined runtime test state:

- Looking Glass client pinned to `20-27`.
- Host `amdgpu` IRQ moved to `0-1,14-15,20-27`.
- Most `nvme2` IRQs remain one queue per CPU, including VM CPUs.

User result: slightly improved.

Expanded IRQ pass:

- Added host IRQs `129 212 221 238 239 240` to the affinity test.
- These correspond to observed host USB, ethernet, and audio IRQs that had activity on VM CPUs.
- Applied successfully along with IRQs `152` and `241`.
- Managed `nvme2` per-queue IRQs `155..196` still rejected runtime affinity changes.

Current expanded runtime state:

- Looking Glass client pinned to `20-27`.
- Host IRQs `129 212 221 238 239 240 152 241` moved to `0-1,14-15,20-27`.
- Managed `nvme2` queue IRQs remain spread across CPUs, including VM CPUs.

User result: feels better.

Mass undo for A/B test:

```bash
sudo bash ./looking-glass-irq-affinity-test.sh restore
taskset -acp 0-27 <lg-pid>
```

Actual result:

- IRQs restored to baseline for movable IRQs.
- Managed `nvme2` IRQs were unchanged, as expected.
- Old LG PID `694750` had exited, so no LG affinity reset was needed. A newly launched LG client defaults to all CPUs unless launched through `taskset`.

Implemented isolated Nix module:

```text
/etc/nixos/modules/looking-glass-stutter-tuning.nix
```

Imported from:

```text
/etc/nixos/flake.nix
```

Module behavior:

- Adds `boot.kernelParams = [ "isolcpus=managed_irq,2-13,16-19" ];` so managed driver IRQs try to avoid VM CPUs at boot when possible.
- Installs `looking-glass-client-tuned`, which runs Looking Glass pinned to `0,1,14,15,20-27`.
- Installs `looking-glass-irq-affinity`, with `apply` and `status` subcommands.
- Adds `systemd.services.looking-glass-irq-affinity`, a root oneshot that applies best-effort runtime affinity for movable host IRQs matched by driver/device names.
- Excludes `vfio` IRQs intentionally.

Validation commands run successfully:

```bash
nix eval 'path:/etc/nixos#nixosConfigurations.nixos.config.boot.kernelParams'
nix eval 'path:/etc/nixos#nixosConfigurations.nixos.config.systemd.services.looking-glass-irq-affinity.description'
nix build 'path:/etc/nixos#nixosConfigurations.nixos.config.system.build.toplevel' --dry-run
```

Rollback path:

- Remove `./modules/looking-glass-stutter-tuning.nix` from `flake.nix`.
- Delete `/etc/nixos/modules/looking-glass-stutter-tuning.nix`.
- Rebuild and reboot to remove the boot kernel parameter.

## 2026-05-06 Disk Flattening And I/O Tuning

Goal: remove deep qcow2 backing-chain latency and switch the VM disk from buffered writeback to direct/native I/O.

Starting state:

- VM was running from `/vm-storage/images/windows11.snapshot-20260205-015646`.
- `/vm-storage/images` had about `1.6T` free before conversion.
- Backing chain had 11 qcow2 layers:

```text
windows11.snapshot-20260205-015646
windows11.snapshot-20260127-035655
windows11.snapshot-20260124-231520
windows11.snapshot-20260124-231005
windows11.snapshot-20260124-222852
windows11.snapshot-20260124-222408
windows11.snapshot-20260124-221051
windows11.snapshot-20260124-214449
windows11.snapshot-20260124-210227
windows11.fresh-install
windows11.qcow2
```

Actions taken:

```bash
virsh -c qemu:///system shutdown Windows11
sudo qemu-img convert -p -f qcow2 -O qcow2 \
  -o lazy_refcounts=on,cluster_size=2M \
  /vm-storage/images/windows11.snapshot-20260205-015646 \
  /vm-storage/images/windows11.flattened-20260506.qcow2
```

Flattened image verification:

```text
image: /vm-storage/images/windows11.flattened-20260506.qcow2
file format: qcow2
virtual size: 500 GiB
disk size: 153 GiB
cluster_size: 2097152
lazy refcounts: true
backing file: none
```

Persistent VM disk was updated with:

```xml
<driver name='qemu' type='qcow2' cache='none' io='native' discard='unmap'/>
<source file='/vm-storage/images/windows11.flattened-20260506.qcow2'/>
```

Runtime verification after start:

- `virsh -c qemu:///system domblklist Windows11 --details` shows `vda` using `/vm-storage/images/windows11.flattened-20260506.qcow2`.
- Running XML shows `<backingStore/>` for `vda`.
- QEMU command line shows `aio=native` and `cache.direct=true` for the flattened disk.

Repo state:

- Saved updated libvirt XML to `/etc/nixos/systems/nixos/vms/Windows11.xml`.
- Existing old qcow2 chain was not deleted and can be used for rollback.

Old chain cleanup:

- User confirmed backups exist and asked to delete the old chain.
- Removed libvirt external snapshot metadata for `fresh-install` and all `snapshot-*` entries.
- Deleted old chain files from `/vm-storage/images`.
- Remaining Windows image file is only:

```text
/vm-storage/images/windows11.flattened-20260506.qcow2
```

Post-cleanup verification:

- `virsh -c qemu:///system snapshot-list Windows11 --tree` returns no snapshots.
- `virsh -c qemu:///system domblklist Windows11 --details` still shows `vda` using the flattened image.
- `/vm-storage/images` usage dropped from about `429G` used to about `174G` used.

Disk rollback path now requires restoring the old chain from external backup, because the local old chain was intentionally deleted.

Looking Glass performance overlay crash:

- Client and guest are both Looking Glass `B7`.
- Crash reproduced when enabling the performance metrics/timing graph overlay:

```text
looking-glass-client: /build/source/repos/cimgui/imgui/imgui.cpp:10575: bool ImGui::ItemAdd(...): Assertion `id != window->ID && "Cannot have an empty ID at the root of a window..."' failed.
```

- Root cause appears to be `client/src/overlay/graphs.c` passing a raw `GraphHandle` pointer as the ImGui `PlotLines` label. The cimgui API expects a string label/ID there.
- Added local Nix patch:

```text
patches/looking-glass-b7-graph-imgui-id.patch
```

- The patch wraps each graph plot with `igPushID_Ptr(graph)` and uses a hidden string label `##timingGraph`, preserving the displayed overlay text while giving ImGui a valid ID.
- Added the patch through the existing `modules/looking-glass-stutter-tuning.nix` overlay.
- Verified patched package builds:

```text
/nix/store/lvl4lrb36cmw0qr3nric48wrd02slib7-looking-glass-client-B7
```

- Full system dry-run succeeds and includes rebuilding `looking-glass-client-tuned` against the patched package.

Damage overlay observation:

- User observed that when Looking Glass damage goes from `0` area to a large region, latency is bad for roughly the next dozen frames.
- If the same large-damage condition continues, such as continuously moving a window, latency smooths out quickly.
- In B7/D12, damage comes from Windows desktop duplication dirty/move rects. The host uses these rects to copy only changed regions into KVMFR, and the client forwards those rects to the renderer.
- This pattern suggests a transition/wake-up issue more than steady bandwidth exhaustion. Likely suspects:
  - guest GPU/capture engine clocks ramping up after idle
  - host GPU/client renderer clocks ramping up after idle
  - Windows DWM/DXGI duplication producing a burst of dirty/move rects after idle
  - LG frame pacing/render queue absorbing the first burst before settling
- Useful A/B tests:
  - On Windows host app, set `[d12] trackDamage=no` to force full-frame copies and see whether the spike disappears, becomes constant, or gets worse.
  - Keep the guest GPU in a maximum-performance power profile and retest idle-to-damage transitions.
  - Try increasing client minimum redraw/frame behavior (`win:fpsMin`) only if the host-side damage test suggests the idle transition is the trigger.

Damage tracking A/B result:

- User set Windows guest host config:

```ini
[d12]
trackDamage=no
```

- Result: feels way better.
- Interpretation: the dominant stutter/latency issue is likely in D12 damage-aware capture/copy behavior or dirty/move-rect burst handling, not raw steady-state KVMFR bandwidth.
- Current best known setting is to keep D12 damage tracking disabled and accept full-frame copies for smoother frame pacing.

Deferred next fix:

- Flatten / consolidate the deep qcow2 snapshot chain before treating storage as solved.
- User wants to discuss CPU topology first, especially whether Windows can see P-core vs E-core differences inside the VM.

Windows topology evidence from Coreinfo:

```text
Logical to Physical Processor Map:
**--------------  Physical Processor 0 (Hyperthreaded)
--**------------  Physical Processor 1 (Hyperthreaded)
----**----------  Physical Processor 2 (Hyperthreaded)
------**--------  Physical Processor 3 (Hyperthreaded)
--------**------  Physical Processor 4 (Hyperthreaded)
----------**----  Physical Processor 5 (Hyperthreaded)
------------**--  Physical Processor 6 (Hyperthreaded)
--------------**  Physical Processor 7 (Hyperthreaded)

Logical Processor to Socket Map:
****************  Socket 0

Logical Processor to NUMA Node Map:
****************  NUMA Node 0
```

Interpretation:

- Windows currently sees 16 logical CPUs as 8 homogeneous hyperthreaded cores.
- Current backing pins are `2-13,16-19`, which are actually 6 P-core SMT pairs plus 4 single-thread E-cores.
- This confirms the guest topology is misleading unless a separate CPU Set / EfficiencyClass check proves Windows has hidden hybrid metadata.
- Coreinfo output did not show P/E core awareness.

P-core-only VM topology applied:

- Refreshed `/etc/nixos/systems/nixos/vms/Windows11.xml` from `virsh -c qemu:///system dumpxml --inactive Windows11` so the saved XML matches the current persistent libvirt definition.
- Changed VM from 16 vCPUs to 12 vCPUs.
- vCPU pins are now `2-13` only.
- Removed E-core vCPU pins `16-19`.
- Changed guest CPU topology from `8 cores x 2 threads` to `6 cores x 2 threads`.
- Changed QEMU emulator pinning from `0-1,14-15` to `0-1,14-27`.
- Defined the updated XML into libvirt with `virsh -c qemu:///system define /etc/nixos/systems/nixos/vms/Windows11.xml`.
- The VM was still running when this was defined, so the new topology applies on the next VM start.

Updated Looking Glass tuning module for the new split:

- VM CPU set: `2-13`
- Host CPU set: `0,1,14-27`
- Boot managed IRQ hint becomes `isolcpus=managed_irq,2-13` after NixOS rebuild and reboot.
