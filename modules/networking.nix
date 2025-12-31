{lib, ...} : {
    networking.useDHCP = lib.mkDefault true;

    # Increase UDP buffer sizes for better performance with Syncthing/QUIC
    boot.kernel.sysctl = {
      "net.core.rmem_max" = 15000000;  # 15 MB receive buffer
      "net.core.wmem_max" = 15000000;  # 15 MB send buffer
    };
}