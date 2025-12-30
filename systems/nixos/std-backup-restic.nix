{
  config,
  sops,
  nixpkgs,
  home-manager,
  ...
}:
let

  remoteRepoFile = config.sops.secrets.restic-remote-uri.path;
  remotePassFile = config.sops.secrets.restic-remote-secret.path;
  runitorPingKeyFile = config.sops.secrets.runitor-ping-key.path;

  resticRemote = nixpkgs.writeShellApplication {
    name = "restic-remote";
    runtimeInputs = [ nixpkgs.restic ];
    text = ''
      set -euo pipefail
      export RESTIC_REPOSITORY_FILE="${remoteRepoFile}"
      export RESTIC_PASSWORD_FILE="${remotePassFile}"
      export RESTIC_CACHE_DIR="/var/cache/restic-backups-remote"
      exec restic "$@"
    '';
  };

  reduRemote = nixpkgs.writeShellApplication {
    name = "redu-remote";
    runtimeInputs = [ nixpkgs.redu nixpkgs.restic ];
    text = ''
      set -euo pipefail
      export RESTIC_REPOSITORY_FILE="${remoteRepoFile}"
      export RESTIC_PASSWORD_FILE="${remotePassFile}"
      export RESTIC_CACHE_DIR="/var/cache/restic-backups-remote"
      exec redu "$@"
    '';
  };

in
{
  sops.age.keyFile = "/var/lib/sops-nix/keys.txt";
  sops.secrets.restic-remote-uri = {
    sopsFile = ../../secrets/host_nixos/restic.yaml;
    key = "remote_repo_uri";
  };

  sops.secrets.restic-remote-secret = {
    sopsFile = ../../secrets/host_nixos/restic.yaml;
    key = "remote_repo_secret";
  };

  sops.secrets.runitor-ping-key = {
    sopsFile = ../../secrets/host_nixos/restic.yaml;
    key = "runitor_ping_key";
  };
  environment.systemPackages = with nixpkgs; [
    restic
    redu
    runitor
    resticRemote
    reduRemote
  ];

  systemd.services.restic-remote-backup = {
    description = "Daily Restic backup, monitored by HC";
    serviceConfig = {
      Type = "oneshot";
      User = "root";
      PrivateTmp = true;
    };

    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];

    environment = {
      PING_KEY = "file:${runitorPingKeyFile}";
      HC_API_URL = "https://hc.pathul-dapneb.com/ping";
    };

    script =
      let
        inhibitCmd = "${nixpkgs.systemd}/bin/systemd-inhibit --mode=block --who=restic --what=sleep --why=\"Scheduled backup\"";
        runitorBackupCmd = "${nixpkgs.runitor}/bin/runitor -no-output-in-ping -slug nixos-backup --";
        runitorCheckCmd = "${nixpkgs.runitor}/bin/runitor -no-output-in-ping -slug nixos-backup-checksum --";
        resticBackupCmd = "${resticRemote}/bin/restic-remote backup /home/jarrett /etc/nixos";
        resticCheckCmd = "${resticRemote}/bin/restic-remote check --read-data-subset=5%";
      in
      ''
        ${inhibitCmd} ${runitorBackupCmd} ${resticBackupCmd} 
        ${inhibitCmd} ${runitorCheckCmd} ${resticCheckCmd}
      '';
  };

  systemd.timers.restic-remote-backup = {
    description = "Restic backup and check timer";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "20:00";
      # If a run was missed (e.g., machine was off or suspended), run ASAP after startup/resume
      Persistent = true;

      # Start the timer immediately when it’s activated (so it will check missed runs)
      # Not strictly required, but useful on first enable.
      Unit = "restic-remote-backup.service";
      AccuracySec = "1min";
    };
  };
}
