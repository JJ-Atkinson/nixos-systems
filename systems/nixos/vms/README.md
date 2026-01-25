# Virtual Machine Configurations

This directory contains libvirt VM XML configurations.

## Windows11.xml

Windows 11 VM with:
- GPU Passthrough (RTX 3060 Ti + Audio)
- Looking Glass (IVSHMEM for low-latency display)
- CPU Pinning (6 P-cores + 4 E-cores)
- VirtIO devices (disk, network, input)
- USB Passthrough (Huion Tablet, SpaceMouse)
- VirtioFS shared folder (currently broken, to be fixed)

### Restoring Configuration

```bash
sudo virsh define /etc/nixos/systems/nixos/vms/Windows11.xml
```

### Updating This File

```bash
sudo virsh dumpxml Windows11 > /etc/nixos/systems/nixos/vms/Windows11.xml
```
