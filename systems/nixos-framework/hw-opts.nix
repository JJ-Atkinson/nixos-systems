{lib, config, pkgs, ...} : {
  # nixos-hardware module (framework-amd-ai-300-series) handles most Framework-specific configuration
  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";

  # Enable WiFi firmware
  hardware.enableRedistributableFirmware = true;

  # Use the systemd-boot EFI boot loader.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # Use latest kernel.
  boot.kernelPackages = pkgs.linuxPackages_latest;

  # Disable AMD microcode checksum verification (required for ucodenix)
  # boot.kernelParams = [ "microcode.amd_sha_check=off" ];

  # Initrd settings
  boot.initrd.systemd.enable = true;
  boot.initrd.availableKernelModules = [ "xhci_pci" "ahci" "nvme" "usbhid" "uas" "sd_mod" ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ "kvm-amd" ]; # AMD instead of Intel
  boot.extraModulePackages = [ ];

  # Swap file configuration (disko handles the mount point)
  swapDevices = [ { device = "/swap/swapfile"; size = 1024 * 70; } ]; # 70GB swap

  # Power management
  powerManagement.enable = true;

  networking.networkmanager.enable = true;

  # AMD AI 300 Series CPU microcode updates via ucodenix
  services.ucodenix = {
    enable = true;
    cpuModelId = "00B60F00";
  };

  # Enable fwupd for BIOS/EC/device firmware updates
  services.fwupd.enable = true;
}
