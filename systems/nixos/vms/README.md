# Virtual Machine Configurations

This directory contains libvirt VM XML configurations.

## Windows11.xml

High-performance Windows 11 VM with:
- **GPU Passthrough**: RTX 3060 Ti + Audio (NVIDIA 10de:2489 + 10de:228b)
- **Looking Glass**: IVSHMEM-based low-latency display (128MB shared memory)
- **CPU Pinning**: 6 P-cores (12 threads) + 4 E-cores optimized for hybrid architecture
- **VirtIO Devices**: Disk, network, keyboard, mouse
- **USB Passthrough**: Huion Tablet (256c:006d), SpaceMouse (256f:c635)
- **VirtioFS Shared Folder**: High-performance host folder sharing (Looking Glass compatible)

### Storage Configuration

```
VM Disk:    /vm-storage/images/windows11.qcow2 (500GB, btrfs with CoW enabled)
Snapshots:  Enabled (disk-only due to GPU passthrough)
Shared Dir: ~/windows-shared → virtiofs mount 'shared' in Windows
```

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

4. **CPU Topology**: The VM exposes the full hybrid P-core/E-core architecture to Windows via host-passthrough.

### Documentation

For comprehensive documentation, see:
- `/etc/nixos/docs/windows-vm.md` - Complete setup guide and troubleshooting
- `/etc/nixos/docs/vfio-gpu-passthrough-guide.md` - GPU passthrough reference
