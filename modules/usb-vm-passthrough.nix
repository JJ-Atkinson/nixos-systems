{ config, lib, pkgs, ... }:

{
  # ============================================================================
  # USB Device Exclusive Passthrough for VMs - DISABLED
  # ============================================================================
  #
  # NOTE: USB passthrough udev rules are currently disabled because they interfere
  # with libvirt's ability to claim devices via libusb.
  #
  # CURRENT APPROACH:
  # Instead of using udev rules, manually unbind drivers before starting the VM:
  #
  #   # Find the device
  #   HUION_DEV=$(grep -l "256c" /sys/bus/usb/devices/*/idVendor | head -1 | xargs dirname)
  #
  #   # Unbind all interface drivers
  #   for intf in $HUION_DEV/*:*/driver; do
  #     [ -e "$intf/unbind" ] && echo $(basename $(dirname $intf)) > $intf/unbind
  #   done
  #
  # Or use libvirt's startupPolicy='optional' and managed='yes' which should
  # handle driver unbinding automatically.
  #
  # ============================================================================

  # No udev rules - rely on libvirt's managed USB passthrough instead
  services.udev.extraRules = "";
}
