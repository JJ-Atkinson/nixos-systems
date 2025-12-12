{ nixpkgs, lib, ... }:
{
  programs.virt-manager.enable = true;

  users.groups.libvirtd.members = [ "jarrett" ];

  virtualisation.libvirtd.enable = true;

  virtualisation.spiceUSBRedirection.enable = true;
}
