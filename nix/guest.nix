# The demo guest: one microVM (microvm.nix + cloud-hypervisor, Debian hosts —
# no libvirt, no qcow2 overlay chain) running every service.
#
#   host tap endpoint  192.168.100.1     tap-selfhostix
#   guest              52:54:00:64:78:0a 192.168.100.10   docs + drive
#
# One guest means one wire: `sudo nix run .#net-setup` puts the gateway
# address on the tap itself, so there is no bridge to join taps behind. The
# host reverse proxy (generated from ./services.nix, see nix/apps.nix)
# terminates TLS for every name and forwards plain HTTP over the tap, so only
# the proxy is LAN-visible; garage never leaves the guest at all.
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
  # The demo CA is generated per install (`sudo nix run .#host-install`), so
  # it cannot be pinned in the flake. The boot wrapper exports its path (see
  # nix/scripts/microvm.sh, which refuses to boot without it); without
  # --impure getEnv reads "" and the guest simply trusts nothing extra, so
  # pure evaluation still works.
  caFile = builtins.getEnv "SELFHOSTIX_CA_FILE";
in {
  imports = [
    ./net.nix
    ./platform.nix
    ./services/docs.nix
    ./services/drive.nix
  ];

  demo.net = {
    inherit (guest) ip mac gateway dns;
    inherit (demo) domains;
  };

  demo.docs.domain = services.docs.domain;
  demo.drive.domain = services.drive.domain;
  # dex answers under this name through the proxy; browsers and the backends
  # therefore see one issuer URL, with one certificate.
  demo.oidc.issuer = "https://${demo.infra.auth.domain}/dex";

  # Trust the demo CA, so a backend reaching the issuer takes the same route
  # and validates the same certificate a browser does.
  security.pki.certificateFiles =
    lib.optional (caFile != "")
    (pkgs.writeText "selfhostix-demo-ca.crt" (builtins.readFile caFile));

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
  # Only what the host proxy dials over the tap: nginx (both app vhosts) and
  # dex. Garage binds loopback and is reached by nginx alone (../platform.nix),
  # and TLS is terminated on the host, so 443 and 9000 stay shut.
  networking.firewall.allowedTCPPorts = [80 8080];

  # Hand tools for poking at the stack from the guest console.
  environment.systemPackages = with pkgs; [curl jq garage_2];
}
