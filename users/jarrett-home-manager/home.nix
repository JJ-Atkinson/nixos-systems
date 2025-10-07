{ config, nixpkgs, nixpkgsUnstable, environment, lib, ... }:

let 
  # system-jdk = (nixpkgsUnstable.jdk25.override { enableJavaFX = true; });
in {
  # Home Manager needs a bit of information about you and the
  # paths it should manage.
  home.username = "jarrett";
  home.homeDirectory = "/home/jarrett";

  home.packages = with nixpkgs; [
    jetbrains.idea-ultimate
    nixpkgsUnstable.devtoolbox
    nixpkgsUnstable.vscode-fhs
    nixpkgsUnstable.zed-editor
    discord
    spotify
    slack
    chromium
    nixpkgsUnstable.obsidian
    nixpkgsUnstable.dino
    nixpkgsUnstable.gajim
    nixpkgsUnstable.movim
    nixpkgsUnstable.caligula
    signal-desktop
    nixpkgsUnstable.zoom-us
    syncthing
    gnupg
    yubikey-manager
    obs-studio
    direnv
    magic-wormhole
    htop
    btop
    wpsoffice
    terminator
    nixpkgsUnstable.ghostty
    alacritty
    nil
    nixfmt
    nixpkgsUnstable.ollama
    element-desktop
    github-desktop
    nixpkgsUnstable.rustup
    onlyoffice-bin
    piper
    wireshark
    inkscape
    telegram-desktop
    nixpkgsUnstable.brave
    nixpkgsUnstable.firefox
    nixpkgsUnstable.orca-slicer
    mc
    bat # like cat but nicer
    tldr # faster man access
    # dbeaver-bin
    nixpkgsUnstable.proton-pass
    nixpkgsUnstable.imagemagick
    transmission_4-gtk
    nixpkgsUnstable.bambu-studio


    wineWowPackages.stable
    winetricks

    gpodder
    ngrok
    fzf
    tree

    # Minimal products to make IJ happy
    # (nixpkgsUnstable.clojure.override { jdk = system-jdk; })
    nixpkgsUnstable.clojure
    babashka
    leiningen
    # system-jdk
    maven
    nodejs_20
    cljfmt
    zprint
    clojure-lsp
    ruff
    black
    vlc

    dig 
    unzip

    nixpkgsUnstable.lazydocker

  ];
  # This value determines the Home Manager release that your
  # configuration is compatible with. This helps avoid breakage
  # when a new Home Manager release introduces backwards
  # incompatible changes.
  #
  # You can update Home Manager without changing this value. See
  # the Home Manager release notes for a list of state version
  # changes in each release.
  home.stateVersion = "23.05";

  services.lorri.enable = true; # Used in some of my old projects

  programs.direnv = {
    enable = true;
    enableZshIntegration = true;
    nix-direnv.enable = true;
  };


  # environment.shells = with nixpkgs; [ zsh ];
  programs.zsh = {
    enable = true;
    enableCompletion = true;
    autosuggestion.enable = true;
    history.extended = true;
#    initExtra = ''
#      ${builtins.readFile ./home/post-compinit.zsh}
#      ${builtins.readFile ./home/shell-aliases.zsh}
#    '';
    initContent = ''
       eval "$(direnv hook zsh)"
    '';
    sessionVariables = rec {
      EDITOR = "vim";
    };
    oh-my-zsh = {
      enable = true;
      # theme = "risto";
      theme = "agnoster";
      plugins = [
        "git"
        "gcloud"
        "fzf"
        "docker"
        "docker-compose"
        "kubectl"
        "aws"
        "zsh-syntax-highlighting"
        "z" # zsh-z, jump to recent folders
        "zsh-autosuggestions"
      ];
    };
    plugins = [
    ];
  };

  xsession.windowManager.bspwm.startupPrograms = ["imwheel"];


  programs.gh.enable = true;
  programs.git.enable = true;
  programs.git.iniContent = { 
    user.name = "jarrett";
    user.email = "jarrett@freeformsoftware.dev";
   # Disabled when I'm working remotely
    user.signingkey = "841C678FCEDB379A";
    commit.gpgsign = "true";
  };

  programs.vim = {
    enable = true;
    defaultEditor = true;
  };

  home.file.".clojure/deps.edn".source = ./clojure-global-deps.edn;
  # home.file.".m2/settings.xml".source = ./maven-settings.xml;
  home.file.".ideavimrc".source = ./.ideavimrc;
  # home.file.".aws/config".source = ./aws-config;
  # home.file.".aws/credentials".source = ./aws-credentials;
  home.file.".datomic/dev-local.edn".source = ./datomic-dev-local.edn;
  home.file.".config/Yubico/u2f_keys".source = ./primary_yubikey_pam_u2f; # https://nixos.wiki/wiki/Yubikey


  # systemd.user.services.ollama = {
  #  Unit = {
  #    Description = "Ollama server";
  #  };
  #  Install = {
  #    WantedBy = [ "default.target" ];
  #  };
  #  Service = {
  #    ExecStart = "${nixpkgs.writeShellScript "Ollama server" ''
  #      #!/run/current-system/sw/bin/bash
  #      ${nixpkgs.ollama}/bin/ollama serve
  #    ''}";
  #    RuntimeMaxSec="1d";
  #  };
  #};

  # xdg.dataFile."applications/gnome-screenshot.desktop".text = ''
  #   [Desktop Entry]
  #   Name=Gnome Screenshot
  #   DesktopName=Gnome Screenshot
  #   GenericName=screenshot
  #   Exec=/home/jarrett/.nix-profile/bin/gnome-screenshot -i
  #   Terminal=false
  # '';


  home.sessionVariables = {
    SSH_AUTH_SOCK = "/run/user/1000/gnupg/S.gpg-agent.ssh";
  };

  # Re-enable gnome keyring, which is turned off in configuration.nix. The non-ssh
  # functionality is still required by some apps. See desktop.nix for where 
  # the root version of gn-kr is disabled
  services.gnome-keyring = {
    enable = true;
    components = ["pkcs11" "secrets"];
  };

  xdg.desktopEntries = {
    deezer-firefox = {
      name = "Deezer";
      exec = "firefox --new-instance --profile /home/jarrett/.mozilla/firefox/deezer --new-window \"https://www.deezer.com\"";
      icon = "audio-x-generic";
      categories = ["AudioVideo" "Audio" "Player"];
      startupNotify = true;
      type = "Application";
      terminal = false;
    };

    sys-hibernate = {
      name = "System Hibernate";
      exec = "systemctl hibernate";
      terminal = false;
      type = "Application";
    };
  };

  # Let Home Manager install and manage itself.
  programs.home-manager.enable = true;
}

