{ ... }: {
  # Plan A's original override emitted full unit files at
  # systemd-cryptsetup@cryptbtrfs_{a,b}.service with no ExecStart, shadowing
  # the generator-produced units and freezing initrd pid 1. Reverted to a
  # no-op on 2026-05-22 to unblock boot. Re-implement degraded-boot tolerance
  # via `settings.crypttabExtraOpts = [ "nofail" "x-systemd.device-timeout=30s" ]`
  # on each LUKS entry in systems/nixos/disko.nix (canonical systemd path,
  # no unit-file shadowing).
}
