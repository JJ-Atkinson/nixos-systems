{lib, config, pkgs, ...} : {

  # environment.systemPackages = with pkgs; [ git vim ];

  boot.initrd.availableKernelModules = [ "xhci_pci" "ahci" "nvme" "usbhid" "uas" "sd_mod" ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ "kvm-intel" ];
  boot.extraModulePackages = [ ];

  fileSystems."/" =
    { device = "/dev/disk/by-uuid/e707f1f9-9aa1-485a-90c8-afc1afa27e06";
      fsType = "btrfs";
      options = [ "subvol=@" "ssd" "noatime" ];
    };

  
  boot.initrd.systemd.enable = true;
  boot.initrd.luks.devices."cryptbtrfs".allowDiscards = true;
  boot.initrd.luks.devices."cryptbtrfs".device = "/dev/disk/by-uuid/4cc951e1-6457-435d-a924-d6e8c4e61f39";

  fileSystems."/home" =
    { device = "/dev/disk/by-uuid/e707f1f9-9aa1-485a-90c8-afc1afa27e06";
      fsType = "btrfs";
      options = [ "subvol=@home" "ssd" "noatime" ];
    };

  fileSystems."/nix" =
    { device = "/dev/disk/by-uuid/e707f1f9-9aa1-485a-90c8-afc1afa27e06";
      fsType = "btrfs";
      options = [ "subvol=@nix" "compress=zstd" "ssd" "noatime" ];
    };

  fileSystems."/var/log" =
    { device = "/dev/disk/by-uuid/e707f1f9-9aa1-485a-90c8-afc1afa27e06";
      fsType = "btrfs";
      options = [ "subvol=@log" "compress=zstd" "ssd" "noatime" ];
    };

  fileSystems."/swap" =
    { device = "/dev/disk/by-uuid/e707f1f9-9aa1-485a-90c8-afc1afa27e06";
      fsType = "btrfs";
      options = [ "subvol=@swap" "compress=no" "ssd" "noatime" ];
    };

  swapDevices = [ {device = "/swap/swapfile"; size = 1024 * 70; } ];
  powerManagement.enable = true;
  

  hardware.cpu.intel.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
}
