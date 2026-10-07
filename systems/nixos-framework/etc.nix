{ pkgs, ... }:
let
  ignoreLidUuid = "ignore-lid@gnome-extensions.mfloto.com";
  # Ignore Lid v2 supports GNOME Shell 49/50; not yet in pinned Nixpkgs.
  ignoreLid = pkgs.fetchzip {
    name = "ignore-lid-2";
    url = "https://extensions.gnome.org/download-extension/${ignoreLidUuid}.shell-extension.zip?version_tag=71079";
    extension = "zip";
    stripRoot = false;
    hash = "sha256-TYdldAoHAr9Xx3FOQt+Rwgo2OYVi3IO7SFP+bQnb+wk=";
  };
in
{
  networking.hostName = "nixos-framework";

  home-manager.users.jarrett = {
    xdg.dataFile."gnome-shell/extensions/${ignoreLidUuid}".source = ignoreLid;
    dconf.settings."org/gnome/shell".enabled-extensions = [ ignoreLidUuid ];
  };
}
