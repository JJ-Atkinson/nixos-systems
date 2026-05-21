{ config, lib, pkgs, ... }:

let
  cfg = config.services.smartErrorWatch;

  notifyUsers = lib.escapeShellArgs cfg.notifyUsers;
  devices = lib.escapeShellArgs cfg.devices;

  notifyScript = pkgs.writeShellScript "smart-error-watch-notify-users" ''
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
            --app-name="SMART error watch" \
            --urgency="$urgency" \
            "$title" \
            "$body" || true
    done
  '';

  watchScript = pkgs.writeShellScript "smart-error-watch-run" ''
    set -u

    state_dir=${lib.escapeShellArg cfg.stateDir}
    ${pkgs.coreutils}/bin/mkdir -p "$state_dir"

    for drive in ${devices}; do
      sn="$(${pkgs.smartmontools}/bin/smartctl -i "$drive" \
        | ${pkgs.gawk}/bin/awk '/Serial Number/ {print $3}')"
      if [ -z "$sn" ]; then
        continue
      fi

      cur="$(${pkgs.smartmontools}/bin/smartctl -a "$drive" \
        | ${pkgs.gawk}/bin/awk -F: '/Media and Data Integrity Errors/ {gsub(/[, ]/,"",$2); print $2}')"
      if [ -z "$cur" ]; then
        continue
      fi

      prev_file="$state_dir/$sn"
      prev="$(${pkgs.coreutils}/bin/cat "$prev_file" 2>/dev/null || echo 0)"

      if [ "$cur" -gt "$prev" ]; then
        delta=$(( cur - prev ))
        ${notifyScript} \
          "SMART: $drive ($sn)" \
          "Media and Data Integrity Errors grew by $delta (now $cur)." \
          critical
        ${pkgs.util-linux}/bin/logger -t smart-error-watch \
          "$drive ($sn) media errors grew by $delta to $cur"
      fi

      echo "$cur" > "$prev_file"
    done
  '';
in
{
  options.services.smartErrorWatch = {
    enable = lib.mkEnableOption "Periodic SMART Media Error counter check with desktop notification on growth";

    devices = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "/dev/nvme0n1" "/dev/nvme1n1" ];
      description = "NVMe device nodes to poll. SN is read from each at runtime so device-name churn is handled.";
    };

    notifyUsers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Users whose active desktop sessions should receive growth notifications.";
    };

    dates = lib.mkOption {
      type = lib.types.str;
      default = "hourly";
      description = "systemd calendar expression for the polling timer.";
    };

    randomizedDelaySec = lib.mkOption {
      type = lib.types.str;
      default = "0";
      description = "Randomized delay for the polling timer.";
    };

    stateDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/smart-error-watch";
      description = "Directory used to remember each drive's last observed Media Error count.";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.smart-error-watch = {
      description = "Poll SMART Media Error counters and alert on growth";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${watchScript}";
      };
    };

    systemd.timers.smart-error-watch = {
      description = "Periodic SMART Media Error counter poll";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.dates;
        RandomizedDelaySec = cfg.randomizedDelaySec;
        Persistent = true;
        Unit = "smart-error-watch.service";
      };
    };
  };
}
