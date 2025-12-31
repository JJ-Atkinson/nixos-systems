# Framework Laptop 13 (AMD AI 300) Setup Notes

## Hardware
- Framework Laptop 13 with AMD Ryzen AI 7 350
- NVMe SSD with LUKS encryption + Btrfs subvolumes

## Initial Installation

### 1. Partition and Format with Disko

From the NixOS installer USB:

```bash
# Verify device path matches your NVMe drive in disk-config.nix
lsblk

# Run disko to partition, encrypt, format, and mount
cd /path/to/nixos-config
sudo nix --experimental-features "nix-command flakes" run github:nix-community/disko/latest -- --mode destroy,format,mount ./disk-config.nix
```

**What this does:**
- Creates GPT partition table
- 512M EFI boot partition (vfat)
- Remainder encrypted with LUKS (interactive password prompt)
- Btrfs filesystem with subvolumes: `@`, `@home`, `@nix`, `@log`, `@swap`
- Mounts everything under `/mnt`

### 2. Install NixOS

```bash
# Basic install
sudo nixos-install --flake /path/to/nixos-config#nixos-framework

# Optional: Use desktop as binary cache for faster install
# (requires nix-serve running on desktop - see main README)
sudo nixos-install --flake /path/to/nixos-config#nixos-framework \
  --option substituters "http://192.168.50.171 https://cache.nixos.org" \
```

### 3. Post-Installation: Add YubiKey FIDO2 LUKS Unlock

After first boot into the installed system:

```bash
# Enroll YubiKey for LUKS unlock (you'll need to enter your LUKS password)
sudo systemd-cryptenroll /dev/nvme0n1p2 --fido2-device=auto
```

**What this does:**
- Adds YubiKey FIDO2 as an additional unlock method for the encrypted partition
- You can now unlock with either password OR YubiKey
- On boot, touch YubiKey when prompted instead of typing password

### 4. Update Firmware with fwupd

The `nixos-hardware` Framework AMD AI 300 module enables `fwupd` by default for firmware updates.

**Update BIOS, Embedded Controller, and other firmware:**

```bash
# Refresh the firmware database
sudo fwupdmgr refresh

# Check for available updates
sudo fwupdmgr get-updates

# Apply all available firmware updates
sudo fwupdmgr update
```

**Important Notes:**
- Firmware updates are sourced from LVFS (Linux Vendor Firmware Service)
- BIOS updates require a reboot to apply
- Some updates may require AC power connected
- Framework regularly releases firmware updates for AMD AI 300 series
- Check [Framework LVFS updates](https://fwupd.org/lvfs/devices/) for latest available firmware

**Verify current firmware versions:**
```bash
sudo fwupdmgr get-devices
```
