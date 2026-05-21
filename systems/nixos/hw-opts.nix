{lib, config, pkgs, ...} : {
  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";

  hardware.enableRedistributableFirmware = true;
  hardware.cpu.intel.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;

  # Use the systemd-boot EFI boot loader.
  boot.loader.systemd-boot.enable = true;
  # Memtest86+ entry in boot menu (for diagnosing the WD SN7100 corruption
  # incident on 2026-05-18 — rule out RAM as the source).
  boot.loader.systemd-boot.memtest86.enable = true;
  # Temporarily disabled due to corrupted EFI variables (LoaderEntries)
  # Re-enable after reboot to clear kernel EFI variable cache
  boot.loader.efi.canTouchEfiVariables = false;

  # Two-disk ESP mirror. systemd-boot installs to /boot (disk_a's ESP); after
  # each install we rsync into /boot-fallback (disk_b's ESP) so the firmware
  # can boot from either disk if one is lost. No --delete on the rsync so
  # older generations on the fallback ESP aren't pruned mid-install — the ESP
  # is 1 GiB which is comfortable for hundreds of generations; periodic
  # cleanup can mirror nixos-rebuild's gc.
  boot.loader.systemd-boot.extraInstallCommands = ''
    if mountpoint -q /boot-fallback; then
      ${pkgs.rsync}/bin/rsync -aH --info=stats1 /boot/ /boot-fallback/
    else
      echo "WARN: /boot-fallback not mounted; skipping ESP mirror" >&2
    fi
  '';

  # Use latest kernel.
  boot.kernelPackages = pkgs.linuxPackages_latest;

  # NVMe Host Memory Buffer cap. SN7100s report hmpre=78 MiB / hmmin=32 MiB.
  # First attempt at 128 produced asymmetric allocation: nvme1 got full 78 MiB
  # preferred but nvme2 only its 32 MiB minimum (apparent global, not
  # per-controller, behavior in current kernel). Partial-HMB on nvme2 caused
  # 63% randread regression (310k → 115k IOPS) — exact bug pattern suspected
  # behind the 2026-05-18 vm-storage csum-error incident. Bumped to 512 so
  # every drive gets its preferred allocation with headroom. User confirmed
  # ~512 MiB of RAM dedicated to HMB is acceptable.
  boot.kernelParams = [ "nvme.max_host_mem_size_mb=512" ];


  # Pick only one of the below networking options.
  # networking.wireless.enable = true;  # Enables wireless support via wpa_supplicant.
  networking.networkmanager.enable = true;  # Easiest to use and most distros use this by default.
}
