{ config, nixpkgs, lib, ... }:

{
  imports = [
    ../../users/jarrett-home-manager/zsh-hm-config.nix
  ];

  home.username = "jarrett";
  home.homeDirectory = "/home/jarrett";
  home.stateVersion = "25.11";

  programs.home-manager.enable = true;

  programs.zsh.oh-my-zsh.enable = false;
  programs.zsh.sessionVariables = {
    _PROMPT_OK_GLYPH = "OK";
    _PROMPT_FAIL_GLYPH = "X";
  };

  home.file."README.md".source = ./README.md;
}
