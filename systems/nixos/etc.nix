{
  networking.hostName = "nixos";

  # Trust mitmproxy CA certificate for debugging HTTP/HTTPS traffic
  security.pki.certificateFiles = [
    ../../certs/nixos-mitmproxy-ca-cert.pem
  ];
}