# Windows 11 GPU Passthrough VM with Looking Glass

This document describes the complete Windows 11 VM setup with GPU passthrough, Looking Glass, and VirtioFS file sharing.

## Table of Contents
1. [Overview](#overview)
2. [Hardware Configuration](#hardware-configuration)
3. [Storage Architecture](#storage-architecture)
4. [Looking Glass Setup](#looking-glass-setup)
5. [VirtioFS Shared Folder](#virtiofs-shared-folder)
6. [CPU Pinning](#cpu-pinning)
7. [VM Management](#vm-management)
8. [Troubleshooting](#troubleshooting)

---

## Overview

### What We've Built

A high-performance Windows 11 VM with:
- **GPU Passthrough**: RTX 3060 Ti dedicated to Windows
- **Looking Glass**: Low-latency remote display via shared memory (no monitor needed)
- **VirtioFS**: High-performance host folder sharing
- **CPU Pinning**: Optimized hybrid CPU core allocation
- **Snapshots**: qcow2-based disk with snapshot support
- **USB Passthrough**: Huion tablet and SpaceMouse automatically attached

### Why This Setup?

This configuration provides near-native Windows performance while maintaining:
- Full NixOS integration (declarative configuration)
- Easy snapshots and rollbacks
- Seamless file sharing with host
- No physical monitor required for the GPU
- Optimal CPU scheduling on hybrid architecture

---

## Hardware Configuration

### System Specifications
- **CPU**: Intel i7-14700KF (8 P-cores + 12 E-cores)
- **GPU (Passthrough)**: NVIDIA RTX 3060 Ti (10de:2489) + Audio (10de:228b)
- **Storage**: WD_BLACK SN7100 2TB NVMe (`/dev/nvme1n1`) dedicated to VM

### USB Devices (Auto-passthrough)
- **Huion Tablet**: USB 256c:006d
- **3Dconnexion SpaceMouse**: USB 256f:c635

### VFIO Configuration

GPU isolation is configured in `/etc/nixos/systems/nixos/hw-opts.nix`:

```nix
boot.kernelParams = [
  "intel_iommu=on"
  "iommu=pt"
  "vfio-pci.ids=10de:2489,10de:228b"  # RTX 3060 Ti + Audio
];
```

Verification:
```bash
# Check VFIO binding
lspci -nnk -d 10de:2489
# Should show: Kernel driver in use: vfio-pci

# Verify IOMMU groups
find /sys/kernel/iommu_groups -type l | grep 10de
```

---

## Storage Architecture

### Current Setup

```
/dev/nvme1n1 (WD_BLACK SN7100 2TB)
├── btrfs filesystem (entire disk)
    ├── @vm-images subvolume → /vm-storage/images
    │   └── windows11.qcow2 (500GB, sparse allocation)
    └── @vm-shared subvolume → /vm-storage/shared (currently unused)
```

### Storage Configuration

File: `/etc/nixos/systems/nixos/fs-opts.nix`

```nix
fileSystems."/vm-storage/images" = {
  device = "/dev/disk/by-uuid/90666d5e-da4d-4a0a-8016-0a949036cec1";
  fsType = "btrfs";
  options = [ "subvol=@vm-images" "ssd" "noatime" ];
};
```

### Btrfs Integrity Checking

Weekly scrubs configured in `/etc/nixos/modules/btrfs-scrub.nix`:

```nix
services.btrfs.autoScrub = {
  enable = true;
  interval = "weekly";
  fileSystems = [
    "/"
    "/vm-storage/images"  # Validates qcow2 integrity
  ];
};
```

**Important**: We kept CoW **enabled** (did not use `chattr +C`) to preserve btrfs checksumming. This provides:
- Automatic bit-rot detection
- Data integrity verification
- Snapshot consistency

Trade-off: Slight performance hit for data safety.

### VM Disk Details

```bash
# Disk creation
qemu-img create -f qcow2 /vm-storage/images/windows11.qcow2 500G

# Check disk info
qemu-img info /vm-storage/images/windows11.qcow2
```

**Snapshot chain** (managed via `snapshot-win-vm` command):
```
windows11.qcow2
  └── windows11.fresh-install
      └── windows11.snapshot-20260124-210227
          └── ... (additional snapshots)
```

---

## Looking Glass Setup

### Architecture

```
┌─────────────────────────────────────────────────────┐
│ Host (NixOS)                                        │
│                                                     │
│  looking-glass-client ──→ /dev/kvmfr0 (128MB)      │
└─────────────────────────┬───────────────────────────┘
                          │ IVSHMEM shared memory
┌─────────────────────────┴───────────────────────────┐
│ Guest (Windows 11)                                  │
│                                                     │
│  Looking Glass Host ←── RTX 3060 Ti framebuffer    │
└─────────────────────────────────────────────────────┘
```

### KVMFR Module Configuration

The KVMFR (Kernel Virtual Machine FrameRelay) module provides DMA-accelerated shared memory for Looking Glass.

**NixOS Configuration** (`/etc/nixos/systems/nixos/virtualization-opts.nix`):

```nix
# Load KVMFR module at boot
boot.kernelModules = [ "kvmfr" ];
boot.extraModulePackages = with config.boot.kernelPackages; [ kvmfr ];

# Configure 128MB shared memory for 4K resolution
boot.extraModprobeConfig = ''
  options kvmfr static_size_mb=128
'';

# Set permissions for user access
services.udev.extraRules = ''
  SUBSYSTEM=="kvmfr", OWNER="jarrett", GROUP="kvm", MODE="0660"
'';
```

**Memory Size Calculation**:
```
Formula: WIDTH × HEIGHT × 4 (BPP) × 2 ÷ 1024 ÷ 1024 + 10
For 4K: 3840 × 2160 × 4 × 2 = 66,355,200 bytes = 63.28 MB + 10 MB overhead
Result: 73.28 MB → round up to nearest power of 2 = 128 MB
```

### IVSHMEM Device in VM

**VM XML Configuration** (`/etc/nixos/systems/nixos/vms/Windows11.xml`):

```xml
<domain type='kvm' xmlns:qemu='http://libvirt.org/schemas/domain/qemu/1.0'>
  ...
  <qemu:commandline>
    <qemu:arg value='-device'/>
    <qemu:arg value="{'driver':'ivshmem-plain','id':'shmem0','memdev':'looking-glass'}"/>
    <qemu:arg value='-object'/>
    <qemu:arg value="{'qom-type':'memory-backend-file','id':'looking-glass','mem-path':'/dev/kvmfr0','size':134217728,'share':true}"/>
  </qemu:commandline>
</domain>
```

**Note**: size=134217728 bytes = 128MB × 1024 × 1024

### Verification

```bash
# Check KVMFR module
lsmod | grep kvmfr
dmesg | grep kvmfr

# Verify device exists with correct permissions
ls -l /dev/kvmfr0
# Expected: crw-rw---- 1 jarrett kvm 242, 0 ... /dev/kvmfr0

# Or check ACL permissions
getfacl /dev/kvmfr0
# Expected: user:jarrett:rw-
```

### Windows Guest Setup

1. **Install Looking Glass Host** (in Windows VM):
   ```
   Download: https://looking-glass.io/downloads
   Run: looking-glass-host-setup.exe as Administrator
   ```

2. **Verify IVSHMEM driver**: Check Device Manager for IVSHMEM device

3. **Install IddSampleDriver** (virtual display):
   - Prevents Windows from disabling GPU when no physical monitor attached
   - Allows Looking Glass to work even if Looking Glass crashes

### Linux Host Usage

```bash
# Start Looking Glass client
looking-glass-client

# Key bindings
Scroll Lock        # Release/capture mouse
Scroll Lock + Q    # Quit client
Scroll Lock + F    # Toggle fullscreen
```

---

## VirtioFS Shared Folder

### The Problem: Looking Glass + VirtioFS Incompatibility

**Original Issue**: Standard virtiofsd (using vm-memory 0.16.x) crashes when used with Looking Glass IVSHMEM:
```
vhost_set_mem_table failed: Input/output error (5)
Error starting vhost: 5
```

**Root Cause**: The vm-memory library's file-offset validation incorrectly rejected `/dev/kvmfr0` (IVSHMEM device), preventing vhost-user memory mapping.

### The Solution: ELginas Fork

We use a patched virtiofsd from the ELginas fork which includes vm-memory 0.17.x with the fix.

**Implementation** (`/etc/nixos/modules/virtiofsd-looking-glass.nix`):

```nix
nixpkgs.overlays = [
  (final: prev: {
    virtiofsd = prev.rustPlatform.buildRustPackage rec {
      pname = "virtiofsd";
      version = "1.13.2-looking-glass";

      src = final.fetchFromGitHub {
        owner = "ELginas";
        repo = "virtiofsd";
        rev = "main";
        hash = "sha256-3p9WoUInWh+fmUkiMCjl2Tygx2/reUyKX+3xvMsW26w=";
      };

      cargoHash = "sha256-rKlm8TpCKc+Nzb9+H0FPs5GSNNjWs5/xNpSd0ZZuQt0=";
      # ... rest of package definition
    };
  })
];
```

**References**:
- Bug fix: https://github.com/rust-vmm/vm-memory/pull/320
- ELginas fork: https://github.com/ELginas/virtiofsd
- Issue: https://gitlab.com/virtio-fs/virtiofsd/-/issues/96

### Shared Folder Configuration

**Host Side**: Folder at `~/windows-shared` (regular directory)

**VM XML Configuration**:
```xml
<filesystem type='mount' accessmode='passthrough'>
  <driver type='virtiofs'/>
  <binary path='/nix/store/vw6vbapxh9dwaw8mhs3pyzlbr7bks6kk-virtiofsd-1.13.2-looking-glass/bin/virtiofsd'/>
  <source dir='/home/jarrett/windows-shared'/>
  <target dir='shared'/>
  <address type='pci' domain='0x0000' bus='0x02' slot='0x00' function='0x0'/>
</filesystem>
```

**Note**: The binary path is currently hardcoded to a specific nix store path. For better resilience to system rebuilds, this should be changed to `/run/current-system/sw/bin/virtiofsd`, but requires VM restart to test.

**Windows Guest Setup**:

1. **Install WinFSP and VirtIO drivers**:
   - Run `virtio-win-guest-tools.exe` from virtio-win ISO
   - Includes VirtioFS driver

2. **Mount the share**:
   - Open "Map Network Drive"
   - Enter: `\\\\127.0.0.1\shared`
   - Or mount via command line: `net use Z: \\\\127.0.0.1\shared`

### Verification

```bash
# After VM starts, check virtiofsd is running
pgrep -a virtiofsd

# Check version (should show 1.13.2-dev from ELginas fork)
virtiofsd --version

# View virtiofsd logs
journalctl -u libvirtd | grep virtiofsd
```

---

## CPU Pinning

### CPU Architecture

**Intel i7-14700KF**:
- 8 P-cores (Performance): CPUs 0-15 (with HyperThreading)
- 12 E-cores (Efficiency): CPUs 16-27 (no HyperThreading)

### VM Allocation (16 vCPUs)

```
┌─────────────────────────────────────────────┐
│ VM: 6 P-cores (12 threads) + 4 E-cores     │
├─────────────────────────────────────────────┤
│ P-cores 1-6: CPUs 2-13                      │
│ E-cores 8-11: CPUs 16-19                    │
└─────────────────────────────────────────────┘

┌─────────────────────────────────────────────┐
│ Host: 2 P-cores (4 threads) + 8 E-cores    │
├─────────────────────────────────────────────┤
│ P-cores 0,7: CPUs 0-1, 14-15                │
│ E-cores 12-19: CPUs 20-27                   │
│ Emulator threads: CPUs 0-1, 14-15           │
└─────────────────────────────────────────────┘
```

### VM XML Configuration

```xml
<vcpu placement='static'>16</vcpu>
<cputune>
  <!-- Pin 6 P-cores (cores 1-6): vCPU 0-11 to host CPUs 2-13 -->
  <vcpupin vcpu='0' cpuset='2'/>
  <vcpupin vcpu='1' cpuset='3'/>
  <vcpupin vcpu='2' cpuset='4'/>
  <vcpupin vcpu='3' cpuset='5'/>
  <vcpupin vcpu='4' cpuset='6'/>
  <vcpupin vcpu='5' cpuset='7'/>
  <vcpupin vcpu='6' cpuset='8'/>
  <vcpupin vcpu='7' cpuset='9'/>
  <vcpupin vcpu='8' cpuset='10'/>
  <vcpupin vcpu='9' cpuset='11'/>
  <vcpupin vcpu='10' cpuset='12'/>
  <vcpupin vcpu='11' cpuset='13'/>

  <!-- Pin 4 E-cores (cores 8-11): vCPU 12-15 to host CPUs 16-19 -->
  <vcpupin vcpu='12' cpuset='16'/>
  <vcpupin vcpu='13' cpuset='17'/>
  <vcpupin vcpu='14' cpuset='18'/>
  <vcpupin vcpu='15' cpuset='19'/>

  <!-- Pin emulator threads to reserved host P-cores -->
  <emulatorpin cpuset='0-1,14-15'/>
</cputune>

<cpu mode='host-passthrough' check='none' migratable='off'>
  <topology sockets='1' dies='1' clusters='1' cores='8' threads='2'/>
  <cache mode='passthrough'/>
  <feature policy='require' name='topoext'/>
</cpu>
```

### Benefits

- **VM sees full hybrid architecture**: Windows Thread Director correctly schedules workloads
- **Dedicated cores**: No CPU contention between host and guest
- **Host responsiveness**: Reserved cores ensure smooth host operation
- **Optimal performance**: P-cores for demanding tasks, E-cores for background work

---

## VM Management

### Snapshot Management

Custom command defined in `/etc/nixos/systems/nixos/virtualization-opts.nix`:

```bash
# Create snapshot
snapshot-win-vm "description of changes"

# List snapshots
sudo virsh snapshot-list Windows11

# Revert to snapshot
sudo virsh shutdown Windows11
sudo virsh snapshot-revert Windows11 snapshot-YYYYMMDD-HHMMSS
sudo virsh start Windows11
```

**Important**: Snapshots are **disk-only** due to GPU passthrough and IVSHMEM limitations. Memory state is not saved.

### VM Control

```bash
# Start VM
sudo virsh start Windows11

# Stop VM gracefully
sudo virsh shutdown Windows11

# Force stop
sudo virsh destroy Windows11

# VM status
sudo virsh list --all

# View VM XML
sudo virsh dumpxml Windows11

# Edit VM (temporary)
sudo virsh edit Windows11

# Update VM XML permanently
sudo virsh dumpxml Windows11 > /etc/nixos/systems/nixos/vms/Windows11.xml
```

### Permanent VM Configuration

The VM XML is stored at `/etc/nixos/systems/nixos/vms/Windows11.xml` and tracked in git.

**To restore VM definition after system rebuild**:
```bash
sudo virsh define /etc/nixos/systems/nixos/vms/Windows11.xml
```

---

## Troubleshooting

### KVMFR Issues

**Device not appearing**:
```bash
# Check module loaded
lsmod | grep kvmfr

# Check kernel messages
dmesg | grep kvmfr

# Reload module
sudo modprobe -r kvmfr
sudo modprobe kvmfr static_size_mb=128
```

**Permission denied**:
```bash
# Check permissions
ls -l /dev/kvmfr0
getfacl /dev/kvmfr0

# Should show user:jarrett:rw- in ACL
# If not, reload udev rules:
sudo udevadm control --reload-rules
sudo udevadm trigger
```

### VirtioFS Issues

**Shared folder not appearing in Windows**:

1. Check virtiofsd is running:
   ```bash
   pgrep -a virtiofsd
   ```

2. Verify virtiofsd version (should be 1.13.2-dev):
   ```bash
   virtiofsd --version
   ```

3. Check libvirtd logs:
   ```bash
   journalctl -u libvirtd -n 100 | grep virtiofs
   ```

4. In Windows, check VirtioFS driver is installed:
   - Device Manager → System devices → VirtIO FS Device

**virtiofsd crashes with vhost error**:

This indicates the old virtiofsd is still running. Solution:
```bash
# Restart libvirtd to pick up new virtiofsd
sudo systemctl restart libvirtd

# Restart VM
sudo virsh shutdown Windows11
sudo virsh start Windows11
```

### Looking Glass Issues

**Black screen in client**:
- Check Looking Glass Host service running in Windows
- Verify IVSHMEM device in Windows Device Manager
- Check `/dev/kvmfr0` permissions

**Mouse not working**:
- Press Scroll Lock to capture/release mouse
- Verify VirtIO input drivers installed in Windows
- Check VM XML has VirtIO mouse and keyboard (not tablet)

**Performance issues**:
- Verify memballoon is disabled: `<memballoon model="none"/>`
- Check CPU pinning is active
- Monitor CPU usage on host and guest

### GPU Passthrough Issues

**GPU not detected in Windows**:
```bash
# Check VFIO binding
lspci -nnk -d 10de:2489

# Should show vfio-pci driver
# If not, check boot parameters
cat /proc/cmdline | grep vfio-pci.ids
```

**Code 43 error in Windows Device Manager**:
- Verify Hyper-V enlightenments in VM XML
- Check `<kvm><hidden state='on'/></kvm>`
- Ensure `vendor_id` is set: `<vendor_id state='on' value='AuthenticAMD'/>`

---

## Configuration Files Reference

| File | Purpose |
|------|---------|
| `/etc/nixos/modules/virtiofsd-looking-glass.nix` | VirtioFS + Looking Glass compatibility fix |
| `/etc/nixos/systems/nixos/virtualization-opts.nix` | Main libvirt and KVMFR configuration |
| `/etc/nixos/systems/nixos/hw-opts.nix` | VFIO GPU binding configuration |
| `/etc/nixos/systems/nixos/fs-opts.nix` | Btrfs VM storage mounts |
| `/etc/nixos/modules/btrfs-scrub.nix` | Weekly integrity checks |
| `/etc/nixos/systems/nixos/vms/Windows11.xml` | VM hardware configuration |
| `/etc/nixos/systems/nixos/vms/README.md` | Quick reference for VM management |

---

## Additional Resources

- **Looking Glass Documentation**: https://looking-glass.io/docs/B7/
- **VirtioFS Documentation**: https://libvirt.org/kbase/virtiofs.html
- **VFIO Guide**: https://wiki.archlinux.org/title/PCI_passthrough_via_OVMF
- **CPU Pinning**: https://www.redhat.com/en/blog/cpu-pinning-and-numa-policies-red-hat-openstack-platform
- **Btrfs Best Practices**: https://btrfs.readthedocs.io/

---

## Changelog

### 2026-01-27
- **Fixed**: VirtioFS now working with Looking Glass using ELginas fork
- **Issue Found**: System had two separate Windows11 VM definitions (user and system session)
- **Resolution**: Removed user session VM, system VM (accessed with `sudo virsh`) is the active one
- **Known Issue**: VM XML has hardcoded virtiofsd path `/nix/store/vw6vbapxh9dwaw8mhs3pyzlbr7bks6kk-virtiofsd-1.13.2-looking-glass/bin/virtiofsd`
  - **TODO**: Change to `/run/current-system/sw/bin/virtiofsd` for resilience to system rebuilds
  - Requires VM restart to test, deferred for now

### 2026-01-25
- **Added**: VirtioFS + Looking Glass compatibility fix using ELginas fork
- **Fixed**: `vhost_set_mem_table` error preventing virtiofs from working with IVSHMEM
- **Updated**: Documentation for virtiofsd-looking-glass.nix module

### 2026-01-24
- **Initial Setup**: Windows 11 VM with GPU passthrough
- **Added**: Looking Glass KVMFR configuration
- **Added**: CPU pinning for hybrid architecture
- **Added**: Btrfs VM storage with weekly scrubs
- **Added**: Custom snapshot command
- **Configured**: USB passthrough for Huion tablet and SpaceMouse
