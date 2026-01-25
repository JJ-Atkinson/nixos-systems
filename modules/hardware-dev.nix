{ config, pkgs, ... }:

{
  # Udev rules for hardware development tools
  services.udev.extraRules = ''
    # Raspberry Pi Pico in BOOTSEL mode
    SUBSYSTEM=="usb", ATTRS{idVendor}=="2e8a", ATTRS{idProduct}=="0003", MODE="0666", GROUP="plugdev"

    # Raspberry Pi Pico with picoprobe/debugprobe
    SUBSYSTEM=="usb", ATTRS{idVendor}=="2e8a", ATTRS{idProduct}=="0004", MODE="0666", GROUP="plugdev"

    # Raspberry Pi Debug Probe
    SUBSYSTEM=="usb", ATTRS{idVendor}=="2e8a", ATTRS{idProduct}=="000c", MODE="0666", GROUP="plugdev"
  '';

  # Ensure plugdev group exists
  users.groups.plugdev = {};
}
