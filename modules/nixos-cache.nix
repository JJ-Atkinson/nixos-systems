{lib, config, pkgs, ...}: {
  # Configure nixos-cache as a binary cache substituter
  # No additional trust needed - it proxies cache.nixos.org with original signatures
  nix.settings = {
    substituters = [
      "http://192.168.50.171"
      "https://cache.nixos.org"
    ];
  };
}
