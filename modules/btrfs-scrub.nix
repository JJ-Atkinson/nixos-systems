{ config, lib, pkgs, ... }:

let
  cfg = config.services.btrfsScrubNotifier;

  notifyUsers = lib.escapeShellArgs cfg.notifyUsers;

  notifyScript = pkgs.writeShellScript "btrfs-scrub-notify-users" ''
    set -u

    title="$1"
    body="$2"
    urgency="''${3:-critical}"

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
            --app-name="btrfs scrub" \
            --urgency="$urgency" \
            "$title" \
            "$body" || true
    done
  '';

  stateDir = "/var/lib/btrfs-scrub-notifier";

  checkScript = pkgs.writeShellScript "btrfs-scrub-check" ''
    set -u

    mountpoint="$1"
    unit_hint="''${2:-}"

    # slug: turn mountpoint into a flat filename ("/" -> "root", "/a/b" -> "a_b")
    slug="$(printf '%s' "$mountpoint" | ${pkgs.gnused}/bin/sed 's|^/||; s|/|_|g')"
    [ -z "$slug" ] && slug=root

    state_dir=${lib.escapeShellArg stateDir}
    state_file="$state_dir/$slug.stats"
    ${pkgs.coreutils}/bin/mkdir -p "$state_dir"

    service_result="''${SERVICE_RESULT:-success}"
    exit_status="''${EXIT_STATUS:-0}"

    # --- per-run scrub counters (this run's findings) ---
    scrub_output="$(${pkgs.btrfs-progs}/bin/btrfs scrub status -R "$mountpoint" 2>&1 || true)"
    scrub_nonzero="$(printf '%s\n' "$scrub_output" | ${pkgs.gawk}/bin/awk '
      /[a-z_]+_errors:[[:space:]]+[0-9]+/ {
        n = $NF + 0
        if (n > 0) print "  " $0
      }
    ')"

    # --- cumulative device stats (growth since last run) ---
    stats_output="$(${pkgs.btrfs-progs}/bin/btrfs device stats "$mountpoint" 2>&1 || true)"
    stats_current="$(printf '%s\n' "$stats_output" | ${pkgs.gawk}/bin/awk '
      /^\[.*\]\..*[[:space:]]+[0-9]+$/ { print $1, $NF }
    ')"

    stats_deltas=""
    if [ -f "$state_file" ]; then
      stats_deltas="$(${pkgs.gawk}/bin/awk '
        NR == FNR { prev[$1] = $2 + 0; next }
        {
          cur = $2 + 0
          old = prev[$1] + 0
          if (cur > old) printf "  %s: %d (was %d, +%d)\n", $1, cur, old, cur - old
        }
      ' "$state_file" <(printf '%s\n' "$stats_current"))"
    fi

    # update baseline
    printf '%s\n' "$stats_current" > "$state_file"

    failed=0
    if [ "$service_result" != "success" ] || [ "$exit_status" != "0" ]; then
      failed=1
    fi

    if [ -z "$scrub_nonzero" ] && [ -z "$stats_deltas" ] && [ "$failed" = "0" ]; then
      ${pkgs.coreutils}/bin/echo "btrfs-scrub-check: $mountpoint clean (baseline updated at $state_file)" >&2
      exit 0
    fi

    body="Mountpoint: $mountpoint"
    if [ "$failed" = "1" ]; then
      body="$body
    Unit result: $service_result (exit $exit_status)"
    fi
    if [ -n "$scrub_nonzero" ]; then
      body="$body
    Scrub-run counters (this run):
    $scrub_nonzero"
    fi
    if [ -n "$stats_deltas" ]; then
      body="$body
    Device stats grew since last run:
    $stats_deltas"
    fi
    if [ -n "$unit_hint" ]; then
      body="$body
    Run: journalctl -u $unit_hint"
    fi

    ${notifyScript} \
      "btrfs scrub: errors on $mountpoint" \
      "$body" \
      critical
  '';
in
{
  options.services.btrfsScrubNotifier = {
    notifyUsers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Users whose active desktop sessions receive critical btrfs scrub error notifications.";
    };
  };

  config = {
    services.btrfs.autoScrub = {
      enable = true;
      interval = "weekly";
      fileSystems = [
        "/"  # Main system btrfs (all subvolumes)
        "/vm-storage/images"  # VM storage btrfs (checks integrity of qcow2 files)
      ];
    };

    # Stagger the vm-storage scrub so the two filesystems are not scrubbed
    # concurrently. Concurrent scrub on Mon 00:00 correlated with a hard freeze
    # on 2026-05-18 (vm-storage on a WD_BLACK SN7100 with btrfs corruption_errs).
    systemd.timers."btrfs-scrub-vm\\x2dstorage-images" = {
      timerConfig.OnCalendar = lib.mkForce "Mon *-*-* 03:00:00";
    };

    # Root drive (nvme0n1, WD_BLACK SN7100) is showing media errors and is
    # pending RMA replacement. Scrub daily until replaced to surface new
    # uncorrectable errors quickly.
    systemd.timers."btrfs-scrub--" = {
      timerConfig.OnCalendar = lib.mkForce "*-*-* 00:00:00";
    };

    systemd.services."btrfs-scrub--" = {
      serviceConfig.ExecStopPost = [
        "${checkScript} / btrfs-scrub--.service"
      ];
    };

    systemd.services."btrfs-scrub-vm\\x2dstorage-images" = {
      serviceConfig.ExecStopPost = [
        "${checkScript} /vm-storage/images btrfs-scrub-vm\\x2dstorage-images.service"
      ];
    };
  };
}
