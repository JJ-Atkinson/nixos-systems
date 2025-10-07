{nixpkgs, ...} : {
  # Enable the X11 windowing system.
  services.xserver.enable = true;

  # Enable the GNOME Desktop Environment.
  services.xserver.displayManager.gdm.enable = true;
  services.xserver.desktopManager.gnome.enable = true;

  # https://discourse.nixos.org/t/how-to-set-fractional-scaling-via-nix-configuration-for-gnome-wayland/56774
  # fractional scaling enable?
  services.xserver = {
    displayManager.gdm = {
      wayland = true;
    };
    desktopManager.gnome = {
      # extraGSettingsOverridePackages = [ pkgs.mutter ];
      extraGSettingsOverrides = ''
        [org.gnome.mutter]
        experimental-features=['scale-monitor-framebuffer']
      '';
    };
  };

  
  
  # Configure keymap in X11
  services.xserver.xkb.layout = "us";
  console.useXkbConfig = true;  # Required to make sure programs nested within the console virtual terminal also use the remapped keys
  # Enable the keyd service
  services.keyd = {
    enable = true;
    keyboards = {
      # Apply this configuration to all connected keyboards
      default = {
        ids = [ "*" ]; # Match all keyboards
        settings = {
          main = {
            # Swap Escape and Caps Lock
            capslock = "escape";
            escape = "capslock";
          };
        };
      };
    };
  };

  # Enable CUPS to print documents.
  services.printing.enable = true;

  # Enable sound.
  # enable rtkit for better rt scheduling on pipewire
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
  };

  # yubikey stuff
  security.polkit.enable = true;
  security.pam.services = {
    login.u2fAuth = true;
    sudo.u2fAuth = true;
    polkit-1.u2fAuth = true;
  };

  services.yubikey-agent.enable = true;
  services.pcscd.enable = true;
  hardware.gpgSmartcards.enable = true;

  services.udev.extraRules = ''
      ACTION=="remove",\
       ENV{ID_BUS}=="usb",\
       ENV{ID_MODEL_ID}=="0407",\
       ENV{ID_VENDOR_ID}=="1050",\
       ENV{ID_VENDOR}=="Yubico",\
       RUN+="${nixpkgs.systemd}/bin/loginctl lock-sessions"
  '';

  programs._1password-gui = {
    enable = true;
    polkitPolicyOwners = ["jarrett"];
  };

  programs.gnupg.agent = {
    enable = true;
    enableSSHSupport = true;
    # pinentryPackage = 
  };
}