{
  description = "Two nixpkgs sets: stable and unstable";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    unstable.url = "github:NixOS/nixpkgs/nixos-unstable";
    sops-nix.url = "github:Mic92/sops-nix";
    sops-nix.inputs.nixpkgs.follows = "nixpkgs";
    nixos-hardware.url = "github:NixOS/nixos-hardware";
    flake-utils.url = "github:numtide/flake-utils";
    deploy.url = "github:serokell/deploy-rs";
    ucodenix.url = "github:e-tho/ucodenix";
    disko.url = "github:nix-community/disko";
    disko.inputs.nixpkgs.follows = "nixpkgs";
    lanzaboote = {
      url = "github:nix-community/lanzaboote/v1.0.0";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    home-manager = {
      url = "github:nix-community/home-manager/release-25.11";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      unstable,
      sops-nix,
      nixos-hardware,
      home-manager,
      ucodenix,
      disko,
      lanzaboote,
      ...
    }@inputs:
    let
      system = "x86_64-linux";

      # Exactly two package sets:
      nixpkgsStable = import nixpkgs {
        inherit system;
        config.allowUnfree = true;
      };
      nixpkgsUnstable = import unstable {
        inherit system;
        config.allowUnfree = true;
      };

      # Pass them to modules under the names you prefer
      specialArgs = {
        nixpkgs = nixpkgsStable;
        nixpkgsUnstable = nixpkgsUnstable;
        inherit inputs nixos-hardware;
      };
    in
    {
      nixosConfigurations.nixos = nixpkgs.lib.nixosSystem {
        inherit system specialArgs;
        modules = [
          sops-nix.nixosModules.sops
          ./systems/nixos/fs-opts.nix
          ./systems/nixos/hw-opts.nix
          ./systems/nixos/etc.nix
          ./systems/nixos/virtualization-opts.nix
          ./systems/nixos/std-backup-restic.nix
          ./systems/nixos/syncthing.nix
          ./modules/btrfs-scrub.nix
          ./modules/desktop.nix
          # ./modules/desktop-kde.nix
          ./modules/docker.nix
          ./modules/etc.nix
          ./modules/vu-driver.nix
          ./modules/networking.nix
          ./modules/ssh-access.nix
          ./modules/tailscale.nix
          ./modules/pgadmin.nix
          ./modules/nix-serve.nix
          ./modules/nixos-cache.nix
          ./modules/hardware-dev.nix
          ./modules/spacemouse.nix
          ./modules/re-clip.nix
          ./modules/virtiofsd-looking-glass.nix

          ./users/common.nix
          ./users/jarrett.nix

          # One small module to set the NixOS option for unfree
          (
            { ... }:
            {
              nixpkgs.config.allowUnfree = true;
            }
          )

          home-manager.nixosModules.home-manager
          {
            home-manager.useGlobalPkgs = true;
            home-manager.useUserPackages = true;

            # Pass the same specialArgs to Home Manager
            home-manager.extraSpecialArgs = specialArgs;

            home-manager.users.jarrett = import ./users/jarrett-home-manager/home.nix;
          }
        ];
      };

      nixosConfigurations.nixos-framework = nixpkgs.lib.nixosSystem {
        inherit system specialArgs;
        modules = [
          sops-nix.nixosModules.sops
          nixos-hardware.nixosModules.framework-amd-ai-300-series
          ucodenix.nixosModules.default
          disko.nixosModules.disko
          lanzaboote.nixosModules.lanzaboote
          ./systems/nixos-framework/disko.nix
          ./systems/nixos-framework/hw-opts.nix
          ./systems/nixos-framework/etc.nix
          ./systems/nixos-framework/syncthing.nix
          ./modules/lanza.nix
          ./modules/btrfs-scrub.nix
          ./modules/desktop.nix
          ./modules/virtual-machines.nix
          ./modules/docker.nix
          ./modules/etc.nix
          ./modules/vu-driver.nix
          ./modules/networking.nix
          ./modules/ssh-access.nix
          ./modules/tailscale.nix
          ./modules/nixos-cache.nix

          ./users/common.nix
          ./users/jarrett.nix

          # One small module to set the NixOS option for unfree
          (
            { ... }:
            {
              nixpkgs.config.allowUnfree = true;
            }
          )

          home-manager.nixosModules.home-manager
          {
            home-manager.useGlobalPkgs = true;
            home-manager.useUserPackages = true;

            # Pass the same specialArgs to Home Manager
            home-manager.extraSpecialArgs = specialArgs;

            home-manager.users.jarrett = import ./users/jarrett-home-manager/home.nix;
          }
        ];
      };

      # deploy = import ./deploy.nix inputs;

      devShells.${system}.default = nixpkgsStable.mkShell {
        buildInputs = [
          nixpkgsStable.nixos-generators
          nixpkgsStable.sops
          nixpkgsStable.ssh-to-pgp
          nixpkgsStable.age
          nixpkgsStable.deploy-rs
          nixpkgsUnstable.claude-code
        ];
      };
    };
}
