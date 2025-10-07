{nixpkgs, ...} : {
   users.mutableUsers = false;
   programs.zsh.enable = true;
   programs.git.enable = true; 
   users.defaultUserShell = nixpkgs.zsh;
}
