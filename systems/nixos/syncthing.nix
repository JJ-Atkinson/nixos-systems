{
  services.syncthing = {
    enable = true;
    openDefaultPorts = true;
    user = "jarrett";

    dataDir = "/home/jarrett/syncthing-datadir";
  };
}