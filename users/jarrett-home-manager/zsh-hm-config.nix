{ config, nixpkgs, lib, ... }:

{
  programs.zsh = {
    enable = true;
    enableCompletion = true;
    autosuggestion.enable = true;
    syntaxHighlighting.enable = true;
    history.extended = true;
    initContent = ''
       if command -v direnv >/dev/null 2>&1; then
         eval "$(direnv hook zsh)"
       fi
       export EDITOR="vim"
       export TERM_PROGRAM=ghostty

       with-program() {
         local depth="''${WITH_PROGRAM_NIX_SHELL_DEPTH:-0}"
         if [[ -z "$WITH_PROGRAM_NIX_SHELL_DEPTH" && -n "$IN_NIX_SHELL" ]]; then
           depth=1
         fi
         depth=$(( depth + 1 ))

         command nix-shell -p "$@" --run "WITH_PROGRAM_NIX_SHELL_DEPTH=$depth ${nixpkgs.zsh}/bin/zsh"
       }

       # Set Ghostty tab title from GHOSTTY_TAB_TITLE env var (set per worktree in .envrc)
       _ghostty_tab_title_precmd() {
         if [[ -n "$GHOSTTY_TAB_TITLE" ]]; then
           printf '\033]0;%s\007' "$GHOSTTY_TAB_TITLE"
         fi
       }
        [[ -z "''${precmd_functions[(r)_ghostty_tab_title_precmd]}" ]] && precmd_functions+=(_ghostty_tab_title_precmd)

       ${builtins.readFile ./zsh-prompt.zsh}
     '';
    sessionVariables = {
      EDITOR = "vim";
    };
    oh-my-zsh = {
      enable = lib.mkDefault true;
      theme = "";
      plugins = lib.mkDefault [
        "git"
        "gcloud"
        "fzf"
        "docker"
        "docker-compose"
        "kubectl"
        "aws"
        "z"
      ];
    };
    plugins = [ ];
  };
}
