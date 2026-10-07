{ config, lib, pkgs, ... }:
let
  cfg = config.programs.yubigpg;
  package = import ./yubigpg/package.nix {
    inherit lib pkgs;
    inherit (cfg) probeTimeout;
    agentConfigFile = if cfg.enable then config.environment.etc."gnupg/gpg-agent.conf".source else null;
  };
in
{
  options.programs.yubigpg = {
    enable = lib.mkEnableOption "receiver-side local/forwarded GPG socket selection (see docs/yubigpg.md)";
    probeTimeout = lib.mkOption {
      type = lib.types.ints.positive;
      default = 3;
      description = "Socket probe timeout in seconds; does not limit signing or PIN entry.";
    };
    package = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      default = package;
      description = "Receiver-side socket selector, with build-time ordinary-GPG integration tests.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ cfg.package ];
    programs.gnupg.agent = {
      enable = true;
      enableExtraSocket = true;
      enableSSHSupport = true;
      # The watchdog probes the canonical S.gpg-agent, not the pathname of
      # the inherited std descriptor. That path intentionally selects another
      # agent in fwd mode, so systemd must supervise this local agent instead.
      # NixOS's key/value renderer emits booleans as literal arguments. An
      # empty string renders a bare flag (with harmless trailing whitespace).
      settings.disable-check-own-socket = "";
    };

    # Keep the local agent on its own stable std descriptor.
    systemd.user.sockets.gpg-agent = {
      socketConfig.ListenStream = lib.mkForce "%t/gnupg/S.gpg-agent.local";
      requires = [ "yubigpg-router.service" ];
      after = [ "yubigpg-router.service" ];
    };
    systemd.user.services.gpg-agent = {
      requires = [ "gpg-agent.socket" ];
      after = [ "gpg-agent.socket" ];
      # Reload the LOCAL agent, never the agent selected by the canonical route.
      serviceConfig.ExecReload = lib.mkForce (
        "${pkgs.gnupg}/bin/gpg-connect-agent --no-autostart "
        + "--raw-socket %t/gnupg/S.gpg-agent.local RELOADAGENT /bye"
      );
    };

    # Replace the GnuPG module's tty-update hook. Its default command follows
    # the selected canonical socket and AUTOSTARTS an unsupervised agent when
    # a forward is down. gpg.conf does not apply to gpg-connect-agent.
    # This repository has no other system-wide programs.ssh.extraConfig blocks;
    # user ~/.ssh/config host entries are independent of this setting.
    programs.ssh.extraConfig = lib.mkForce cfg.package.sshConfig;
    systemd.user.services.yubigpg-router = {
      description = "Restore the manually selected GnuPG socket route";
      wantedBy = [ "sockets.target" ];
      before = [ "gpg-agent.socket" "sockets.target" ];
      # Avoid basic.target -> sockets.target -> router -> basic.target ordering.
      unitConfig.DefaultDependencies = false;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${cfg.package}/bin/yubigpg init";
      };
    };

    # Ordinary clients must not spawn an agent and steal the selector symlink
    # when the fwd endpoint is absent. Local socket activation still works.
    # Do NOT put this in common.conf: that also disables supervised gpg-agent.
    environment.etc."gnupg/gpg.conf".text = "no-autostart\n";
    environment.etc."gnupg/gpgsm.conf".text = "no-autostart\n";

    # Plain ssh cannot run receiver preparation before requesting its forwards.
    # OpenSSH handles stale forwarding sockets; multiplexing shares live ones.
    services.openssh.settings.StreamLocalBindUnlink = lib.mkDefault true;
  };
}
