{config, pkgs, ...}:

{
  hardware.spacenavd.enable = true;

  systemd.services.spacenavd = {
    serviceConfig = {
      PIDFile = "/run/spnavd.pid";
      StandardError = "journal";
    };
  };

  # Allow user access to 3Dconnexion devices for WebHID (browser support)
  services.udev.extraRules = ''
    # 3Dconnexion devices
    SUBSYSTEM=="hidraw", ATTRS{idVendor}=="256f", MODE="0666", TAG+="uaccess"
    SUBSYSTEM=="usb", ATTRS{idVendor}=="256f", MODE="0666", TAG+="uaccess"
  '';
}