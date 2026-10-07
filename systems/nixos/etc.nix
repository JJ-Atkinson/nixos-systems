{ lib, pkgs, ... }:
let
  skipFleet = _: { unitConfig.ConditionUser = "!koil-fleet"; };
in
{
  networking.hostName = "nixos";

  # Host-local identity: keep these IDs stable while rootless Podman data exists.
  users.groups.koil-fleet.gid = 1200;
  users.groups.koil-fleet-operators.members = [ "jarrett" "koil-fleet" ];
  users.users.koil-fleet = {
    isNormalUser = true;
    uid = 1200;
    group = "koil-fleet";
    home = "/home/koil-fleet";
    createHome = true;
    homeMode = "0700";
    hashedPassword = "!";
    openssh.authorizedKeys.keys = [ ];
    extraGroups = [ ];
    subUidRanges = [ { startUid = 851968; count = 65536; } ];
    subGidRanges = [ { startGid = 917504; count = 65536; } ];
    linger = true;
  };
  users.manageLingering = true;

  # Only fleet operators can traverse this stable socket directory.
  systemd.tmpfiles.rules = [
    "d /run/koil-fleet 0750 koil-fleet koil-fleet-operators -"
  ];

  # Host-wide desktop and VU user units are for the interactive user, not the
  # lingering fleet manager. Leave D-Bus and NixOS activation available.
  systemd.user.services = (lib.genAttrs [
    "vu-server" "vu-driver-pack" "vu-driver-restart" "vu-driver-resume"
    "gcr-ssh-agent" "pipewire" "pipewire-pulse" "wireplumber"
    "podman"
  ] skipFleet) // {
    koil-fleet-podman = {
      # Rootless Podman needs the setuid subordinate-ID helpers on its PATH.
      path = [ "/run/wrappers" ];
      unitConfig = {
        ConditionUser = "koil-fleet";
        Requires = "koil-fleet-podman.socket";
        After = "koil-fleet-podman.socket";
      };
      serviceConfig = {
        Type = "exec";
        ExecStart = "${pkgs.podman}/bin/podman system service";
        Delegate = true;
        KillMode = "process";
      };
    };
  };
  systemd.user.sockets = (lib.genAttrs [
    "gcr-ssh-agent" "gpg-agent" "gpg-agent-ssh"
    "pipewire" "pipewire-pulse" "speech-dispatcher" "podman"
  ] skipFleet) // {
    koil-fleet-podman = {
      unitConfig.ConditionUser = "koil-fleet";
      wantedBy = [ "sockets.target" ];
      socketConfig = {
        ListenStream = "/run/koil-fleet/podman.sock";
        SocketMode = "0660";
        SocketGroup = "koil-fleet-operators";
        Service = "koil-fleet-podman.service";
      };
    };
  };
  systemd.user.timers = lib.genAttrs [ "vu-driver-restart" ] skipFleet;

}
