{ config, nixpkgs, nixpkgsUnstable, claudeCode, environment, lib, ... }:

let
  # system-jdk = (nixpkgsUnstable.jdk25.override { enableJavaFX = true; });
  # TODO 2026-06-30: Re-evaluate whether nixpkgsUnstable.opencode still needs this local libstdc++ wrapper.
  opencodeWithLibstdcpp = nixpkgsUnstable.opencode.overrideAttrs (old: {
    postFixup = (old.postFixup or "") + ''
      wrapProgram $out/bin/opencode \
        --prefix LD_LIBRARY_PATH : "${lib.makeLibraryPath [ nixpkgsUnstable.stdenv.cc.cc.lib ]}"
    '';
  });
  zedClojureLauncher = nixpkgs.writeShellScriptBin "zeditor" ''
    set -euo pipefail

    bundle=/home/jarrett/.local/share/zed-clojure-current
    if [[ ! -x "$bundle/zed" ]]; then
      echo "Custom Zed binary is missing: $bundle/zed" >&2
      exit 1
    fi
    if [[ ! -r "$bundle/remote_server.gz" ]]; then
      echo "Custom Zed remote server is missing: $bundle/remote_server.gz" >&2
      exit 1
    fi

    export ZED_COPY_REMOTE_SERVER="$bundle/remote_server.gz"
    export ZED_UPDATE_EXPLANATION="This custom Zed build is managed through /etc/nixos."
    exec "$bundle/zed" "$@"
  '';
  keycount-daemon = nixpkgs.runCommandCC "keycount-daemon" { } ''
    mkdir -p $out/bin
    $CC -O2 -Wall -Wextra -o $out/bin/keycount-daemon ${./keycount/keycount-daemon.c}
  '';
in {
  imports = [
    ./zsh-hm-config.nix
  ];

  # Home Manager needs a bit of information about you and the
  # paths it should manage.
  home.username = "jarrett";
  home.homeDirectory = "/home/jarrett";

  home.packages = with nixpkgs; [
    jetbrains.idea
    devtoolbox
    telegram-desktop
    nixpkgsUnstable.vscode-fhs
    nixpkgsUnstable.zed-editor
    (lib.hiPrio zedClojureLauncher)
    discord
    spotify
    slack
    chromium
    google-chrome
    nixpkgsUnstable.obsidian
    nixpkgsUnstable.dino
    nixpkgsUnstable.gajim
    nixpkgsUnstable.movim
    nixpkgsUnstable.caligula
    nixpkgsUnstable.signal-desktop
    nixpkgsUnstable.zoom-us
    syncthing
    gnupg
    yubikey-manager
    par2cmdline-turbo
    obs-studio
    uxplay
    direnv
    magic-wormhole
    htop
    btop
    wpsoffice
    terminator
    nixpkgsUnstable.ghostty
    alacritty
    nil
    nixfmt-rfc-style
    nixpkgsUnstable.ollama
    nixpkgsUnstable.llama-cpp-vulkan
    nixpkgsUnstable.pi-coding-agent
    element-desktop
    github-desktop
    nixpkgsUnstable.rustup
    onlyoffice-desktopeditors
    piper
    wireshark
    inkscape
    telegram-desktop
    nixpkgsUnstable.brave
    nixpkgsUnstable.firefox
    mc
    bat # like cat but nicer
    tldr # faster man access
    # dbeaver-bin
    nixpkgsUnstable.proton-pass
    nixpkgsUnstable.protonvpn-gui
    nixpkgsUnstable.imagemagick
    transmission_4-gtk
    claudeCode
    nixpkgsUnstable.appimage-run
    opencodeWithLibstdcpp
    nixpkgsUnstable.herdr
    nixpkgsUnstable.deezer-desktop

    # gnome apps
    gnome-tweaks
    nixpkgsUnstable.resources
    nixpkgsUnstable.gnome-graphs
    nixpkgsUnstable.tangram
    nixpkgsUnstable.video-trimmer
    nixpkgsUnstable.warp
    nixpkgsUnstable.gnome-boxes

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
    openscad
    jq

    # iOS safari debug tooling
    libimobiledevice
    ios-webkit-debug-proxy

    keycount-daemon
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
  # zsh config lives in ./zsh-hm-config.nix (shared with rpi4-yubikey-live)

  xsession.windowManager.bspwm.startupPrograms = ["imwheel"];


  programs.gh.enable = true;
  programs.git.enable = true;
  programs.git.iniContent = { 
    user.name = "jarrett";
    user.email = "16200906+JJ-Atkinson@users.noreply.github.com";
   # Disabled when I'm working remotely
    user.signingkey = "1B78F90203495DE0";
    commit.gpgsign = "true";
    gpg.format = "openpgp";
  };

  programs.vim = {
    enable = true;
    defaultEditor = true;
  };

  home.file.".clojure/deps.edn".source = ./clojure-global-deps.edn;
  # home.file.".m2/settings.xml".source = ./maven-settings.xml;
  home.file.".ideavimrc".source = ./.ideavimrc;

  # Daily key/space counter: C daemon counts via evdev (keyd virtual kb);
  # GNOME extension only displays ~/.local/share/keycount/stats.json
  xdg.dataFile."gnome-shell/extensions/keycount@local".source = ./extensions + "/keycount@local";

  systemd.user.services.keycount-daemon = {
    Unit = {
      Description = "Count key presses per day (no keylogging)";
      After = [ "graphical-session.target" ];
    };
    Service = {
      ExecStart = "${keycount-daemon}/bin/keycount-daemon";
      Restart = "on-failure";
      RestartSec = "2";
    };
    Install = {
      WantedBy = [ "default.target" ];
    };
  };

  dconf.settings = {
    "org/gnome/shell" = {
      disable-user-extensions = false;
      enabled-extensions = [ "keycount@local" ];
    };
    # Workspace left/right (free Super+h from minimize, Super+l from lock)
    "org/gnome/desktop/wm/keybindings" = {
      minimize = [ ];
      switch-to-workspace-left = [ "<Super>h" ];
      switch-to-workspace-right = [ "<Super>l" ];
    };
    "org/gnome/settings-daemon/plugins/media-keys" = {
      screensaver = [ ]; # was <Super>l
      custom-keybindings = [
        "/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0/"
        "/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom1/"
      ];
    };
    # Existing interactive screenshot (was set outside HM)
    "org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0" = {
      name = "Screenshot";
      command = "gdbus call --session --dest org.gnome.Shell.Screenshot --object-path /org/gnome/Shell/Screenshot --method org.gnome.Shell.Screenshot.InteractiveScreenshot";
      binding = "<Super>Delete";
    };
    # reclip: strip 1Password clipboard metadata (modules/re-clip.nix)
    "org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom1" = {
      name = "reclip";
      command = "reclip";
      binding = "<Control><Alt>c";
    };
  };
  # home.file.".aws/config".source = ./aws-config;
  # home.file.".aws/credentials".source = ./aws-credentials;
  home.file.".datomic/dev-local.edn".source = ./datomic-dev-local.edn;
  home.file.".config/Yubico/u2f_keys".source = ./primary_yubikey_pam_u2f; # https://nixos.wiki/wiki/Yubikey
  home.file.".gnupg/scdaemon.conf".text = "disable-ccid\n"; # Force scdaemon to use pcscd, not direct CCID


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


  # The yubigpg module supplies the stable selected SSH agent at login.
  # Keep the socket path out of Home Manager's cached session-variable script.

  # Re-enable gnome keyring, which is turned off in configuration.nix. The non-ssh
  # functionality is still required by some apps. See desktop.nix for where
  # the root version of gn-kr is disabled
  services.gnome-keyring = {
    enable = true;
    components = ["pkcs11" "secrets"];
  };

  # Enable KWallet for KDE application secrets
  # Local SSH uses GPG agent; SSH sessions can preserve a forwarded agent.
  # services.kwalletd = {
  #   enable = true;
  # };

  # Open on GNOME/Wayland graphical login only (XDG autostart; not SSH).
  xdg.configFile = lib.listToAttrs (
    map
      (app: {
        name = "autostart/${app.id}.desktop";
        value.text = ''
          [Desktop Entry]
          Type=Application
          Name=${app.name}
          Exec=${app.exec}
          Terminal=false
          X-GNOME-Autostart-enabled=true
        '';
      })
      [
        {
          id = "slack";
          name = "Slack";
          exec = "${nixpkgs.slack}/bin/slack -s";
        }
        {
          id = "firefox";
          name = "Firefox";
          exec = "${nixpkgsUnstable.firefox}/bin/firefox";
        }
        {
          id = "deezer";
          name = "Deezer";
          exec = "${nixpkgsUnstable.brave}/bin/brave --profile-directory=Default --app-id=dbjlimibnhmfcgadnpbfgkmmeijhieif";
        }
        {
          id = "ghostty";
          name = "Ghostty";
          exec = "${nixpkgsUnstable.ghostty}/bin/ghostty --gtk-single-instance=true";
        }
        {
          id = "discord";
          name = "Discord";
          exec = "${nixpkgs.discord}/bin/Discord";
        }
        {
          id = "1password";
          name = "1Password";
          exec = "1password";
        }
        {
          id = "chromium";
          name = "Chromium";
          exec = "${nixpkgs.chromium}/bin/chromium";
        }
        {
          id = "nautilus";
          name = "Files";
          exec = "nautilus";
        }
      ]
  ) // {
   "zed/keymap.json" = {
      force = true;
      text = builtins.toJSON [
        {
          context = "Editor && vim_mode == normal && !menu";
          bindings = {
            s = "workspace::SaveAll";
            "=" = "editor::Format";
            w = "editor::SelectLargerSyntaxNode";
            W = "editor::SelectSmallerSyntaxNode";
            t = "pane::GoBack";
            T = "pane::GoForward";
            b = "editor::GoToDefinition";
            "shift-b" = "editor::FindAllReferences";
            q = "editor::Hover";
            U = "editor::Redo";
          };
        }
        {
          context = "Editor && vim_mode == visual && !menu";
          bindings = {
            "=" = "editor::Format";
            w = "editor::SelectLargerSyntaxNode";
            W = "editor::SelectSmallerSyntaxNode";
          };
        }
        {
          context = "Editor && !menu && (vim_mode == normal || vim_mode == visual) && (extension == clj || extension == cljs || extension == cljc || extension == cljd || extension == edn || extension == bb)";
          bindings = {
            "z enter" = null;
            "z -" = null;
            "z ^" = null;
            "z +" = null;
            "z t" = null;
            "z z" = null;
            "z ." = null;
            "z b" = null;
            "z a" = null;
            "z shift-a" = null;
            "z c" = null;
            "z shift-c" = null;
            "z o" = null;
            "z shift-o" = null;
            "z f" = null;
            "z shift-m" = null;
            "z shift-r" = null;
            "z l" = null;
            "z h" = null;
            "z shift-l" = null;
            "z shift-h" = null;
            "shift-z shift-z" = null;
            "shift-z shift-q" = null;
          };
        }
        {
          context = "Editor && !menu && (vim_mode == normal || vim_mode == visual) && (extension == clj || extension == cljc || extension == cljs || extension == edn || extension == bb)";
          bindings = {
            "space r p" = [
              "editor::SpawnNearestTask"
              {
                reveal = "never";
                use_selection_context = true;
                variables = {
                  snippet = "portal";
                };
              }
            ];
            "space r r" = [
              "editor::SpawnNearestTask"
              {
                reveal = "never";
                use_selection_context = true;
                variables = {
                  snippet = "refresh-all";
                };
              }
            ];
            "space r c" = [
              "editor::SpawnNearestTask"
              {
                reveal = "never";
                use_selection_context = true;
                variables = {
                  snippet = "refresh-all-clj-reload";
                };
              }
            ];
            "space r t" = [
              "editor::SpawnNearestTask"
              {
                reveal = "never";
                use_selection_context = true;
                variables = {
                  snippet = "portal-test";
                };
              }
            ];
            "space r l" = [
              "editor::SpawnNearestTask"
              {
                reveal = "never";
                use_selection_context = true;
                variables = {
                  snippet = "load-file";
                };
              }
            ];
            "space r 0" = [
              "editor::SpawnNearestTask"
              {
                reveal = "never";
                use_selection_context = true;
                variables = {
                  snippet = "use-remote";
                };
              }
            ];
            "space r 1" = [
              "editor::SpawnNearestTask"
              {
                reveal = "never";
                use_selection_context = true;
                variables = {
                  snippet = "use-jvm";
                };
              }
            ];
            "space r 2" = [
              "editor::SpawnNearestTask"
              {
                reveal = "never";
                use_selection_context = true;
                variables = {
                  snippet = "use-node";
                };
              }
            ];
            "space r w" = [
              "editor::SpawnNearestTask"
              {
                reveal = "never";
                use_selection_context = true;
                variables = {
                  snippet = "reload";
                };
              }
            ];
            "space r e" = [
              "editor::SpawnNearestTask"
              {
                reveal = "never";
                use_selection_context = true;
                variables = {
                  snippet = "restart";
                };
              }
            ];
            "space r a" = [
              "editor::SpawnNearestTask"
              {
                reveal = "never";
                use_selection_context = true;
                variables = {
                  snippet = "tap";
                };
              }
            ];
            "space r u" = [
              "editor::SpawnNearestTask"
              {
                reveal = "never";
                use_selection_context = true;
                variables = {
                  snippet = "unbreak";
                };
              }
            ];
          };
        }
        {
          context = "Editor && vim_mode == normal && !menu && (extension == clj || extension == cljc || extension == cljs || extension == cljd || extension == edn || extension == bb)";
          bindings = {
            z = [
              "editor::SpawnNearestTask"
              {
                reveal = "never";
              }
            ];
            "shift-z" = [
              "editor::SpawnNearestTask"
              {
                reveal = "never";
                variables = {
                  snippet = "tap";
                };
              }
            ];
          };
        }
        {
          context = "Editor && vim_mode == visual && !menu && (extension == clj || extension == cljc || extension == cljs || extension == edn || extension == bb)";
          bindings = {
            z = [
              "editor::SpawnNearestTask"
              {
                reveal = "never";
                use_selection_context = true;
                variables = {
                  snippet = "evaluate";
                };
              }
            ];
            "shift-z" = [
              "editor::SpawnNearestTask"
              {
                reveal = "never";
                use_selection_context = true;
                variables = {
                  snippet = "tap";
                };
              }
            ];
          };
        }
        {
          context = "Editor && vim_mode == normal && !menu && (extension == clj || extension == cljc || extension == cljs || extension == bb)";
          bindings = {
            "shift-j" = [
              "editor::ExecuteLspCommand"
              {
                server = "clojure-lsp";
                command = "forward-sexp-or-up";
                arguments = [ "$uri" "$line" "$column" ];
              }
            ];
            "shift-k" = [
              "editor::ExecuteLspCommand"
              {
                server = "clojure-lsp";
                command = "backward-sexp-or-up";
                arguments = [ "$uri" "$line" "$column" ];
              }
            ];
            "shift-h" = [
              "editor::ExecuteLspCommand"
              {
                server = "clojure-lsp";
                command = "forward-barf";
                arguments = [ "$uri" "$line" "$column" ];
              }
            ];
            "shift-l" = [
              "editor::ExecuteLspCommand"
              {
                server = "clojure-lsp";
                command = "forward-slurp";
                arguments = [ "$uri" "$line" "$column" ];
              }
            ];
            "shift-m" = [
              "editor::ExecuteLspCommand"
              {
                server = "clojure-lsp";
                command = "drag-backward";
                arguments = [ "$uri" "$line" "$column" ];
              }
            ];
            m = [
              "editor::ExecuteLspCommand"
              {
                server = "clojure-lsp";
                command = "drag-forward";
                arguments = [ "$uri" "$line" "$column" ];
              }
            ];
          };
        }
        {
          context = "Editor && vim_mode == visual && !menu && (extension == clj || extension == cljc || extension == cljs || extension == bb)";
          bindings = {
            "shift-j" = [
              "editor::ExecuteLspCommand"
              {
                server = "clojure-lsp";
                command = "backward-select";
                arguments = [ "$uri" "$line" "$column" ];
              }
            ];
            "shift-k" = [
              "editor::ExecuteLspCommand"
              {
                server = "clojure-lsp";
                command = "forward-select";
                arguments = [ "$uri" "$line" "$column" ];
              }
            ];
          };
        }
      ];
    };
    uxplayrc.text = "p 17000\n";
    "herdr/config.toml" = {
      force = true;
      text = ''
        onboarding = false

        [theme]
        name = "terminal"

        [ui]
        tab_bar_right = [{ type = "hostname" }]
      '';
    };
  };

  xdg.desktopEntries = {
    sys-hibernate = {
      name = "System Hibernate";
      exec = "systemctl hibernate";
      terminal = false;
      type = "Application";
    };
    # Titlebar colors from worktree VS Code settings (hai / scoria) + orange.
    # green 35de8f, blue A0CFD3, purple 9a7aa0, yellow d1d133, orange E89B5C
    ghostty-green = {
      name = "Ghostty Green";
      exec = "ghostty --window-theme=ghostty --window-titlebar-background=35de8f --window-titlebar-foreground=000000";
      terminal = false;
      type = "Application";
      icon = "com.mitchellh.ghostty";
      categories = [ "System" "TerminalEmulator" ];
    };
    ghostty-blue = {
      name = "Ghostty Blue";
      exec = "ghostty --window-theme=ghostty --window-titlebar-background=A0CFD3 --window-titlebar-foreground=000000";
      terminal = false;
      type = "Application";
      icon = "com.mitchellh.ghostty";
      categories = [ "System" "TerminalEmulator" ];
    };
    ghostty-purple = {
      name = "Ghostty Purple";
      exec = "ghostty --window-theme=ghostty --window-titlebar-background=9a7aa0 --window-titlebar-foreground=ffffff";
      terminal = false;
      type = "Application";
      icon = "com.mitchellh.ghostty";
      categories = [ "System" "TerminalEmulator" ];
    };
    ghostty-yellow = {
      name = "Ghostty Yellow";
      exec = "ghostty --window-theme=ghostty --window-titlebar-background=d1d133 --window-titlebar-foreground=000000";
      terminal = false;
      type = "Application";
      icon = "com.mitchellh.ghostty";
      categories = [ "System" "TerminalEmulator" ];
    };
    ghostty-orange = {
      name = "Ghostty Orange";
      exec = "ghostty --window-theme=ghostty --window-titlebar-background=E89B5C --window-titlebar-foreground=000000";
      terminal = false;
      type = "Application";
      icon = "com.mitchellh.ghostty";
      categories = [ "System" "TerminalEmulator" ];
    };
  };

  # Let Home Manager install and manage itself.
  programs.home-manager.enable = true;
}
