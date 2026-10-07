{pkgs, lib, ... }:

{
  environment.systemPackages = with pkgs; [
    sbctl
  ];

  # Disable systemd-boot when using Lanzaboote
  boot.loader.systemd-boot.enable = false;

  boot.lanzaboote = {
    enable = true;
    pkiBundle = "/var/lib/sbctl";

    # Automatically generate Secure Boot keys if they don't exist
    autoGenerateKeys.enable = true;

    # Automatically enroll the keys with Microsoft keys included
    # This will prepare the keys for enrollment on next boot
    autoEnrollKeys = {
      enable = true;
      # Include Microsoft keys for compatibility with Option ROMs
      includeMicrosoftKeys = true;
      # Optionally auto-reboot after key preparation (disabled by default for safety)
      # autoReboot = true;
    };
  };
}
