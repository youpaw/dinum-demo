{
  description = "Selfhostix collaboration demo (LaSuite Docs + LaSuite Drive) + Bureautix clients";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };

    microvm = {
      url = "github:microvm-nix/microvm.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = inputs @ {
    flake-parts,
    microvm,
    nixpkgs,
    ...
  }: let
    systems = ["x86_64-linux"];
  in
    flake-parts.lib.mkFlake {inherit inputs;} {
      inherit systems;

      # One guest for every service (see ./nix/guest.nix): a full
      # cloud-hypervisor microVM for Debian hosts, on a single tap to the
      # host proxy. Run after `sudo nix run .#net-setup`:
      #   nix run .#microvm
      flake.nixosConfigurations.selfhostix = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [microvm.nixosModules.microvm ./nix/guest.nix];
      };

      # Apps (scripts + host proxy files) all live in ./nix/apps.nix.
      perSystem = {
        pkgs,
        lib,
        ...
      }: let
        scripts = import ./nix/apps.nix {inherit pkgs lib;};
        toApp = pkg: {
          type = "app";
          program = lib.getExe pkg;
        };
      in {
        packages = scripts;
        # detect-origin is a helper the other scripts call on PATH, not a verb
        # of the demo, so it stays a package without an app entry.
        apps = lib.mapAttrs (_: toApp) (removeAttrs scripts ["detect-origin"]);
        formatter = pkgs.alejandra;
      };
    };
}
