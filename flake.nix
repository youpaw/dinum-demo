{
  description = "Selfhostix collaboration server (LaSuite Docs) + Bureautix clients";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    microvm.url = "github:microvm-nix/microvm.nix";
    microvm.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, microvm, ... }: {
    nixosConfigurations = {
      # Selfhostix server (see ./microvm/docs-guest.nix): full Docs stack as a
      # cloud-hypervisor microVM for Debian hosts (no libvirt, no qcow2
      # overlay chain). Run after creating the tap net
      # (see ./host/net-setup.sh) and starting the proxy:
      #   nix run .#nixosConfigurations.selfhostix.config.microvm.runner.cloud-hypervisor
      selfhostix = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [ microvm.nixosModules.microvm ./microvm/docs-guest.nix ];
      };
    };
  };
}
