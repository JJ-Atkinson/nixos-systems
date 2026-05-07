# Virtual Machine Configurations

This directory contains libvirt VM XML configurations.

## Windows11.xml

High-performance Windows 11 VM with:
- **GPU Passthrough**: RTX 3060 Ti + Audio (NVIDIA 10de:2489 + 10de:228b)
- **Looking Glass**: IVSHMEM-based low-latency display (128MB shared memory)
- **CPU Pinning**: 6 P-cores (12 threads), avoiding mixed P/E topology in Windows
- **VirtIO Devices**: Disk, network, keyboard, mouse
- **USB Passthrough**: Huion Tablet (256c:006d), SpaceMouse (256f:c635)
- **VirtioFS Shared Folder**: High-performance host folder sharing (Looking Glass compatible)

### Storage Configuration

```
VM Disk:    /vm-storage/images/windows11.flattened-20260506.qcow2 (500GB qcow2)
Driver:     cache='none' io='native' discard='unmap'
Snapshots:  Old local qcow2 chain deleted after flattening; restore from external backup if needed
Shared Dir: ~/windows-shared → virtiofs mount 'shared' in Windows
```

The active disk is a flattened qcow2 with no backing file. This replaced the old deep external snapshot chain to reduce storage latency variance.

### Looking Glass Notes

Looking Glass version is `B7` on both client and guest host.

The Windows host uses D12 capture. Current best-known guest host config:

```ini
[d12]
trackDamage=no
```

Place that in the Windows VM at:

```text
C:\Program Files\Looking Glass (host)\looking-glass-host.ini
```

Then restart the Looking Glass host service in Windows.

Why this is set:
- With `trackDamage=yes`, idle-to-large-damage transitions caused bad latency for about a dozen frames.
- With `trackDamage=no`, Looking Glass does predictable full-frame copies and feels much smoother.
- This trades bandwidth for frame pacing stability.

At the current 4K BGRA format, one full frame is:

```text
3840 * 2160 * 4 bytes = 33,177,600 bytes = 31.64 MiB
```

Approximate full-frame copy bandwidth:

| FPS | Bandwidth |
|---:|---:|
| 30 | 949 MiB/s |
| 60 | 1.85 GiB/s |
| 75 | 2.32 GiB/s |
| 120 | 3.71 GiB/s |
| 144 | 4.45 GiB/s |

The Linux client has a local B7 patch for the performance metrics overlay crash:
- Patch: `/etc/nixos/patches/looking-glass-b7-graph-imgui-id.patch`
- Overlay wiring: `/etc/nixos/modules/looking-glass-stutter-tuning.nix`
- Cause: B7 passed a raw graph pointer as an ImGui plot label, which could trip an empty-ID assertion.

Optional host-side helpers from `/etc/nixos/modules/looking-glass-stutter-tuning.nix`:
- `looking-glass-client-tuned`: runs the client on host CPUs outside the VM CPU set.
- `looking-glass-irq-affinity status|apply`: keeps selected host IRQs off VM CPUs where the kernel allows it.

### Quick Reference

**Start VM**:
```bash
sudo virsh start Windows11
```

**Stop VM**:
```bash
sudo virsh shutdown Windows11
```

**Create Snapshot**:
```bash
snapshot-win-vm "description of changes"
```

**List Snapshots**:
```bash
sudo virsh snapshot-list Windows11
```

**Revert to Snapshot**:
```bash
sudo virsh shutdown Windows11
sudo virsh snapshot-revert Windows11 <snapshot-name>
sudo virsh start Windows11
```

**Connect with Looking Glass**:
```bash
looking-glass-client
# Scroll Lock to release mouse
# Scroll Lock + Q to quit
```

**Connect with CPU-pinned Looking Glass client**:
```bash
looking-glass-client-tuned
```

### Restoring VM Definition

After NixOS rebuild or if VM definition is lost:

```bash
sudo virsh define /etc/nixos/systems/nixos/vms/Windows11.xml
```

### Updating This File

After making changes to the VM in virt-manager or via `virsh edit`:

```bash
sudo virsh dumpxml Windows11 > /etc/nixos/systems/nixos/vms/Windows11.xml
git add /etc/nixos/systems/nixos/vms/Windows11.xml
git commit -m "Update Windows11 VM configuration"
```

### Important Notes

1. **VirtioFS Compatibility**: This VM uses a patched virtiofsd from the ELginas fork to enable VirtioFS + Looking Glass compatibility. See `/etc/nixos/modules/virtiofsd-looking-glass.nix` for details.

2. **Memballoon**: The VM has `<memballoon model="none"/>` for performance. Do not change this.

3. **SPICE Display**: Keep SPICE enabled as fallback. Looking Glass is primary display method.

4. **CPU Topology**: The VM exposes 6 hyperthreaded P-cores to Windows. E-cores remain available to the host for Looking Glass, IRQs, and background work.

5. **Looking Glass Damage Tracking**: Keep `[d12] trackDamage=no` unless deliberately retesting. It currently gives much smoother latency than D12 damage-aware copies.

### Documentation

For comprehensive documentation, see:
- `/etc/nixos/docs/windows-vm.md` - Complete setup guide and troubleshooting
- `/etc/nixos/docs/vfio-gpu-passthrough-guide.md` - GPU passthrough reference
