{ pkgs, lib, nixpkgs, nixpkgsUnstable, modulesPath, ... }:
{
  imports = [
    "${modulesPath}/installer/cd-dvd/installation-cd-graphical-gnome.nix"
  ];

  image.fileName = lib.mkForce "nixos-recovery.iso";

  isoImage = {
    volumeID = lib.mkForce "NIXOS_RECOVERY";
    makeEfiBootable = true;
    makeUsbBootable = true;
    squashfsCompression = "zstd -Xcompression-level 6";
    appendToMenuLabel = " recovery";
  };

  system.nixos.label = lib.mkForce "recovery";

  networking.hostName = "recovery";
  networking.networkmanager.enable = true;

  users.users.rescue = {
    isNormalUser = true;
    description = "Recovery operator";
    extraGroups = [ "wheel" "networkmanager" "disk" "video" "audio" ];
    initialPassword = "rescue";
    shell = pkgs.zsh;
  };

  security.sudo.wheelNeedsPassword = false;
  services.displayManager.autoLogin = {
    enable = lib.mkForce true;
    user = lib.mkForce "rescue";
  };

  programs.zsh.enable = true;

  environment.systemPackages = with pkgs; [
    nixpkgsUnstable.ghostty

    ddrescue
    smartmontools
    nvme-cli
    hdparm
    parted
    gptfdisk
    cryptsetup
    btrfs-progs
    e2fsprogs
    xfsprogs
    dosfstools
    rsync
    git
    neovim
    curl
    wget
    htop
    iotop
    pciutils
    usbutils
    file
    lsof
    tmux
  ];

  environment.gnome.excludePackages = [ pkgs.gnome-tour ];
}
