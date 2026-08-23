{ pkgs, lib, ... }:

# Foreground public exposure of a local dev port, behind a per-run password.
#
# Topology:
#
#   dev1.pathul-dapneb.com ──┐
#                            ├─ NPM (bastion-host, 100.95.181.21, public Linode)
#   dev2.pathul-dapneb.com ──┘        │
#                                     │ tailscale (direct WireGuard)
#                                     ▼
#                   nixos-1:48001 / :48002 ── gate ──▶ 127.0.0.1:<local-port>
#
# `gate` is share-public-gate (./gate), an authenticating reverse proxy: it
# forwards nothing until the client presents a magic-link token or the
# three-word password printed when the run starts. Both secrets are generated
# per run and exist only in that process. See ./gate/main.go.
#
# These two ports are effectively internet-facing, because the bastion in front
# of them is. So they are DROPped by default and only opened for the duration of
# a `share-public` invocation, scoped to the bastion's tailnet address alone.
#
# Four layers, deliberately:
#
#   1. Tailnet ACL  — a single STATIC grant (bastion-host -> nixos-host on
#      48001,48002) that lives in the policy file and is never touched by this
#      module. Tailscale exposes no per-grant toggle, so automating it would
#      mean rewriting the whole policy document on every invocation. Not worth
#      the blast radius.
#   2. iptables     — the actual toggle. Instant, local, no network round trip,
#      so the close path cannot fail due to an unreachable API.
#   3. gate         — only listens while the command runs. If a rule ever leaks,
#      there is still nothing behind the port.
#   4. auth         — and if the port is somehow reached anyway, a client still
#      needs a secret that was never written to disk.
#
# Manual one-time setup this module does NOT do:
#   - Add the ACL grant above in the Tailscale admin console.
#   - Create the two NPM proxy hosts -> http://100.66.217.33:4800{1,2}.
#     Turn Cache Assets OFF (NPM has previously cached a pre-login 403 as
#     webawesome.js and MIME-blocked the module).
#     Turn Websockets Support ON, or HMR and any app websocket dies at the
#     bastion before it ever reaches the gate.

let
  # NPM Linode. `bastion-host` in the tailnet policy file.
  bastionIp = "100.95.181.21";

  # This machine's tailnet address. The gate binds here explicitly so the
  # listener is never reachable from the LAN or any physical NIC.
  tailnetIp = "100.66.217.33";

  slots = {
    dev1 = { port = 48001; host = "dev1.pathul-dapneb.com"; };
    dev2 = { port = 48002; host = "dev2.pathul-dapneb.com"; };
  };

  publicPorts = lib.mapAttrsToList (_: s: s.port) slots;

  gate = pkgs.buildGoModule {
    pname = "share-public-gate";
    version = "1.0";
    src = ./gate;
    vendorHash = null; # stdlib only, deliberately — nothing to vendor.
  };

  # Kept identical between the standing DROP, the toggle, and the boot-time
  # sweep, so a rule inserted by one is always deletable by another.
  dropRule = port:
    "-i tailscale0 -p tcp --dport ${toString port} -j DROP";

  # `tailscale0` is in networking.firewall.trustedInterfaces, which appends a
  # blanket ACCEPT to nixos-fw. Inserting at position 1 puts these DROPs ahead
  # of it; the toggle then inserts its ACCEPT ahead of the DROP.
  standingDrops = lib.concatMapStringsSep "\n"
    (port: "iptables -I nixos-fw 1 ${dropRule port}")
    publicPorts;

  stopDrops = lib.concatMapStringsSep "\n"
    (port: "iptables -D nixos-fw ${dropRule port} || true")
    publicPorts;

  # Where a live run records its owning PID. /run is tmpfs, so a stale pidfile
  # can never survive a reboot and be mistaken for a live session.
  runDir = "/run/share-public";

  # The sweep. Runs at boot AND every 10 minutes, so a leaked opening is closed
  # without waiting for a reboot.
  #
  # It must not close a port out from under a legitimate share, so it cannot
  # simply delete every ACCEPT it finds. Nor can it infer liveness from "is
  # something listening" — SIGKILLing the script orphans the gate, which keeps
  # the port bound. Instead each run records its PID, and the sweep treats an
  # opening as leaked only when that owner is provably gone. The PID is
  # cross-checked against /proc/<pid>/cmdline so a recycled PID cannot keep a
  # dead session's rule alive.
  clearAcceptsScript = ''
    run_dir=${runDir}

    sweep_port() {
      port="$1"

      if ! iptables -C nixos-fw -i tailscale0 -s ${bastionIp} -p tcp --dport "$port" -j ACCEPT 2>/dev/null; then
        return 0
      fi

      pidfile="$run_dir/$port.pid"
      if [ -r "$pidfile" ]; then
        pid=$(cat "$pidfile" 2>/dev/null || true)
        if [ -n "$pid" ] \
           && kill -0 "$pid" 2>/dev/null \
           && grep -qa share-public "/proc/$pid/cmdline" 2>/dev/null; then
          # Live, owned session. Leave it alone.
          return 0
        fi
      fi

      echo "share-public-reset: closing leaked opening on port $port"
      while iptables -C nixos-fw -i tailscale0 -s ${bastionIp} -p tcp --dport "$port" -j ACCEPT 2>/dev/null; do
        iptables -D nixos-fw -i tailscale0 -s ${bastionIp} -p tcp --dport "$port" -j ACCEPT
      done
      rm -f "$pidfile"

      # An orphaned gate from a hard-killed run would otherwise keep serving on
      # the tailnet even after the rule is gone. `-listen` is passed last by the
      # wrapper precisely so this pattern can anchor on the end of the cmdline.
      pkill -f "share-public-gate .*-listen [0-9.]*:$port\$" || true
    }

    ${lib.concatMapStringsSep "\n" (port: "sweep_port ${toString port}") publicPorts}
  '';

  sharePublic = pkgs.writeShellApplication {
    name = "share-public";
    runtimeInputs = [ pkgs.iptables pkgs.iproute2 gate ];
    text = ''
      usage() {
        # Explicit `--help` prints to stdout and exits 0; a usage ERROR prints to
        # stderr and exits 64. Same text either way.
        code="''${1:-64}"
        out=2
        if [ "$code" -eq 0 ]; then out=1; fi
        cat >&"$out" <<'EOF'
      share-public — expose a local port through the public bastion, in foreground.

        sudo share-public [options] <dev1|dev2> <local-port|localhost-url>

      Serves a local server at https://<slot>.pathul-dapneb.com for as long as
      this command runs. Ctrl-C, SIGTERM, SIGHUP (closing the terminal) or a
      normal exit all shut the firewall and drop the listener.

      Options:
        --allow-path-nogate <prefix>
            Serve everything under <prefix> WITHOUT authentication — no magic
            link, no password, no cookie, no redirect. GET/HEAD only, so it can
            never open an unauthenticated write onto the local app. Repeatable.

            For endpoints a third party must fetch while holding none of this
            run's secrets: OIDC/OAuth discovery and JWKS, .well-known probes,
            webhook verification callbacks. A relying party fetching
            /.well-known/oidc.json carries no per-run token, so the normal
            magic-link path (302 + cookie) bounces it to the login screen; this
            hands it the JSON straight, 200.

            Matching is by path segment: --allow-path-nogate /.well-known
            covers /.well-known and /.well-known/oidc.json but never
            /.well-known-evil. Everything OUTSIDE the listed prefixes still needs
            a secret as before. Only expose paths whose bodies are meant to be
            public — anyone who can reach the bastion can read them.

            e.g.  sudo share-public --allow-path-nogate /.well-known dev1 5173

      Given a localhost URL instead of a bare port, the path is carried over and
      the public URL is printed back rewritten:

        sudo share-public dev1 5173
        sudo share-public dev1 http://localhost:5173/admin?debug=1
          -> https://dev1.pathul-dapneb.com/admin?debug=1

      The same rewrite is available WHILE the share runs: paste a localhost URL
      into this terminal and its public, magic-link form is printed back. That
      is usually what you want, since the URL worth sharing is one you navigate
      to after the share is already up.

      Nothing is forwarded until the client authenticates, by either:

        magic link — the printed URL carries a one-run token, which is swapped
                     for a cookie and stripped from the address bar on arrival.
        password   — a three-word phrase, also printed, entered on a bare login
                     screen served at any path.

      Both are generated fresh per run and never stored. Failed attempts are
      rate limited to one per 5s per client and logged to this console.

      SIGKILL (kill -9), a panic or a power cut skip the cleanup and leave the
      port open. It is closed again by the next run of this command, by
      `sudo systemctl restart share-public-reset`, or at the next boot.

      Slots:
        dev1 -> public port 48001 -> https://dev1.pathul-dapneb.com
        dev2 -> public port 48002 -> https://dev2.pathul-dapneb.com
      EOF
        exit "$code"
      }

      # Options may precede or follow the two positionals. Each
      # --allow-path-nogate becomes a -nogate-path passed through to the gate;
      # the flag is repeatable, so the args accumulate in an array.
      nogate_args=()
      positional=()
      while [ "$#" -gt 0 ]; do
        case "$1" in
          -h|--help|help) usage 0 ;;
          --allow-path-nogate)
            [ "$#" -ge 2 ] || { echo "share-public: --allow-path-nogate needs a path" >&2; usage; }
            case "$2" in
              /*) ;;
              *) echo "share-public: --allow-path-nogate wants an absolute path, got '$2'" >&2; usage ;;
            esac
            nogate_args+=(-nogate-path "$2")
            shift 2
            ;;
          --allow-path-nogate=*)
            val="''${1#*=}"
            case "$val" in
              /*) ;;
              *) echo "share-public: --allow-path-nogate wants an absolute path, got '$val'" >&2; usage ;;
            esac
            nogate_args+=(-nogate-path "$val")
            shift
            ;;
          --) shift; while [ "$#" -gt 0 ]; do positional+=("$1"); shift; done ;;
          -*) echo "share-public: unknown option '$1'" >&2; usage ;;
          *) positional+=("$1"); shift ;;
        esac
      done
      set -- "''${positional[@]+"''${positional[@]}"}"

      [ "$#" -eq 2 ] || usage 64

      slot="$1"
      target="$2"

      case "$slot" in
        dev1) public_port=48001; public_host="dev1.pathul-dapneb.com" ;;
        dev2) public_port=48002; public_host="dev2.pathul-dapneb.com" ;;
        *)    echo "share-public: unknown slot '$slot'" >&2; usage ;;
      esac

      # A bare number is a port. Anything else is read as a URL, so a value
      # pasted straight out of the address bar works — and comes back rewritten
      # to its public form rather than leaving you to reassemble it by hand.
      path="/"
      case "$target" in
        *[!0-9]*)
          rest="''${target#*://}"
          hostport="''${rest%%/*}"
          case "$rest" in
            */*) path="/''${rest#*/}" ;;
          esac

          case "$hostport" in
            \[*\]*)  # bracketed IPv6, e.g. [::1]:5173
              host="''${hostport%%\]*}]"
              local_port="''${hostport##*\]:}"
              ;;
            *)
              host="''${hostport%%:*}"
              local_port="''${hostport##*:}"
              ;;
          esac

          if [ "$local_port" = "$hostport" ]; then
            echo "share-public: URL needs an explicit port, e.g. http://localhost:5173/" >&2
            exit 64
          fi

          # Only loopback: this forwards a port that is already yours, it is not
          # a general proxy onto the LAN.
          case "$host" in
            localhost|127.0.0.1|0.0.0.0|"[::1]") ;;
            *)
              echo "share-public: only localhost URLs can be shared (got '$host')" >&2
              exit 64
              ;;
          esac
          ;;
        *)
          local_port="$target"
          ;;
      esac

      case "$local_port" in
        ""|*[!0-9]*) echo "share-public: local port must be numeric" >&2; usage ;;
      esac
      if [ "$local_port" -lt 1 ] || [ "$local_port" -gt 65535 ]; then
        echo "share-public: local port out of range" >&2
        exit 64
      fi

      if [ "$(id -u)" -ne 0 ]; then
        echo "share-public: must run as root (it edits the firewall). Use sudo." >&2
        exit 1
      fi

      accept_rule=(-i tailscale0 -s ${bastionIp} -p tcp --dport "$public_port" -j ACCEPT)

      close_firewall() {
        # Idempotent, and removes duplicates left by an earlier hard kill.
        while iptables -C nixos-fw "''${accept_rule[@]}" 2>/dev/null; do
          iptables -D nixos-fw "''${accept_rule[@]}"
        done
      }

      cleanup() {
        # Order matters on the way out: kill the listener and shut the firewall
        # before anything that could block. Never let a failure here escape.
        trap - EXIT INT TERM HUP

        if [ -n "''${gate_pid:-}" ] && kill -0 "$gate_pid" 2>/dev/null; then
          kill "$gate_pid" 2>/dev/null || true
          wait "$gate_pid" 2>/dev/null || true
        fi

        close_firewall || true
        rm -f "''${pidfile:-}"
        echo ""
        echo "share-public: closed $public_host (port $public_port dropped)"
      }

      # Warn but do not refuse: the target may be starting up alongside this.
      if ! ss -Hltn "sport = :$local_port" | grep -q .; then
        echo "share-public: warning — nothing is listening on 127.0.0.1:$local_port" >&2
      fi

      # Clear anything a previous hard kill left behind before opening.
      close_firewall

      # Claim ownership BEFORE the rule exists, so the periodic sweep can never
      # observe an opening with no pidfile and wrongly judge it leaked.
      mkdir -p ${runDir}
      pidfile="${runDir}/$public_port.pid"
      echo "$$" > "$pidfile"

      trap cleanup EXIT INT TERM HUP

      iptables -I nixos-fw 1 "''${accept_rule[@]}"

      # The gate prints the banner itself, once its socket is actually up, so
      # the URL handed back is never a promise the listener has not kept. Keep
      # -listen last: the leak sweep's pkill pattern anchors on it.
      #
      # `<&3` is load-bearing. With job control off, bash points an async
      # command's stdin at /dev/null unless it is redirected explicitly, which
      # silently costs the gate the pasted-URL prompt. Backgrounding itself is
      # also load-bearing: a foreground child would defer the cleanup traps
      # until it exited, so a `kill -TERM` at the script would leave the
      # firewall open until the gate happened to die on its own.
      exec 3<&0
      share-public-gate \
        -target "127.0.0.1:$local_port" \
        -public-host "$public_host" \
        -path "$path" \
        -bastion ${bastionIp} \
        ''${nogate_args[@]+"''${nogate_args[@]}"} \
        -listen ${tailnetIp}:"$public_port" <&3 &
      gate_pid=$!

      wait "$gate_pid"
    '';
  };
in
{
  environment.systemPackages = [ sharePublic ];

  networking.firewall.extraCommands = standingDrops;
  networking.firewall.extraStopCommands = stopDrops;

  # A crashed or SIGKILLed run leaves an ACCEPT behind that its own trap never
  # got to remove. Sweep at boot (so closed is the guaranteed default) and every
  # 10 minutes thereafter (so a leak does not sit open until the next reboot).
  #
  # Deliberately NOT RemainAfterExit: a oneshot that stays `active` cannot be
  # re-triggered by a timer — every firing would be a no-op.
  systemd.services.share-public-reset = {
    description = "Close leaked share-public firewall openings";
    wantedBy = [ "multi-user.target" ];
    after = [ "firewall.service" ];
    serviceConfig.Type = "oneshot";
    path = [ pkgs.iptables pkgs.procps ];
    script = clearAcceptsScript;
  };

  systemd.timers.share-public-reset = {
    description = "Periodically close leaked share-public firewall openings";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "2min";
      OnUnitActiveSec = "10min";
      # A missed window (suspend, downtime) sweeps promptly on resume rather
      # than silently waiting out the next full interval.
      Persistent = true;
      AccuracySec = "30s";
    };
  };

  security.sudo.extraRules = [{
    groups = [ "wheel" ];
    commands = [{
      command = "${sharePublic}/bin/share-public";
      options = [ "NOPASSWD" ];
    }];
  }];
}
