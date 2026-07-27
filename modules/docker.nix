{ pkgs, ... }:

{

  virtualisation.docker.enable = true;
  virtualisation.docker.package = pkgs.docker_29;
  virtualisation.podman.enable = true;
  # Required for containers under podman-compose to be able to talk to each other.
  virtualisation.podman.defaultNetwork.settings.dns_enabled = true;

  networking.firewall.trustedInterfaces = [ "docker0" ];

}