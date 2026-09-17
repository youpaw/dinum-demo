# The demo guest: one microVM (microvm.nix + cloud-hypervisor, Debian hosts —
# no libvirt, no qcow2 overlay chain) running every service.
#
#   host tap endpoint  192.168.100.1     tap-selfhostix
#   guest              52:54:00:64:78:0a 192.168.100.10   docs + drive
#
# One guest means one wire: `sudo nix run .#net-setup` puts the gateway
# address on the tap itself, so there is no bridge to join taps behind. The
# host reverse proxy (generated from ../nix/services.nix, see nix/apps.nix)
# binds the LAN IP and forwards to :80 here, so only the proxy is LAN-visible;
# dex (:8080) and garage (:9000) stay on the tap link unless proxied.
#
# This file is the only place demo data (../nix/services.nix) meets the
# option tree; everything below it is parametrised through `demo.*` options.
{
  pkgs,
  lib,
  ...
}: let
  demo = import ./services.nix {inherit lib;};
  inherit (demo) guest services;
  # The origin browsers actually use (the host's LAN address) cannot be known
  # at flake pin time. Boot wrappers export SELFHOSTIX_PUBLIC_ORIGIN (see
  # nix/scripts/microvm.sh); without --impure getEnv reads "" and this is a
  # no-op, so pure evaluation is unaffected.
  envOrigin = builtins.getEnv "SELFHOSTIX_PUBLIC_ORIGIN";
in {
  imports = [
    ./net.nix
    ./platform.nix
    ./services/docs.nix
    ./services/drive.nix
  ];

  demo.net = {
    inherit (guest) ip mac gateway dns;
    domains = lib.mapAttrsToList (_: s: s.domain) services;
    publicOrigins = lib.optional (envOrigin != "") envOrigin;
  };
  demo.docs.domain = services.docs.domain;
  demo.drive.domain = services.drive.domain;

  microvm = {
    hypervisor = "cloud-hypervisor";
    # Both stacks in one guest (Django/gunicorn + celery + collaboration
    # server for Docs, + beat for Drive) on shared postgres/garage/dex. Two
    # 4 GB / 4 vCPU guests lagged noticeably when each ran a full stack; this
    # is the same budget in one place, minus the duplicated backends.
    # Changing it requires a guest reboot.
    mem = 8192;
    vcpu = 8;
    # erofs = faster than squashfs, read-only root with prepopulated store.
    # (microvm.nix default; pinned here so perf intent is explicit.)
    interfaces = [
      {
        type = "tap";
        id = guest.tap;
        inherit (guest) mac;
      }
    ];
    # Only /var/lib persists (postgres, garage, media); the root filesystem
    # is ephemeral on every boot.
    volumes = [
      {
        mountPoint = "/var/lib";
        image = "var-lib-selfhostix.img";
        size = 8192;
      }
    ];
  };

  networking.hostName = guest.hostName;
  system.stateVersion = "25.11";
  time.timeZone = "UTC";

  # Easy console access for the demo VM (root/root, SSH open).
  users.users.root.password = "root";
  services.getty.autologinUser = lib.mkDefault "root";
  services.openssh.enable = true;
  services.openssh.settings.PermitRootLogin = "yes";
  # 80/443 nginx; 8080 dex and 9000 garage-S3 are reached via the guest tap
  # address, so the firewall must allow them even though nothing listens on
  # public sockets.
  networking.firewall.allowedTCPPorts = [80 443 8080 9000];

  # Hand tools for poking at the stack from the guest console.
  environment.systemPackages = with pkgs; [curl jq garage_2];
}
