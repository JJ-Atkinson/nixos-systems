{ nixpkgs, lib, config, pkgs, ... }:
{
  # Enable libvirt and virt-manager
  programs.virt-manager.enable = true;
  virtualisation.libvirtd = {
    enable = true;
    qemu = {
      swtpm.enable = true;  # Enable TPM 2.0 emulation for Windows 11
      vhostUserPackages = [ pkgs.virtiofsd ];  # Make virtiofsd available to QEMU
      verbatimConfig = ''
        cgroup_device_acl = [
          "/dev/null", "/dev/full", "/dev/zero",
          "/dev/random", "/dev/urandom",
          "/dev/ptmx", "/dev/kvm",
          "/dev/kvmfr0"
        ]
      '';
    };
  };

  # Configure virtiofsd for shared folders
  systemd.services.libvirtd.path = [ pkgs.virtiofsd ];
  virtualisation.spiceUSBRedirection.enable = true;

  users.groups.libvirtd.members = [ "jarrett" ];

  # VFIO GPU Passthrough Configuration
  boot.kernelParams = [ "intel_iommu=on" "iommu=pt" ];
  boot.kernelModules = [ "kvm-intel" "vfio_virqfd" "vfio_pci" "vfio_iommu_type1" "vfio" "kvmfr" ];
  boot.blacklistedKernelModules = [ "nouveau" "nvidia" "nvidiafb" ];

  # Bind RTX 3060 Ti (and its audio controller) to VFIO
  # GPU: 10de:2489, Audio: 10de:228b
  boot.extraModprobeConfig = ''
    options vfio-pci ids=10de:2489,10de:228b
    # Looking Glass KVMFR module - 128MB for 4K SDR (3840x2160)
    options kvmfr static_size_mb=128
  '';

  # Add KVMFR kernel module for Looking Glass
  boot.extraModulePackages = with config.boot.kernelPackages; [ kvmfr ];

  # Udev rules for Looking Glass KVMFR device permissions
  services.udev.extraRules = ''
    SUBSYSTEM=="kvmfr", KERNEL=="kvmfr[0-9]*", GROUP="kvm", MODE="0660", TAG+="uaccess"
  '';

  # VM Storage and Shared Folder
  # VM images stored at: /vm-storage/images (btrfs with CoW disabled per-file)
  # Shared folder at: ~/windows-shared (regular directory, simple and accessible)

  environment.systemPackages = with pkgs; [
    virtiofsd
    swtpm  # Software TPM emulator for Windows 11
    looking-glass-client  # Looking Glass B7 client for low-latency VM display

    # Custom script for Windows VM snapshots
    (pkgs.writeShellScriptBin "snapshot-win-vm" ''
      if [ -z "$1" ]; then
        echo "Usage: snapshot-win-vm 'description'"
        echo "Example: snapshot-win-vm 'after driver installation'"
        exit 1
      fi

      TIMESTAMP=$(date +%Y%m%d-%H%M%S)
      SNAPSHOT_NAME="snapshot-$TIMESTAMP"
      DESCRIPTION="$1"

      echo "Creating snapshot: $SNAPSHOT_NAME"
      echo "Description: $DESCRIPTION"

      sudo virsh snapshot-create-as Windows11 "$SNAPSHOT_NAME" "$DESCRIPTION" --disk-only --atomic

      if [ $? -eq 0 ]; then
        echo "✓ Snapshot created successfully!"
        echo ""
        echo "To list all snapshots:"
        echo "  sudo virsh snapshot-list Windows11"
        echo ""
        echo "To revert to this snapshot:"
        echo "  sudo virsh shutdown Windows11"
        echo "  sudo virsh snapshot-revert Windows11 $SNAPSHOT_NAME"
        echo "  sudo virsh start Windows11"
      else
        echo "✗ Snapshot creation failed!"
        exit 1
      fi
    '')
  ];
}
