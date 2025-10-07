{nixpkgs, config, ...}:

{
  environment.systemPackages = [ nixpkgs.tailscale ];
  services.tailscale.enable = true;

  networking.firewall = {
    enable = true;


    # always allow traffic from your Tailscale network
    trustedInterfaces = [ "tailscale0" ];

    # allow the Tailscale UDP port through the firewall
    allowedUDPPorts = [ config.services.tailscale.port ];

    # let you SSH in over the public internet
    allowedTCPPorts = [ 22 ];
  };
}