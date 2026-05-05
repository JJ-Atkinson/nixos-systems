{ config, lib, pkgs, modulesPath, ... }:

{
  imports = [
    "${modulesPath}/installer/sd-card/sd-image-aarch64.nix"
  ];

  system.stateVersion = "25.11";

  networking.hostName = "rpi4-yubikey-live";
  networking.useDHCP = true;

  boot.supportedFilesystems = lib.mkForce [ "vfat" "ext4" "exfat" ];
  boot.initrd.supportedFilesystems = lib.mkForce [ "vfat" "ext4" ];
  boot.initrd.availableKernelModules = lib.mkForce [
    "ext4"
    "mmc_block"
    "pcie_brcmstb"
    "uas"
    "usb_storage"
    "usbhid"
    "xhci_pci"
  ];

  time.timeZone = "America/Chicago";
  i18n.defaultLocale = "en_US.UTF-8";
  console.keyMap = "us";

  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  users.mutableUsers = false;
  users.users.root.hashedPassword = "!";
  users.users.jarrett = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    hashedPassword = "";
  };

  security.pam.services.login.allowNullPassword = true;
  security.sudo.wheelNeedsPassword = false;

  services.openssh.enable = false;

  services.pcscd.enable = true;
  hardware.gpgSmartcards.enable = true;
  programs.gnupg.agent = {
    enable = true;
    enableSSHSupport = true;
    pinentryPackage = pkgs.pinentry-curses;
  };

  system.activationScripts.yubikeyGpgConfig.text = ''
    install -d -m 0700 -o jarrett -g users /home/jarrett/.gnupg
    install -m 0600 -o jarrett -g users ${pkgs.writeText "rpi4-yubikey-gpg.conf" ''
    ''} /home/jarrett/.gnupg/gpg.conf
    install -m 0600 -o jarrett -g users ${pkgs.writeText "rpi4-yubikey-common.conf" ''
      use-keyboxd
    ''} /home/jarrett/.gnupg/common.conf
    install -m 0600 -o jarrett -g users ${pkgs.writeText "rpi4-yubikey-scdaemon.conf" ''
      disable-ccid
    ''} /home/jarrett/.gnupg/scdaemon.conf
    install -m 0600 -o jarrett -g users ${pkgs.writeText "rpi4-yubikey-gpg-agent.conf" ''
      enable-ssh-support
      pinentry-program ${pkgs.pinentry-curses}/bin/pinentry-curses
      pinentry-timeout 86400
      default-cache-ttl 86400
      max-cache-ttl 86400
      default-cache-ttl-ssh 86400
      max-cache-ttl-ssh 86400
    ''} /home/jarrett/.gnupg/gpg-agent.conf
  '';

  environment.shellInit = ''
    export GPG_TTY="$(tty)"
    export SSH_AUTH_SOCK="$(gpgconf --list-dirs agent-ssh-socket 2>/dev/null || true)"
    export GPG_UID="Jarrett R Atkinson (Master SSH GPG Key) <jarrett@freeformsoftware.dev>"
    export LOCAL_BACKUP="/dev/shm/gpg-new-master"
    export MOUNT_DIR="/mnt/firstkey"
  '';

  environment.systemPackages = with pkgs; [
    gnupg
    pinentry-curses
    paperkey
    pcsclite
    ccid
    yubikey-manager
    yubikey-personalization
    libfido2
    opensc

    git
    openssh
    curl
    wget
    rsync
    magic-wormhole

    age
    sops
    cryptsetup
    parted
    gptfdisk
    dosfstools
    e2fsprogs
    exfatprogs
    par2cmdline-turbo
    util-linux

    vim
    tmux
    htop
    btop
    jq
    tree
    file
    less
    usbutils
    dnsutils

    (writeShellApplication {
      name = "gpg-0-disk-list";
      runtimeInputs = [ util-linux ];
      text = builtins.readFile ./scripts/gpg-0-disk-list.sh;
    })
    (writeShellApplication {
      name = "gpg-0-disk-mount";
      runtimeInputs = [ coreutils util-linux ];
      text = builtins.readFile ./scripts/gpg-0-disk-mount.sh;
    })
    (writeShellApplication {
      name = "gpg-0-disk-fsck";
      runtimeInputs = [ coreutils util-linux dosfstools e2fsprogs exfatprogs ];
      text = builtins.readFile ./scripts/gpg-0-disk-fsck.sh;
    })
    (writeShellApplication {
      name = "gpg-0-clock";
      runtimeInputs = [ coreutils systemd curl gnugrep ];
      text = builtins.readFile ./scripts/gpg-0-clock.sh;
    })
    (writeShellApplication {
      name = "gpg-1-create-key";
      runtimeInputs = [ coreutils gnupg gawk ];
      text = builtins.readFile ./scripts/gpg-1-create-key.sh;
    })
    (writeShellApplication {
      name = "gpg-2-card-policy";
      runtimeInputs = [ yubikey-manager gnupg ];
      text = builtins.readFile ./scripts/gpg-2-card-policy.sh;
    })
    (writeShellApplication {
      name = "gpg-3-load-card";
      runtimeInputs = [ coreutils gnupg gnugrep ];
      text = builtins.readFile ./scripts/gpg-3-load-card.sh;
    })
    (writeShellApplication {
      name = "gpg-3-reimport-master";
      runtimeInputs = [ coreutils gnupg gnugrep ];
      text = builtins.readFile ./scripts/gpg-3-reimport-master.sh;
    })
    (writeShellApplication {
      name = "gpg-4-finish-local";
      runtimeInputs = [ coreutils gnupg openssh gawk gnugrep ];
      text = builtins.readFile ./scripts/gpg-4-finish-local.sh;
    })
    (writeShellApplication {
      name = "gpg-5-export-public";
      runtimeInputs = [ coreutils gnupg openssh ];
      text = builtins.readFile ./scripts/gpg-5-export-public.sh;
    })
    (writeShellApplication {
      name = "gpg-6-import-public";
      runtimeInputs = [ gnupg ];
      text = builtins.readFile ./scripts/gpg-6-import-public.sh;
    })
    (writeShellApplication {
      name = "gpg-7-publish-drive";
      runtimeInputs = [ coreutils gnupg openssh par2cmdline-turbo findutils util-linux ];
      text = ''
        export RPI4_BACKUP_SCRIPT="${./scripts/gpg-9-redundant-backup.sh}"
        export RPI4_RESTORE_SCRIPT="${./scripts/gpg-9-redundant-restore.sh}"
        export RPI4_IMPORT_KEYS_SCRIPT="${./scripts/import-keys.sh}"
        ${builtins.readFile ./scripts/gpg-7-publish-drive.sh}
      '';
    })
    (writeShellApplication {
      name = "gpg-9-redundant-backup";
      runtimeInputs = [ coreutils findutils par2cmdline-turbo gnupg ];
      text = builtins.readFile ./scripts/gpg-9-redundant-backup.sh;
    })
    (writeShellApplication {
      name = "gpg-9-redundant-restore";
      runtimeInputs = [ coreutils findutils par2cmdline-turbo gnupg ];
      text = builtins.readFile ./scripts/gpg-9-redundant-restore.sh;
    })
  ];

  environment.defaultPackages = lib.mkForce [ ];
  documentation.enable = false;
  documentation.man.enable = false;
  documentation.nixos.enable = false;
  programs.command-not-found.enable = false;
  services.getty.autologinUser = lib.mkForce null;

  sdImage.compressImage = true;
  image.fileName = "rpi4-yubikey-live.img";
}
