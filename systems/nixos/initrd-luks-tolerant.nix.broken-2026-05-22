{ lib, ... }:
{
  # Degraded-boot guard. Without this, systemd-cryptsetup@cryptbtrfs_<x>.service
  # waits the default ~90 s on its source .device unit when a disk is missing,
  # then fails — and depending on target dependencies may drop the system to
  # emergency shell. Capping the job timeout and clearing OnFailure lets the
  # btrfs `degraded` mount on the surviving leg take over.
  #
  # Verified by the A.5 failure drill: if the drill still hits emergency shell,
  # tighten cryptsetup.target dependencies here (it currently Wants= members in
  # NixOS, not Requires=, so one failure should not fail the target).
  boot.initrd.systemd.services."systemd-cryptsetup@cryptbtrfs_a" = {
    unitConfig.JobTimeoutSec = "30s";
    unitConfig.OnFailure = lib.mkForce [ ];
  };
  boot.initrd.systemd.services."systemd-cryptsetup@cryptbtrfs_b" = {
    unitConfig.JobTimeoutSec = "30s";
    unitConfig.OnFailure = lib.mkForce [ ];
  };
}
