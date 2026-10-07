{lib, config, pkgs, ...} : {
  # nixos-hardware module (framework-amd-ai-300-series) handles most Framework-specific configuration
  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";

  # Enable WiFi firmware
  hardware.enableRedistributableFirmware = true;

  # Boot loader is configured in modules/lanza.nix (Lanzaboote for Secure Boot)
  boot.loader.efi.canTouchEfiVariables = true;

  # Use latest kernel.
  boot.kernelPackages = pkgs.linuxPackages_latest;

  # Disable AMD microcode checksum verification (required for ucodenix)
  # boot.kernelParams = [ "microcode.amd_sha_check=off" ];

  # Disable amdgpu VPE (Video Processing Engine, IP block 11) to prevent VPE queue
  # reset failures on suspend/hibernate that can cause the display to not recover on resume.
  # VPE is used for video post-processing pipelines, not for video decode (VCN) or display (DCN).
  boot.kernelParams = [ "amdgpu.ip_block_mask=0xFFFFF7FF" ];

  # Initrd settings
  boot.initrd.systemd.enable = true;
  boot.initrd.availableKernelModules = [ "xhci_pci" "ahci" "nvme" "usbhid" "uas" "sd_mod" ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ "kvm-amd" ]; # AMD instead of Intel
  boot.extraModulePackages = [ ];

  # Swap file configuration (disko handles the mount point)
  swapDevices = [ { device = "/swap/swapfile"; size = 1024 * 70; } ]; # 70GB swap

  # Power management
  powerManagement.enable = true;

  # Hybrid sleep configuration: suspend first, then hibernate after delay
  systemd.sleep.extraConfig = ''
    HibernateDelaySec=90min
  '';

  # Configure systemd to use suspend-then-hibernate for lid close
  services.logind.settings.Login = {
    HandleLidSwitch = "suspend-then-hibernate";
    HandleLidSwitchExternalPower = "suspend-then-hibernate";
  };

  # UPower configuration for battery-based hibernation (backup protection)
  services.upower = {
    enable = true;
    percentageLow = 15;           # Show low battery warning at 15%
    percentageCritical = 10;      # Mark as critical at 10%
    percentageAction = 10;        # Take action at 10%
    criticalPowerAction = "Hibernate";  # Hibernate when battery reaches 10%
  };

  networking.networkmanager.enable = true;

  # AMD AI 300 Series CPU microcode updates via ucodenix
  services.ucodenix = {
    enable = true;
    cpuModelId = "00B60F00";
  };

  # Enable fwupd for BIOS/EC/device firmware updates
  services.fwupd.enable = true;

  # Daily firmware update checker with desktop notifications
  systemd.services.fwupd-update-check = {
    description = "Check for firmware updates and notify";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.writeShellScript "fwupd-check.sh" ''
        # Refresh metadata first
        ${pkgs.fwupd}/bin/fwupdmgr refresh --force || true

        # JSON avoids missing updates when other devices have no available updates.
        if UPDATES=$(${pkgs.fwupd}/bin/fwupdmgr --json get-updates); then
          :
        else
          status=$?
          # fwupdmgr uses exit status 2 when there is nothing to do.
          if [ "$status" -eq 2 ]; then
            echo "No firmware updates available"
            exit 0
          fi
          exit "$status"
        fi

        if ${pkgs.jq}/bin/jq -e 'any(.Devices[]?; ((.Releases // []) | length) > 0)' <<< "$UPDATES" >/dev/null; then
          echo "Firmware updates available!"

          ${pkgs.sudo}/bin/sudo -u jarrett \
            DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus \
            ${pkgs.libnotify}/bin/notify-send \
              --urgency=normal \
              --icon=system-software-update \
              "Firmware Updates Available" \
              "Run 'fwupdmgr update' to install firmware updates."
        else
          echo "No firmware updates available"
        fi
      ''}";
    };
  };

  systemd.timers.fwupd-update-check = {
    description = "Daily firmware update check timer";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "daily";
      Persistent = true;
      RandomizedDelaySec = "1h";
    };
  };

  # Configure Goodix fingerprint reader with TOD driver
  services.fprintd.tod = {
    enable = true;
    driver = pkgs.libfprint-2-tod1-goodix;
  };

  # Fix fingerprint reader not enumerating on boot
  # Sometimes the Goodix fingerprint reader (27c6:609c) fails to enumerate during boot.
  # This service resets the USB controller early in boot to ensure proper device detection.
  systemd.services.fingerprint-boot-fix = {
    description = "Reset USB controller at boot to ensure fingerprint reader enumeration";
    after = [ "systemd-udev-settle.service" ];
    before = [ "display-manager.service" "gdm.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.writeShellScript "fingerprint-boot-reset.sh" ''
        set -e
        FINGERPRINT_READER_ID="27c6:609c"
        # Try both USB controllers that the fingerprint reader might be connected to
        USB_CONTROLLERS=("c1:00.4" "c3:00.3")

        # Check if fingerprint reader is already detected
        if ${pkgs.usbutils}/bin/lsusb | grep -q "$FINGERPRINT_READER_ID" ; then
          echo "Fingerprint reader already detected, no reset needed"
          exit 0
        fi

        echo "Fingerprint reader not detected, resetting USB controllers..."

        # Reset each USB controller to trigger re-enumeration
        for BUS_ID in "''${USB_CONTROLLERS[@]}"; do
          if [ -e "/sys/bus/pci/devices/0000:$BUS_ID" ]; then
            echo "Resetting USB controller 0000:$BUS_ID"

            # Unbind the controller
            if [ -e "/sys/bus/pci/drivers/xhci_hcd/0000:$BUS_ID" ]; then
              echo "0000:$BUS_ID" > /sys/bus/pci/drivers/xhci_hcd/unbind || true
              sleep 1
            fi

            # Reset the device
            echo 1 > "/sys/bus/pci/devices/0000:$BUS_ID/reset" || true
            sleep 1

            # Rebind the controller
            echo "0000:$BUS_ID" > /sys/bus/pci/drivers/xhci_hcd/bind || true
            sleep 2

            # Check if device appeared after this controller reset
            if ${pkgs.usbutils}/bin/lsusb | grep -q "$FINGERPRINT_READER_ID" ; then
              echo "Fingerprint reader detected after resetting $BUS_ID"
              exit 0
            fi
          fi
        done

        # If still not detected, log warning but don't fail the service
        if ! ${pkgs.usbutils}/bin/lsusb | grep -q "$FINGERPRINT_READER_ID" ; then
          echo "Warning: Fingerprint reader still not detected after USB controller reset"
        fi
      ''}";
    };
  };

  # Fix fingerprint reader getting stuck after sleep by resetting USB bus
  # See: https://community.frame.work/t/debian-trixie-on-framework-13-with-amd-ryzen-ai-5-300-series/78666
  systemd.services.fingerprint-sleep-fix = {
    description = "Check and reset fingerprint reader after wake up";
    before = [ "sleep.target" ];
    wantedBy = [ "sleep.target" ];
    unitConfig = {
      StopWhenUnneeded = true;
    };
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.coreutils}/bin/true";
      ExecStop = "${pkgs.writeShellScript "fingerprint-reset.sh" ''
        set -e
        FINGERPRINT_READER_ID="27c6:609c"
        USB_CONTROLLERS=("c1:00.4" "c3:00.3")

        # Check if fingerprint reader is responding
        if ${pkgs.usbutils}/bin/lsusb | grep -q "$FINGERPRINT_READER_ID" ; then
          echo "Fingerprint reader detected after wake, no reset needed"
          exit 0
        fi

        echo "Fingerprint reader not detected after wake, resetting USB controllers..."

        # Reset USB controllers to restore the fingerprint reader
        for BUS_ID in "''${USB_CONTROLLERS[@]}"; do
          if [ -e "/sys/bus/pci/devices/0000:$BUS_ID" ]; then
            echo "Resetting USB controller 0000:$BUS_ID"

            if [ -e "/sys/bus/pci/drivers/xhci_hcd/0000:$BUS_ID" ]; then
              echo "0000:$BUS_ID" > /sys/bus/pci/drivers/xhci_hcd/unbind || true
              sleep 1
            fi

            echo 1 > "/sys/bus/pci/devices/0000:$BUS_ID/reset" || true
            sleep 1

            echo "0000:$BUS_ID" > /sys/bus/pci/drivers/xhci_hcd/bind || true
            sleep 2

            if ${pkgs.usbutils}/bin/lsusb | grep -q "$FINGERPRINT_READER_ID" ; then
              echo "Fingerprint reader restored after resetting $BUS_ID"
              exit 0
            fi
          fi
        done
      ''}";
    };
  };

}
