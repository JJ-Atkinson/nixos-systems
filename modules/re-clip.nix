{ pkgs, ... }:
{
  # Install wl-clipboard for Wayland clipboard operations
  environment.systemPackages = with pkgs; [
    wl-clipboard

    # Create reclip script to strip 1Password metadata from clipboard
    (pkgs.writeShellScriptBin "reclip" ''
      #!/usr/bin/env bash
      # Re-copy clipboard to strip 1Password metadata
      # Usage: Copy from 1Password, run this script, paste into VM
      ${pkgs.wl-clipboard}/bin/wl-paste | ${pkgs.wl-clipboard}/bin/wl-copy
    '')
  ];
}
