{ config, nixpkgs, lib, pkgs, ... }:
{
  imports = [ ../../users/jarrett-home-manager/zsh-hm-config.nix ];

  home.username = "rescue";
  home.homeDirectory = "/home/rescue";
  home.stateVersion = "25.11";

  home.sessionVariables = lib.mkForce {
    EDITOR = "vim";
  };

  home.file."README.md".source = ./README.md;

  programs.zsh.initContent = lib.mkAfter ''
    if [[ -t 1 ]]; then
      echo
      echo "Recovery image — see ~/README.md for the per-drive clone procedure."
      echo
    fi
  '';
}
