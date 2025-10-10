{nixpkgs, sops, config, lib, ...} : 

{
  sops.age.keyFile = "/var/lib/sops-nix/keys.txt";
  sops.secrets.pgadmin-password = {
    sopsFile = ../secrets/host_nixos/pgadmin.yaml;
    key = "password";
  };

  services.postgresql.package = nixpkgs.postgresql_17;

  services.pgadmin = {
    enable = true;
    openFirewall = false;
    package = nixpkgs.pgadmin4;

    initialEmail = "local@user.com";
    initialPasswordFile = config.sops.secrets.pgadmin-password.path;
  };
}