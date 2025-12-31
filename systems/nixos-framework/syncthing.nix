{
  services.syncthing = {
    enable = true;
    openDefaultPorts = true;
    user = "jarrett";

    dataDir = "/home/jarrett/syncthing-datadir";

    settings.options = {
      # Don't limit bandwidth on LAN connections
      limitBandwidthInLan = false;

      # Allow more folders to sync concurrently (0 = unlimited)
      maxFolderConcurrency = 0;
    };
  };
}