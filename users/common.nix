{nixpkgs, ...} : {
   users.mutableUsers = false;
   programs.zsh.enable = true;
   programs.git.enable = true;
   programs.git.config.safe.directory = "/etc/nixos";
   users.defaultUserShell = nixpkgs.zsh;
}
