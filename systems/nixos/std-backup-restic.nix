{ config, sops, nixpkgs, home-manager, ... }:
let 

  remoteRepoFile = config.sops.secrets.restic-remote-uri.path;
  remotePassFile = config.sops.secrets.restic-remote-secret.path;

  resticRemote = nixpkgs.writeShellApplication {
    name = "restic-remote";
    runtimeInputs = [ nixpkgs.restic ];
    text = ''
      set -euo pipefail
      export RESTIC_REPOSITORY_FILE="${remoteRepoFile}"
      export RESTIC_PASSWORD_FILE="${remotePassFile}"
      exec restic "$@"
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

  environment.systemPackages = with nixpkgs; [ restic resticRemote];

  services.restic.backups = {
    remote_backup = {
      repositoryFile = remoteRepoFile;
      passwordFile = remotePassFile;
      initialize = true;
      paths = ["/home/jarrett"
               "/etc/nixos/"];
      inhibitsSleep = true;
      timerConfig = {
        OnCalendar = "20:00";
        Persistent = true;
      };
      checkOpts = ["--read-data-subset=10%"];
    };
  };
}