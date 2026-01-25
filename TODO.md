# Windows 11 GPU Passthrough VM with Looking Glass

---
## 🔄 REBUILD PLAN - 2026-01-24

### Previous Setup Issues:
- ❌ VM disk on raw partition (`/dev/nvme1n1p1`) - **snapshots don't work**
- ❌ Shared folder on NTFS partition (`/dev/nvme1n1p2`) - mounted at `/mnt/vm-shared`
- ❌ Looking Glass Host service failed - disabled SPICE display, couldn't troubleshoot

### New Setup Plan:
- ✅ VM disk as **qcow2 file** at `/var/lib/libvirt/images/windows11.qcow2` - **snapshots enabled**
- ✅ Shared folder at **`~/windows-shared`** - simple, no NTFS mount needed
- ✅ Keep SPICE display **enabled** in Windows for troubleshooting
- ✅ Use **MicroWin ISO** (Chris Titus Tech) for cleaner Windows install
- ✅ `/dev/nvme1n1p2` freed up for Linux use (can reformat as ext4/btrfs)

### Backups Created:
- VM XML: `~/windows11-vm-backup-20260124-185754.xml`
- NixOS config: `~/virtualization-opts-backup-20260124-*.nix`

### Current Status:
- ✅ NixOS config updated (btrfs VM storage configured)
- ✅ KVMFR module loaded and `/dev/kvmfr0` working with ACL permissions
- ✅ btrfs VM storage configured on `/dev/nvme1n1` with weekly scrubs
- ✅ 500GB qcow2 disk created at `/vm-storage/images/windows11.qcow2` (with btrfs checksumming)
- ✅ Windows 11 VM created and running
- ✅ Windows 11 installation in progress (minimal ISO)
- ⏳ Next: Install VirtIO drivers after Windows boots
- ⏳ Next: Configure CPU pinning for optimal performance

---

# Windows 11 GPU Passthrough VM with Looking Glass

## Looking Glass Overview

**Looking Glass** allows viewing and controlling the GPU-passthrough VM without a physical monitor attached to the RTX 3060 Ti. It uses shared memory (IVSHMEM) for ultra-low latency frame transfer.

### Architecture
```
Host (NixOS) → Looking Glass Client → /dev/kvmfr0 (IVSHMEM)
                                           ↓
Guest (Windows 11) ← Looking Glass Host ← RTX 3060 Ti
```

### Documentation
- Downloaded to: `/tmp/looking-glass-docs/docs/B7/`
- Official site: https://looking-glass.io/docs/B7/

### Key Requirements for 4K SDR (3840x2160)
- **Shared Memory Size**: 128MB (calculated per Looking Glass formula)
- **KVMFR Module**: Kernel module for DMA-accelerated frame transfer
- **IVSHMEM Device**: Added to VM XML configuration
- **Looking Glass Host**: Installed in Windows VM
- **Looking Glass Client**: Built and installed on NixOS host

### Important Findings
- RTX 3060 Ti is ideal for passthrough (NVIDIA recommended over AMD)
- Must disable memballoon device in VM (causes performance issues)
- Must use VirtIO input devices (keyboard/mouse) for proper input handling
- Reserve minimum 2 CPU cores (4 threads) for host system
- SPICE used for keyboard/mouse/clipboard sync (keep until Looking Glass working)

---

## Post-Reboot Verification (COMPLETED ✓)

1. ✓ **VFIO binding for RTX 3060 Ti** - Confirmed using vfio-pci driver
2. ✓ **IOMMU enabled** - Confirmed intel_iommu=on iommu=pt
3. ✓ **VFIO modules loaded** - vfio_pci, vfio_iommu_type1, vfio all present

## Looking Glass Setup (Host/NixOS Side)

**STATUS: NixOS config updated and rebuilt - REBOOT REQUIRED to load KVMFR module**

### Completed via NixOS configuration:
- ✓ Added `kvmfr` to `boot.kernelModules`
- ✓ Added `boot.extraModulePackages = [ kvmfr ]`
- ✓ Configured `boot.extraModprobeConfig` with `options kvmfr static_size_mb=128`
- ✓ Added udev rules for `/dev/kvmfr0` permissions (jarrett:kvm, mode 0660)
- ✓ Added `looking-glass-client` to system packages
- ✓ System rebuilt successfully

### After reboot, verify:

4. **Verify KVMFR kernel module loaded**
   ```bash
   # Check module is loaded:
   lsmod | grep kvmfr
   # Should show: kvmfr

   # Check kernel messages:
   dmesg | grep kvmfr
   # Should show: "kvmfr: creating 1 static devices"

   # Verify /dev/kvmfr0 exists with correct permissions:
   ls -l /dev/kvmfr0
   # Should show: crw-rw---- 1 jarrett kvm 242, 0 ... /dev/kvmfr0
   ```

5. **Add IVSHMEM device to VM XML configuration**
   - Edit Windows11 VM XML to add IVSHMEM device
   - For QEMU 6.2+ / libvirt 7.9+ (JSON syntax):
     ```xml
     <domain type='kvm' xmlns:qemu='http://libvirt.org/schemas/domain/qemu/1.0'>
     ...
     <qemu:commandline>
       <qemu:arg value="-device"/>
       <qemu:arg value="{'driver':'ivshmem-plain','id':'shmem0','memdev':'looking-glass'}"/>
       <qemu:arg value="-object"/>
       <qemu:arg value="{'qom-type':'memory-backend-file','id':'looking-glass','mem-path':'/dev/kvmfr0','size':134217728,'share':true}"/>
     </qemu:commandline>
     ```
     Note: size=134217728 bytes = 128MB × 1024 × 1024
   - Update AppArmor: Add `/dev/kvmfr0 rw,` to `/etc/apparmor.d/local/abstractions/libvirt-qemu`
   - Update cgroups: Add `/dev/kvmfr0` to `cgroup_device_acl` in `/etc/libvirt/qemu.conf`
   - Restart libvirtd: `sudo systemctl restart libvirtd.service`

6. **Verify VM XML has proper SPICE/input configuration**
   - Video model: `<model type='vga'/>`
   - Input devices: VirtIO mouse and keyboard
   - SPICE channel for clipboard: `<channel type="spicevmc">` with virtio target
   - Memballoon: `<memballoon model="none"/>` (CRITICAL for performance)

7. **Build/install Looking Glass client on NixOS**
   - Download from https://looking-glass.io/downloads or build from source
   - Install dependencies and build
   - Client will connect to /dev/kvmfr0 to display VM output

## Start and Configure Windows VM

8. **Start the Windows 11 VM**
   ```bash
   sudo virsh start Windows11
   # Or use virt-manager GUI
   ```

9. **Connect to VM console**
   ```bash
   virt-manager
   # Open Windows11 VM console
   ```

10. **Install Windows 11**
    - During installation, load VirtIO drivers from the virtio-win.iso
    - Install VirtIO SCSI controller drivers to see the disk
    - Complete Windows installation

11. **Install VirtIO drivers in Windows**
    - After Windows boots, install all VirtIO drivers from virtio-win.iso (D: or E: drive)
    - **EASIEST METHOD**: Run `virtio-win-guest-tools.exe` from ISO root (installs all drivers)
    - **OR MANUAL METHOD**: Device Manager → Update driver for each device:
      - Network adapter (NetKVM) - browse to `NetKVM\w11\amd64\`
      - VirtIO Serial driver (for SPICE clipboard sync)
      - VirtIO Input drivers (vioinput) - CRITICAL for Looking Glass input
      - Any other missing drivers
    - NOTE: Do NOT install Balloon driver (memballoon should be disabled)
    - Reboot after driver installation

12. **Install NVIDIA drivers**
    - Download latest RTX 3060 Ti drivers from NVIDIA
    - Install and reboot
    - Verify GPU is working in Device Manager

13. **Install Looking Glass Host in Windows VM**
    - Download `looking-glass-host-setup.exe` from https://looking-glass.io/downloads
    - Run as Administrator
    - Installer includes IVSHMEM driver (installs automatically)
    - Install with default options
    - Looking Glass Host service will start automatically
    - Verify in Device Manager: IVSHMEM device should appear
    - Note: Dummy HDMI plug may be needed on RTX 3060 Ti if Windows disables GPU output

14. **Set up shared folder in Windows**
    - Install WinFSP and virtio-win-guest-tools
    - The shared folder should appear as a virtiofs mount
    - Map to drive letter if desired

15. **Test Looking Glass connection**
    - On NixOS host, run: `looking-glass-client`
    - Should display Windows VM screen with low latency
    - Test mouse/keyboard input
    - Test clipboard sync (copy/paste between host and guest)
    - Key bindings: Scroll Lock + Q to quit, Scroll Lock to release cursor

16. **Test USB passthrough**
    - Plug in Huion tablet - should automatically attach to VM
    - Plug in SpaceMouse - should automatically attach to VM
    - Install respective drivers if needed
    - Verify devices work through Looking Glass display

## Optimization (Optional)

17. **CPU pinning for better performance**
    - Intel i7-14700KF: 8 P-cores (CPUs 0-15, HT) + 12 E-cores (CPUs 16-27, no HT)
    - **Planned VM Allocation (16 vCPUs total):**
      - 6 P-cores: CPUs 2-13 (cores 1-6, with hyperthreading = 12 threads)
      - 4 E-cores: CPUs 16-19 (cores 8-11, no HT = 4 threads)
    - **Reserved for Host (12 CPUs):**
      - 2 P-cores: CPUs 0-1, 14-15 (cores 0, 7)
      - 8 E-cores: CPUs 20-27 (cores 12-19)
    - VM gets full CPU topology info via host-passthrough (sees P/E core architecture)
    - Windows Thread Director will correctly schedule on hybrid architecture

18. **Hugepages configuration**
    - Configure hugepages for better memory performance
    - Beneficial for Looking Glass frame transfer

19. **Remove SPICE display (once Looking Glass confirmed working)**
    - Keep SPICE for now as fallback
    - Later: Edit VM XML to remove `<graphics type='spice'>`
    - Keep VirtIO input devices (required for Looking Glass)
    - This frees up resources but removes fallback display option

## Notes

### VM Configuration

**IMPORTANT DISK CONFIGURATION (CURRENT SETUP):**
- **VM Disk**: `/vm-storage/images/windows11.qcow2` (qcow2 file on btrfs, snapshots enabled)
  - **CRITICAL**: Create with `chattr +C` AFTER file creation to disable CoW on the file only
  - Command sequence:
    ```bash
    qemu-img create -f qcow2 /vm-storage/images/windows11.qcow2 200G
    chattr +C /vm-storage/images/windows11.qcow2
    ```
  - Why: Disables CoW on qcow2 (prevents fragmentation) while preserving btrfs checksums
  - Size: ~200GB allocated, can grow as needed
  - Stored on: `/dev/nvme1n1` (WD_BLACK SN7100 2TB) - dedicated btrfs filesystem
  - Weekly btrfs scrub validates integrity and detects bit rot
- **Shared Folder**: `~/windows-shared` (regular directory, shared via virtiofs)
  - Mount point in VM: "shared"
  - Simple and accessible from home directory

**OLD DISK CONFIGURATION (DEPRECATED):**
- ~~**VM Disk**: `/dev/nvme1n1p1` (raw partition - no snapshots)~~
- ~~**Shared Folder**: `/dev/nvme1n1p2` (NTFS - removed)~~
- ~~**VM Disk**: `/var/lib/libvirt/images/windows11.qcow2` on nvme2n1~~

**Available Disks:**
- nvme0n1: WD_BLACK SN7100 2TB (encrypted system disk)
- nvme1n1: WD_BLACK SN7100 2TB (VM disk) ← **USE THIS ONE**
- nvme2n1: SOLIDIGM 2TB (NixOS system disk) ← **DO NOT TOUCH**
- sda: Samsung SSD 870 EVO 500GB

**Other Configuration:**
- Windows ISO: **MicroWin ISO** (from Chris Titus Tech) - download in progress
- VirtIO Drivers: `~/Downloads/virtio-win.iso`
- GPU: RTX 3060 Ti (10de:2489) + Audio (10de:228b)
- USB Devices: Huion Tablet (256c:006d), SpaceMouse (256f:c635)
- Shared Folder: `~/windows-shared` (virtiofs mount point: "shared")

### Looking Glass Configuration
- Resolution: 4K SDR (3840x2160)
- Shared Memory Required: 128MB
- KVMFR Device: `/dev/kvmfr0`
- Memory calculation formula: `WIDTH × HEIGHT × 4 (BPP) × 2 ÷ 1024 ÷ 1024 + 10`, round up to power of 2
  - 3840 × 2160 × 4 × 2 = 66,355,200 bytes = 63.28 MB + 10 MB = 73.28 MB → rounds to 128 MB
- IVSHMEM size in bytes: 134217728 (128 × 1024 × 1024)
- Documentation: `/tmp/looking-glass-docs/docs/B7/`

### Critical VM XML Requirements for Looking Glass
- Memballoon: MUST be `<memballoon model="none"/>` (not virtio)
- CPU: Reserve minimum 2 cores (4 threads) for host
- Input: VirtIO keyboard and mouse (NOT tablet device)
- Video: VGA model for SPICE fallback
- SPICE: Keep enabled until Looking Glass confirmed working

## VM Configuration Files

- Main config: `/etc/nixos/systems/nixos/virtualization-opts.nix`
- VM XML: Managed by libvirt, can view with `sudo virsh dumpxml Windows11`
- KVMFR config: `/etc/modprobe.d/kvmfr.conf`, `/etc/modules-load.d/kvmfr.conf`
- Udev rules: `/etc/udev/rules.d/99-kvmfr.rules`
