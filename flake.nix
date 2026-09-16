{
  description = "Isolated LaSuite Docs quickstart VM (loopback) — reusable for libvirt testing VM";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs, ... }: {
    nixosConfigurations = {
      # Isolated temp run: nix build .#nixosConfigurations.quickstart.config.system.build.vm
      quickstart = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [ ./docs-vm.nix {
          # Runner sizing + SLIRP forwards. NOTE: build.vm reads vmVariant,
          # build.vmWithBootLoader reads vmVariantWithBootLoader ONLY, so
          # both must be set (they are independent deltas in this nixpkgs).
          virtualisation.vmVariant.virtualisation = {
            memorySize = 4096;
            cores = 4;
            diskSize = 8192;
            forwardPorts = [
              { from = "host"; host.port = 8081; guest.port = 80; }
              { from = "host"; host.port = 2221; guest.port = 22; }
            ];
          };
          virtualisation.vmVariantWithBootLoader.virtualisation = {
            memorySize = 4096;
            cores = 4;
            diskSize = 8192;
            forwardPorts = [
              { from = "host"; host.port = 8081; guest.port = 80; }
              { from = "host"; host.port = 8082; guest.port = 8080; }
              { from = "host"; host.port = 8083; guest.port = 9000; }
              { from = "host"; host.port = 2221; guest.port = 22; }
            ];
          };
        } ];
      };
      # Testing libvirt VM: same base, plus ssh key + hostname tweaks.
      # Deploy with nixos-anywhere or import qcow2 into virt-manager.
      testing = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [ ./docs-vm.nix ./testing-vm.nix ];
      };
    };
  };
}
