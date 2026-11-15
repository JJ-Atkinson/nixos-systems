{ config, lib, pkgs, ... }:
let
  fsUuid = "6137e9a6-e9b2-49e6-9ac4-03e044ee845a";
  swapUuid = "25eb788e:0c293850:a21dc655:0086fa90";
  rootCryptUnits = [
    "systemd-cryptsetup@cryptbtrfs_a.service"
    "systemd-cryptsetup@cryptbtrfs_b.service"
  ];
  # 64-btrfs.rules otherwise withholds SYSTEMD_READY when a member is absent.
  # Scope the exception to this RAID1 filesystem, in BOTH boot stages. The
  # mount still validates redundancy and explicitly uses the degraded option.
  readyRule = ''
    SUBSYSTEM=="block", ENV{ID_FS_TYPE}=="btrfs", ENV{ID_FS_UUID}=="${fsUuid}", ENV{SYSTEMD_READY}="1"
  '';
in
{
  assertions = [{
    assertion = config.boot.initrd.systemd.enable;
    message = "The desktop's mirrored-root recovery requires systemd initrd.";
  }];

  # The filesystem UUID is shared by the two Btrfs members, unlike a LUKS
  # UUID or /dev/mapper/cryptbtrfs_b. No partitioning/formatting is involved.
  fileSystems = lib.genAttrs
    [ "/" "/home" "/nix" "/var/log" "/vm-storage/images" "/vm-storage/shared" ]
    (_: {
      device = lib.mkForce "/dev/disk/by-uuid/${fsUuid}";
      options = [ "x-systemd.requires=mirrored-root-ready.service" ];
    }) // {
      "/boot".options = [ "nofail" "x-systemd.device-timeout=10s" ];
      "/boot-fallback".options = [ "nofail" "x-systemd.device-timeout=10s" ];
    };

  boot.initrd.luks.devices = lib.genAttrs
    [ "cryptbtrfs_a" "cryptbtrfs_b" "cryptswap" ]
    (_: {
      # Keep these mappings attached across switch-root, including swap,
      # which is not held open by an initrd filesystem mount.
      crypttabExtraOpts = [ "nofail" "x-systemd.device-timeout=30s" "x-initrd.attach" ];
    });

  boot.initrd.services.udev.rules = readyRule;
  services.udev.extraRules = readyRule;
  boot.initrd.systemd.storePaths = [
    "${pkgs.coreutils}/bin/tr"
    "${pkgs.coreutils}/bin/cat"
    "${pkgs.coreutils}/bin/readlink"
  ];

  boot.initrd.systemd.services.mirrored-root-ready = {
    description = "Register available encrypted Btrfs RAID1 members";
    # nofail deliberately removes cryptsetup.target ordering; explicitly wait
    # for BOTH attempts so a normal boot never races the second unlock.
    wants = rootCryptUnits;
    after = rootCryptUnits;
    before = [ "sysroot.mount" ];
    unitConfig.DefaultDependencies = false;
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      found=0
      for device in /dev/mapper/cryptbtrfs_a /dev/mapper/cryptbtrfs_b; do
        if test -b "$device"; then
          ${pkgs.btrfs-progs}/bin/btrfs device scan "$device"
          found=$((found + 1))
        fi
      done
      if test "$found" -eq 0; then
        echo "Neither encrypted root member is available; refusing to mount." >&2
        exit 1
      fi
      if test "$found" -eq 1; then
        echo "WARNING: booting Btrfs root with one member; redundancy is lost." >&2
      fi
    '';
  };

  # fstab also references the readiness service after switch-root. The work
  # was already done in initrd; do not try to unlock containers a second time.
  systemd.services.mirrored-root-ready = {
    description = "Encrypted Btrfs members were registered by initrd";
    unitConfig.DefaultDependencies = false;
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.coreutils}/bin/true";
    };
  };

  # Incremental mdadm assembly can leave a one-member array inactive. Start
  # only our known swap array; never force-assemble stale members or create it.
  boot.swraid.mdadmConf = ''
    ARRAY /dev/md/swap UUID=${swapUuid}
  '';
  # 26.05 no longer includes this unit implicitly.
  boot.initrd.systemd.additionalUpstreamUnits = [ "systemd-udev-settle.service" ];
  boot.initrd.systemd.services.mirrored-swap-assemble = {
    description = "Start the existing swap RAID1, allowing a missing member";
    # Swap's physical RAID partitions do not depend on either root unlock.
    # Waiting for a missing root member here races cryptswap's device timeout.
    wants = [ "systemd-udev-settle.service" ];
    after = [ "systemd-udev-settle.service" ];
    before = [ "systemd-cryptsetup@cryptswap.service" ];
    unitConfig = {
      DefaultDependencies = false;
      IgnoreOnIsolate = true;
    };
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      array=
      # Incremental assembly may expose only /dev/md127 while inactive, not
      # /dev/md/swap. Locate that existing array by UUID, never by enumeration.
      for uuid_file in /sys/class/block/md*/md/uuid; do
        if test -r "$uuid_file" && test "$(${pkgs.coreutils}/bin/tr -d ':-' < "$uuid_file")" = "${lib.replaceStrings [ ":" ] [ "" ] swapUuid}"; then
          array="''${uuid_file%/md/uuid}"
          array="/dev/''${array##*/}"
          break
        fi
      done
      # An inactive incremental array can lack a usable sysfs UUID. Check
      # the on-disk member UUID, then find the array holding that member.
      if test -z "$array"; then
        for member in /dev/disk/by-partlabel/disk-disk_a-swap_raid /dev/disk/by-partlabel/disk-disk_b-swap_raid; do
          if ! test -b "$member"; then continue; fi
          member_info=$(${pkgs.mdadm}/bin/mdadm --examine --export "$member")
          member_uuid=
          while IFS='=' read -r key value; do
            if test "$key" = MD_UUID; then member_uuid="$value"; fi
          done <<< "$member_info"
          if test "$member_uuid" != "${swapUuid}"; then
            echo "Refusing unexpected swap member UUID on $member" >&2
            exit 1
          fi
          member=$(${pkgs.coreutils}/bin/readlink -f "$member")
          for md_dir in /sys/class/block/md*/md; do
            candidate="''${md_dir%/md}"
            if test -e "$candidate/slaves/''${member##*/}"; then
              array="/dev/''${candidate##*/}"
              break
            fi
          done
          if test -n "$array"; then break; fi
        done
      fi
      if test -n "$array"; then
        state=$(${pkgs.coreutils}/bin/cat "/sys/class/block/''${array##*/}/md/array_state")
        if test "$state" = inactive; then
          ${pkgs.mdadm}/bin/mdadm --run "$array"
        fi
      else
        ${pkgs.mdadm}/bin/mdadm --assemble --run /dev/md/swap --uuid=${swapUuid}
      fi
    '';
  };
  boot.initrd.systemd.services."systemd-cryptsetup@cryptswap" = {
    # MUST be a drop-in: the base unit is created at boot by the generator.
    overrideStrategy = "asDropin";
    wants = [ "mirrored-swap-assemble.service" ];
    after = [ "mirrored-swap-assemble.service" ];
  };

  # If disk_a is absent, promote the mounted fallback ESP to /boot. This lets
  # systemd-boot updates target the survivor rather than the root filesystem.
  systemd.services.mirrored-esp-promote = {
    description = "Use the surviving EFI partition when the primary is missing";
    wantedBy = [ "local-fs.target" ];
    wants = [ "boot.mount" "boot-fallback.mount" ];
    after = [ "boot.mount" "boot-fallback.mount" ];
    before = [ "local-fs.target" ];
    unitConfig.DefaultDependencies = false;
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      if ! ${pkgs.util-linux}/bin/mountpoint -q /boot; then
        if ${pkgs.util-linux}/bin/mountpoint -q /boot-fallback; then
          ${pkgs.coreutils}/bin/mkdir -p /boot
          ${pkgs.util-linux}/bin/mount --bind /boot-fallback /boot
          echo "WARNING: using fallback EFI partition as /boot." >&2
        else
          echo "WARNING: neither EFI partition is mounted; do not rebuild boot entries." >&2
        fi
      fi
    '';
  };
}
