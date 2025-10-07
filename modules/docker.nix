{

  virtualisation.docker.enable = true;
  virtualisation.podman.enable = true;
  # Required for containers under podman-compose to be able to talk to each other.
  virtualisation.podman.defaultNetwork.settings.dns_enabled = true;

}