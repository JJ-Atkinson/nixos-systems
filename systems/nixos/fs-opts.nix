{ lib, config, pkgs, ... }: {

  # Filesystems, LUKS, and swap are declared by ./disko.nix. This file now only
  # carries kernel/initrd module config and host-level toggles that don't fit in
  # the disko layout.

  boot.initrd.availableKernelModules = [ "xhci_pci" "ahci" "nvme" "usbhid" "uas" "sd_mod" ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ "kvm-intel" ];
  boot.extraModulePackages = [ ];

  # systemd-stage1: required for the cryptsetup password cache that lets a
  # single typed passphrase unlock all three LUKS containers (cryptbtrfs_a,
  # cryptbtrfs_b, cryptswap).
  boot.initrd.systemd.enable = true;

  # mdadm arrays (boot ESP mirror, swap mirror) need swraid enabled at runtime.
  boot.swraid.enable = true;

  # mdmon (the mdadm metadata monitor) crashes on start unless MAILADDR or
  # PROGRAM is set. Stub value; Plan B replaces this with a PROGRAM hook that
  # routes degraded-array events to desktop notify-send.
  boot.swraid.mdadmConf = "MAILADDR root@localhost";

  powerManagement.enable = true;

  hardware.cpu.intel.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
}
