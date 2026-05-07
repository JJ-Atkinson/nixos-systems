{ config, lib, pkgs, ... }:

let
  cfg = config.services.nixosAutoUpgradeRebootNotifier;

  updateFlags = lib.concatMap (input: [ "--update-input" input ]) cfg.updateInputs;

  notifyUsers = lib.escapeShellArgs cfg.notifyUsers;

  notifyScript = pkgs.writeShellScript "nixos-upgrade-notify-users" ''
    set -u

    title="$1"
    body="$2"
    urgency="''${3:-normal}"

    for user in ${notifyUsers}; do
      uid="$(${pkgs.coreutils}/bin/id -u "$user" 2>/dev/null || true)"
      if [ -z "$uid" ]; then
        continue
      fi

      runtime_dir="/run/user/$uid"
      bus="$runtime_dir/bus"
      if [ ! -S "$bus" ]; then
        continue
      fi

      ${pkgs.util-linux}/bin/runuser -u "$user" -- \
        ${pkgs.coreutils}/bin/env \
          XDG_RUNTIME_DIR="$runtime_dir" \
          DBUS_SESSION_BUS_ADDRESS="unix:path=$bus" \
          ${pkgs.libnotify}/bin/notify-send \
            --app-name="NixOS Auto Upgrade" \
            --urgency="$urgency" \
            "$title" \
            "$body" || true
    done
  '';

  rebootRequiredScript = pkgs.writeShellScript "nixos-upgrade-check-reboot-required" ''
    set -u

    state_dir=${lib.escapeShellArg cfg.stateDir}
    marker="$state_dir/reboot-required"

    booted="$(${pkgs.coreutils}/bin/readlink -f \
      /run/booted-system/initrd \
      /run/booted-system/kernel \
      /run/booted-system/kernel-modules 2>/dev/null || true)"

    current="$(${pkgs.coreutils}/bin/readlink -f \
      /nix/var/nix/profiles/system/initrd \
      /nix/var/nix/profiles/system/kernel \
      /nix/var/nix/profiles/system/kernel-modules 2>/dev/null || true)"

    if [ "$booted" != "$current" ]; then
      ${pkgs.coreutils}/bin/mkdir -p "$state_dir"
      if [ ! -e "$marker" ]; then
        ${pkgs.coreutils}/bin/date --iso-8601=seconds > "$marker"
      fi

      ${notifyScript} \
        "NixOS update installed" \
        "A kernel/initrd update requires a real reboot. Hibernate/resume is not enough." \
        critical
    else
      ${pkgs.coreutils}/bin/rm -f "$marker"
    fi
  '';
in
{
  options.services.nixosAutoUpgradeRebootNotifier = {
    enable = lib.mkEnableOption "NixOS auto-upgrades with desktop reboot-required notifications";

    flake = lib.mkOption {
      type = lib.types.str;
      default = "/etc/nixos#${config.networking.hostName}";
      description = "Flake URI for the NixOS configuration to auto-upgrade.";
    };

    updateInputs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "nixpkgs" ];
      description = "Flake inputs to update before rebuilding.";
    };

    dates = lib.mkOption {
      type = lib.types.str;
      default = "04:40";
      description = "systemd calendar expression for the auto-upgrade timer.";
    };

    randomizedDelaySec = lib.mkOption {
      type = lib.types.str;
      default = "0";
      description = "Randomized delay for the auto-upgrade timer.";
    };

    notifyUsers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Users whose active desktop sessions should receive upgrade notifications.";
    };

    stateDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/nixos-reboot-required";
      description = "Directory used to track whether a reboot-required notice has been emitted.";
    };
  };

  config = lib.mkIf cfg.enable {
    system.autoUpgrade = {
      enable = true;
      operation = "switch";
      allowReboot = false;
      flake = cfg.flake;
      flags = updateFlags;
      dates = cfg.dates;
      randomizedDelaySec = cfg.randomizedDelaySec;
    };

    systemd.services.nixos-upgrade = {
      preStart = ''
        ${notifyScript} \
          "NixOS package refresh started" \
          "NixOS is refreshing flake inputs and applying available updates." \
          normal
      '';

      postStart = ''
        ${rebootRequiredScript}
      '';
    };
  };
}
