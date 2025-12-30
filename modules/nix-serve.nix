{config, pkgs, lib, ...}: {
  # Binary cache server for local network
  services.nix-serve = {
    enable = true;
    port = 5000;
    secretKeyFile = "/var/cache-priv-key.pem";
    # Bind to all interfaces so LAN devices can access it
    bindAddress = "0.0.0.0";
  };

  # Open firewall for local network (adjust if you want to restrict to specific IPs)
  networking.firewall.allowedTCPPorts = [ 5000 ];

  # Optional: Generate keys automatically on first boot
  systemd.services.nix-serve-keys = {
    description = "Generate nix-serve signing keys";
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      if [ ! -f /var/cache-priv-key.pem ]; then
        ${pkgs.nix}/bin/nix-store --generate-binary-cache-key nixos-cache-1 /var/cache-priv-key.pem /var/cache-pub-key.pem
        chmod 600 /var/cache-priv-key.pem
        chmod 644 /var/cache-pub-key.pem
      fi
    '';
  };
}
