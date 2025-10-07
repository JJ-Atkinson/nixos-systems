{
  description = "Two nixpkgs sets: stable and unstable";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
    unstable.url = "github:NixOS/nixpkgs/nixos-unstable";
    sops-nix.url = "github:Mic92/sops-nix";
    sops-nix.inputs.nixpkgs.follows = "nixpkgs";
    nixos-hardware.url = "github:NixOS/nixos-hardware";
    flake-utils.url = "github:numtide/flake-utils";
    deploy.url = "github:serokell/deploy-rs";

    home-manager = {
      url = "github:nix-community/home-manager/release-25.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, unstable, sops-nix, nixos-hardware, home-manager, ... }@inputs:
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
  in {
    nixosConfigurations.nixos = nixpkgs.lib.nixosSystem {
      inherit system specialArgs;
      modules = [
        sops-nix.nixosModules.sops
        ./systems/nixos/fs-opts.nix
        ./systems/nixos/hw-opts.nix
        ./systems/nixos/etc.nix
        ./systems/nixos/std-backup-restic.nix
        ./systems/nixos/syncthing.nix
        ./modules/btrfs-scrub.nix
        ./modules/desktop.nix
        ./modules/docker.nix
        ./modules/etc.nix
        ./modules/networking.nix
        ./modules/ssh-access.nix
        ./modules/tailscale.nix

        ./users/common.nix
        ./users/jarrett.nix

        # One small module to set the NixOS option for unfree
        ({ ... }: {
          nixpkgs.config.allowUnfree = true;
        })

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

    deploy = import ./deploy.nix inputs;

    devShell.${system} = nixpkgsStable.mkShell {
      buildInputs = [
        nixpkgsStable.nixos-generators
        nixpkgsStable.sops
        nixpkgsStable.ssh-to-pgp
        nixpkgsStable.age
        nixpkgsStable.deploy-rs
      ];
    };
  };
}