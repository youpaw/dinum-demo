# Differences for the persistent libvirt testing VM vs ephemeral quickstart.
# Usage:
#   1. virt-manager: import the qcow2 from `nix build .#nixosConfigurations.testing.config.system.build.vm`
#      (or .#nixosConfigurations.testing.config.system.build.image), or
#   2. nixos-anywhere: nix run nixpkgs#nixos-anywhere -- --flake .#testing root@<vm-ip>
{ config, lib, ... }:
{
  networking.hostName = "docs-testing";
  # Do NOT autologin on a persistent VM; set your key:
  # users.users.root.openssh.authorizedKeys.keys = [ "ssh-ed25519 AAAA... you@host" ];
  services.getty.autologinUser = lib.mkForce null;
  users.users.root.password = lib.mkForce null; # key-only login
  services.openssh.settings.PasswordAuthentication = false;
}
