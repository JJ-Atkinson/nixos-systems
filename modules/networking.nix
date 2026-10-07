{lib, ...} : {
    networking.useDHCP = lib.mkDefault true;

    services.avahi = {
      enable = true;
      openFirewall = true;
      publish = {
        enable = true;
        userServices = true;
      };
    };

    networking.firewall = {
      allowedTCPPortRanges = [ { from = 17000; to = 17002; } ];
      allowedUDPPortRanges = [ { from = 17000; to = 17002; } ];
    };

    # Increase UDP buffer sizes for better performance with Syncthing/QUIC
    boot.kernel.sysctl = {
      "net.core.rmem_max" = 15000000;  # 15 MB receive buffer
      "net.core.wmem_max" = 15000000;  # 15 MB send buffer
    };
}
