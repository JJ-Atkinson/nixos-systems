{ config, lib, pkgs, ... }:

let
  cfg = config.services.diskWriteWatch;

  sampleScript = pkgs.writeShellScript "disk-write-watch-sample" ''
    set -eu
    export PATH=${lib.makeBinPath [ pkgs.coreutils pkgs.gawk pkgs.gnused pkgs.gnugrep pkgs.util-linux ]}

    log_dir=${lib.escapeShellArg cfg.logDir}
    state_dir=${lib.escapeShellArg cfg.stateDir}
    mkdir -p "$log_dir" "$state_dir"

    ts="$(date -Is)"
    day="$(date +%F)"
    log="$log_dir/writes-$day.log"
    prev="$state_dir/io.prev"
    cur="$state_dir/io.cur"
    disk_prev="$state_dir/disk.prev"
    disk_cur="$state_dir/disk.cur"

    # Per-process cumulative write_bytes (bytes actually submitted to block layer).
    : > "$cur"
    for pid in /proc/[0-9]*; do
      [ -r "$pid/io" ] || continue
      w="$(awk '/^write_bytes:/ {print $2}' "$pid/io" 2>/dev/null || true)"
      [ -n "''${w:-}" ] || continue
      [ "$w" -gt 0 ] 2>/dev/null || continue
      cmd="$(tr '\0' ' ' < "$pid/cmdline" 2>/dev/null | cut -c1-180 || true)"
      if [ -z "$cmd" ]; then
        cmd="[$(cat "$pid/comm" 2>/dev/null || echo unknown)]"
      fi
      # Escape tabs/newlines in cmd for TSV
      cmd="$(printf '%s' "$cmd" | tr '\t\n' '  ')"
      printf '%s\t%s\t%s\n' "''${pid#/proc/}" "$w" "$cmd" >> "$cur"
    done

    # Device writes from diskstats (512-byte sectors).
    : > "$disk_cur"
    awk '$3 ~ /^(nvme[0-9]+n[0-9]+|sd[a-z]+|dm-[0-9]+)$/ {
      printf "%s\t%s\t%s\n", $3, $10, $6
    }' /proc/diskstats > "$disk_cur"

    {
      echo "=== $ts ==="

      echo "-- devices (MB written this interval) --"
      if [ -f "$disk_prev" ]; then
        awk -F '\t' '
          FNR==NR { pw[$1]=$2; pr[$1]=$3; next }
          {
            dw=($2-pw[$1])*512/1048576
            dr=($3-pr[$1])*512/1048576
            if (dw >= 1 || dr >= 1)
              printf "  %-12s  write %8.1f MB  read %8.1f MB\n", $1, dw, dr
          }
        ' "$disk_prev" "$disk_cur" | sort -k3 -nr
      else
        echo "  (first sample; baselines recorded)"
      fi

      echo "-- processes (MB write_bytes this interval, top ${toString cfg.topN}) --"
      if [ -f "$prev" ]; then
        awk -F '\t' -v top=${toString cfg.topN} -v min_mb=${toString cfg.minDeltaMB} '
          FNR==NR { pw[$1]=$2; next }
          {
            pid=$1; w=$2; $1=""; $2=""; sub(/^\t/, "");
            cmd=$0
            if (!(pid in pw)) next
            d=w-pw[pid]
            if (d < 0) next
            mb=d/1048576
            if (mb >= min_mb) printf "%.3f\t%s\t%s\n", mb, pid, cmd
          }
        ' "$prev" "$cur" | sort -t$'\t' -nr -k1 | head -n ${toString cfg.topN} | \
          awk -F '\t' '{ printf "  %8.1f MB  pid=%-7s  %s\n", $1, $2, $3 }'
      else
        echo "  (first sample; baselines recorded)"
      fi

      # Hot files worth watching for this machine's scoria workload.
      for f in ${lib.escapeShellArgs cfg.watchFiles}; do
        if [ -e "$f" ]; then
          sz="$(stat -c '%s' "$f" 2>/dev/null || echo 0)"
          mtime="$(stat -c '%y' "$f" 2>/dev/null || true)"
          awk -v s="$sz" -v f="$f" -v m="$mtime" \
            'BEGIN { printf "  watchfile  %8.1f MB  %s  mtime=%s\n", s/1048576, f, m }'
        fi
      done

      echo
    } >> "$log"

    mv -f "$cur" "$prev"
    mv -f "$disk_cur" "$disk_prev"

    # Retention
    find "$log_dir" -type f -name 'writes-*.log' -mtime +${toString cfg.retentionDays} -delete 2>/dev/null || true
  '';
in
{
  options.services.diskWriteWatch = {
    enable = lib.mkEnableOption "Log per-process and per-device disk write deltas for multi-day diagnosis";

    intervalSeconds = lib.mkOption {
      type = lib.types.int;
      default = 60;
      description = "Sampling interval in seconds.";
    };

    logDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/log/disk-write-watch";
    };

    stateDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/disk-write-watch";
    };

    topN = lib.mkOption {
      type = lib.types.int;
      default = 20;
    };

    minDeltaMB = lib.mkOption {
      type = lib.types.int;
      default = 1;
      description = "Only log processes that wrote at least this many MB in the interval.";
    };

    retentionDays = lib.mkOption {
      type = lib.types.int;
      default = 7;
    };

    watchFiles = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "/home/jarrett/code/ogc/scoria/.scoria-dev/obs/obs.db"
        "/home/jarrett/code/ogc/scoria/.scoria-dev/obs/obs.db-wal"
        "/home/jarrett/code/ogc/scoria/.scoria-dev/system/scoria.db"
      ];
      description = "Files whose size/mtime are annotated each sample.";
    };
  };

  config = lib.mkMerge [
    {
      # On by default: this module exists to diagnose disk problems.
      services.diskWriteWatch.enable = lib.mkDefault true;

      environment.systemPackages = with pkgs; [
        smartmontools
        nvme-cli
        iotop
        sysstat
        atop
      ];

      services.smartd = {
        enable = true;
        notifications.wall.enable = true;
      };
    }

    (lib.mkIf cfg.enable {
      systemd.tmpfiles.rules = [
        "d ${cfg.logDir} 0755 root root -"
        "d ${cfg.stateDir} 0755 root root -"
        "d /var/log/atop 0755 root root -"
      ];

      # Binary process/disk history. Browse: atop -r /var/log/atop/atop_YYYYMMDD
      # (press 'd' for disk sort). Interval matches diskWriteWatch.intervalSeconds.
      systemd.services.atop = {
        description = "Atop continuous system performance logger";
        after = [ "misc-os.slice" ];
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          Type = "simple";
          Environment = [ "LOGPATH=/var/log/atop" "INTERVAL=${toString cfg.intervalSeconds}" ];
          ExecStartPre = "${pkgs.coreutils}/bin/mkdir -p /var/log/atop";
          ExecStart = "${pkgs.writeShellScript "atop-logger" ''
            set -eu
            day="$(${pkgs.coreutils}/bin/date +%Y%m%d)"
            exec ${pkgs.atop}/bin/atop -w "/var/log/atop/atop_''${day}" -a "${toString cfg.intervalSeconds}"
          ''}";
          Restart = "on-failure";
          RestartSec = "30s";
          Nice = 10;
          IOSchedulingClass = "best-effort";
          IOSchedulingPriority = 7;
        };
      };

      # Rotate atop log daily at midnight-ish via calendar timer restart.
      systemd.services.atop-rotate = {
        description = "Rotate atop log file (restart atop for new day file)";
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${pkgs.systemd}/bin/systemctl restart atop.service";
        };
      };
      systemd.timers.atop-rotate = {
        description = "Daily atop log rotation";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = "*-*-* 00:00:30";
          Persistent = true;
          Unit = "atop-rotate.service";
        };
      };

      # Retention for atop raw logs
      systemd.services.atop-cleanup = {
        description = "Delete old atop logs";
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${pkgs.writeShellScript "atop-cleanup" ''
            set -eu
            ${pkgs.findutils}/bin/find /var/log/atop -type f -name 'atop_*' -mtime +${toString cfg.retentionDays} -delete
          ''}";
        };
      };
      systemd.timers.atop-cleanup = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = "daily";
          Persistent = true;
          Unit = "atop-cleanup.service";
        };
      };

      systemd.services.disk-write-watch = {
        description = "Sample per-process disk write_bytes deltas";
        serviceConfig = {
          Type = "oneshot";
          ExecStart = sampleScript;
          Nice = 10;
          IOSchedulingClass = "best-effort";
          IOSchedulingPriority = 7;
        };
      };

      systemd.timers.disk-write-watch = {
        description = "Periodic disk write attribution samples";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = "2min";
          OnUnitActiveSec = "${toString cfg.intervalSeconds}s";
          AccuracySec = "10s";
          Unit = "disk-write-watch.service";
        };
      };
    })
  ];
}
