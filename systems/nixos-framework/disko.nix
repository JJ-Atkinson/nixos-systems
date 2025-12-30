{
  disko.devices = {
    disk = {
      main = {
        type = "disk";
        device = "/dev/nvme0n1"; # Change this to match your Framework's NVMe device
        content = {
          type = "gpt";
          partitions = {
            ESP = {
              size = "512M";
              type = "EF00";
              content = {
                type = "filesystem";
                format = "vfat";
                mountpoint = "/boot";
                mountOptions = [
                  "defaults"
                ];
              };
            };
            luks = {
              size = "100%";
              content = {
                type = "luks";
                name = "cryptbtrfs";
                # Disable settings.keyFile if you want to enter password interactively
                # passwordFile = "/tmp/secret.key"; # Set this during install
                settings = {
                  allowDiscards = true;
                  # Enable this for systemd initrd
                  # crypttabExtraOpts = [ "tpm2-device=auto" ]; # Optional: TPM2 unlock
                };
                content = {
                  type = "btrfs";
                  extraArgs = [ "-f" ]; # Force overwrite
                  subvolumes = {
                    # Root subvolume
                    "@" = {
                      mountpoint = "/";
                      mountOptions = [ "subvol=@" "ssd" "noatime" ];
                    };
                    # Home subvolume
                    "@home" = {
                      mountpoint = "/home";
                      mountOptions = [ "subvol=@home" "ssd" "noatime" ];
                    };
                    # Nix store subvolume with compression
                    "@nix" = {
                      mountpoint = "/nix";
                      mountOptions = [ "subvol=@nix" "compress=zstd" "ssd" "noatime" ];
                    };
                    # Log subvolume with compression
                    "@log" = {
                      mountpoint = "/var/log";
                      mountOptions = [ "subvol=@log" "compress=zstd" "ssd" "noatime" ];
                    };
                    # Swap subvolume (no compression for swap)
                    "@swap" = {
                      mountpoint = "/swap";
                      mountOptions = [ "subvol=@swap" "compress=no" "ssd" "noatime" ];
                    };
                  };
                };
              };
            };
          };
        };
      };
    };
  };
}
