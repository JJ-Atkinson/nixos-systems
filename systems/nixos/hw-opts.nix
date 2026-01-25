{lib, config, pkgs, ...} : {
  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";

  hardware.enableRedistributableFirmware = true;
  hardware.cpu.intel.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;

  # Use the systemd-boot EFI boot loader.
  boot.loader.systemd-boot.enable = true;
  # Temporarily disabled due to corrupted EFI variables (LoaderEntries)
  # Re-enable after reboot to clear kernel EFI variable cache
  boot.loader.efi.canTouchEfiVariables = false;

  # Use latest kernel.
  boot.kernelPackages = pkgs.linuxPackages_latest;


  # Pick only one of the below networking options.
  # networking.wireless.enable = true;  # Enables wireless support via wpa_supplicant.
  networking.networkmanager.enable = true;  # Easiest to use and most distros use this by default.
}
