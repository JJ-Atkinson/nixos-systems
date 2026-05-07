{ pkgs, ... }:

let
  vmCpus = "2-13";
  hostCpus = "0,1,14-27";

  # Match host-side IRQs observed interrupting VM CPUs. vfio IRQs are
  # intentionally excluded because those belong to the passed-through GPU path.
  hostIrqPattern = "(amdgpu|xhci_hcd|enp8s0|enp0s31f6|snd_hda_intel|nvme2q0)";

  irqAffinityScript = pkgs.writeShellScriptBin "looking-glass-irq-affinity" ''
    set -euo pipefail

    host_cpus=${hostCpus}
    pattern='${hostIrqPattern}'

    usage() {
      printf 'Usage: %s {apply|status}\n' "$0" >&2
    }

    matching_irqs() {
      ${pkgs.gawk}/bin/awk -v pattern="$pattern" '
        $0 ~ pattern && $0 !~ /vfio/ {
          irq = $1
          sub(/:/, "", irq)
          print irq
        }
      ' /proc/interrupts
    }

    status() {
      matching_irqs | while read -r irq; do
        [ -n "$irq" ] || continue
        printf '%s ' "$irq"
        tr -d '\n' < "/proc/irq/$irq/smp_affinity_list"
        printf ' '
        ${pkgs.gnugrep}/bin/grep -E "^[[:space:]]*$irq:" /proc/interrupts || true
      done
    }

    apply() {
      if [ "$(id -u)" -ne 0 ]; then
        printf 'looking-glass-irq-affinity apply must run as root.\n' >&2
        exit 1
      fi

      matching_irqs | while read -r irq; do
        [ -n "$irq" ] || continue
        if ! printf '%s' "$host_cpus" > "/proc/irq/$irq/smp_affinity_list" 2>/dev/null; then
          printf 'skipped IRQ %s: kernel rejected affinity change\n' "$irq" >&2
        fi
      done

      status
    }

    case "''${1:-}" in
      apply) apply ;;
      status) status ;;
      *) usage; exit 2 ;;
    esac
  '';

  clientScript = pkgs.writeShellScriptBin "looking-glass-client-tuned" ''
    exec ${pkgs.util-linux}/bin/taskset -c ${hostCpus} ${pkgs.looking-glass-client}/bin/looking-glass-client "$@"
  '';
in
{
  nixpkgs.overlays = [
    (final: prev: {
      looking-glass-client = prev.looking-glass-client.overrideAttrs (old: {
        patches = (old.patches or [ ]) ++ [ ./../patches/looking-glass-b7-graph-imgui-id.patch ];
      });
    })
  ];

  # Runtime pinning alone cannot move managed MSI-X vectors. This boot-time hint
  # tells drivers to avoid VM CPUs for managed IRQs when housekeeping CPUs exist.
  boot.kernelParams = [ "isolcpus=managed_irq,${vmCpus}" ];

  environment.systemPackages = [
    clientScript
    irqAffinityScript
  ];

  systemd.services.looking-glass-irq-affinity = {
    description = "Keep selected host IRQs off Windows VM CPUs for Looking Glass";
    wantedBy = [ "multi-user.target" ];
    after = [ "sysinit.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${irqAffinityScript}/bin/looking-glass-irq-affinity apply";
      RemainAfterExit = true;
    };
  };
}
