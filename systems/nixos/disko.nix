{ pkgs, ... }:
{
  disko.devices = {
    disk = {
      # disk_a: WD_BLACK SN7100 — empty LUKS, joined to btrfs by mkfs from disk_b.
      # Discovered via `ls /dev/disk/by-id/`; serial 25306L805271.
      # Note: at install time nvme enumeration had WD=nvme1n1 (Solidigm=nvme0n1),
      # the inverse of the original system. by-id pinning makes this irrelevant.
      disk_a = {
        type = "disk";
        device = "/dev/disk/by-id/nvme-WD_BLACK_SN7100_2TB_25306L805271";
        content = {
          type = "gpt";
          partitions = {
            ESP = {
              size = "1G";
              type = "EF00";
              # Plain vfat ESP, NOT an mdadm member. NixOS's systemd-boot
              # installer (`bootctl install`) refuses to install onto a
              # non-partitioned block device (md*), so we keep each ESP as a
              # real GPT partition and mirror /boot -> /boot-fallback via
              # boot.loader.systemd-boot.extraInstallCommands in hw-opts.nix.
              content = {
                type = "filesystem";
                format = "vfat";
                mountpoint = "/boot";
                mountOptions = [ "umask=0077" ];
              };
            };
            swap_raid = {
              size = "70G";
              content = {
                type = "mdraid";
                name = "swap";
              };
            };
            crypt = {
              size = "100%";
              content = {
                type = "luks";
                name = "cryptbtrfs_a";
                askPassword = true;
                settings.allowDiscards = true;
                settings.crypttabExtraOpts = [ "fido2-device=auto" ];
                # No btrfs content here — disko opens this LUKS first; mkfs.btrfs
                # runs from disk_b and references /dev/mapper/cryptbtrfs_a as a
                # second device via extraArgs.
              };
            };
          };
        };
      };

      # disk_b: Solidigm SSDPFKNU020TZ 2TB — carries the btrfs filesystem
      # definition; mkfs joins disk_a's mapper into the same RAID1 filesystem.
      # Serial PHEH308200MD2P0C.
      disk_b = {
        type = "disk";
        device = "/dev/disk/by-id/nvme-SOLIDIGM_SSDPFKNU020TZ_PHEH308200MD2P0C";
        content = {
          type = "gpt";
          partitions = {
            ESP = {
              size = "1G";
              type = "EF00";
              # Mirror of disk_a's ESP. extraInstallCommands keeps it in sync.
              content = {
                type = "filesystem";
                format = "vfat";
                mountpoint = "/boot-fallback";
                mountOptions = [ "umask=0077" ];
              };
            };
            swap_raid = {
              size = "70G";
              content = {
                type = "mdraid";
                name = "swap";
              };
            };
            crypt = {
              size = "100%";
              content = {
                type = "luks";
                name = "cryptbtrfs_b";
                askPassword = true;
                settings.allowDiscards = true;
                settings.crypttabExtraOpts = [ "fido2-device=auto" ];
                content = {
                  type = "btrfs";
                  extraArgs = [
                    "-L" "cryptbtrfs"
                    "-d" "raid1"
                    "-m" "raid1"
                    "/dev/mapper/cryptbtrfs_a"
                  ];
                  subvolumes = {
                    "@" = {
                      mountpoint = "/";
                      mountOptions = [ "compress=zstd" "ssd" "noatime" "degraded" ];
                    };
                    "@home" = {
                      mountpoint = "/home";
                      mountOptions = [ "compress=zstd" "ssd" "noatime" "degraded" ];
                    };
                    "@nix" = {
                      mountpoint = "/nix";
                      mountOptions = [ "compress=zstd" "ssd" "noatime" "degraded" ];
                    };
                    "@log" = {
                      mountpoint = "/var/log";
                      mountOptions = [ "compress=zstd" "ssd" "noatime" "degraded" ];
                    };
                    "@vm-images" = {
                      mountpoint = "/vm-storage/images";
                      mountOptions = [ "ssd" "noatime" "degraded" ];
                    };
                    "@vm-shared" = {
                      mountpoint = "/vm-storage/shared";
                      mountOptions = [ "ssd" "noatime" "degraded" ];
                    };
                  };
                  # Apply chattr +C to the VM-storage subvolumes so files created
                  # inside them inherit nodatacow (the per-subvolume postCreateHook
                  # the plan suggested doesn't exist in disko's btrfs subvolume
                  # type — hooks live on the filesystem, not the subvolume).
                  postCreateHook = ''
                    for sv in @vm-images @vm-shared; do
                      MNT=$(mktemp -d)
                      mount -o "subvol=$sv" /dev/mapper/cryptbtrfs_b "$MNT"
                      ${pkgs.e2fsprogs}/bin/chattr +C "$MNT"
                      umount "$MNT"
                      rmdir "$MNT"
                    done
                  '';

              };
            };
          };
        };
      };
    };

    };

    mdadm = {
      # Mirrored, encrypted, hibernation-capable swap. mdadm RAID1 (metadata=1.2)
      # → LUKS (same passphrase as the btrfs pair, deduplicated by systemd's
      # initrd password cache) → swap. resumeDevice=true tells disko to set
      # boot.resumeDevice for hibernate.
      swap = {
        type = "mdadm";
        level = 1;
        metadata = "1.2";
        content = {
          type = "luks";
          name = "cryptswap";
          askPassword = true;
          settings.allowDiscards = true;
          settings.crypttabExtraOpts = [ "fido2-device=auto" ];
          content = {
            type = "swap";
            resumeDevice = true;
          };
        };
      };
    };
  };
}
