# Single source of truth for the demo's guest and the services it hosts.
#
# One microVM (`selfhostix`) runs every service: LaSuite Docs and LaSuite
# Drive share its kernel, its dex (mock OIDC), its garage (S3), its postgres
# and its nginx — the apps themselves namespace everything else (own gunicorn
# socket, own redis server, own database, own vhost).
#
# Consumed by:
#   - nix/guest.nix  (guest identity -> demo.net / demo.<service> options)
#   - nix/apps.nix   (the DEMO_SERVICES/<svc>_* shell table every app gets,
#                     and the generated host Caddyfile)
#
# Both `lasuite-docs` and `lasuite-drive` share the same core Django User
# model (admin_email/full_name/short_name/email/is_staff/is_active — same
# La Suite `core` app), which is what makes one generic user-propagation
# script safe across both.
{lib}: let
  guest = {
    hostName = "selfhostix";
    # Point-to-point tap link to the host. One guest means one wire: the
    # host end of the tap carries the gateway address itself, so there is no
    # bridge to unify taps behind (see nix/scripts/net-setup.sh).
    tap = "tap-selfhostix";
    ip = "192.168.100.10";
    mac = "52:54:00:64:78:0a";
    gateway = "192.168.100.1";
    # Guest egress goes through host NAT; resolve via the LAN gateway like
    # the host itself (the host tap address runs no DNS server).
    dns = "10.19.254.254";
  };

  services = {
    docs = {
      domain = "docs.selfhostix";
      manage = "lasuite-docs-manage";
      # Catch-all behind the host proxy: `/` reaches Docs, and Docs' nginx
      # vhost is the guest's default server, so bare-IP and LAN Host headers
      # land there too (see nix/services/docs.nix).
      prefix = null;
    };
    drive = {
      domain = "drive.selfhostix";
      manage = "lasuite-drive-manage";
      # Reached at `/drive/*`; the proxy rewrites Host to the domain above so
      # the guest's name-based vhosts still tell the two services apart.
      prefix = "/drive";
    };
  };

  domains = lib.mapAttrsToList (_: s: s.domain) services;
  catchAll = lib.filterAttrs (_: s: s.prefix == null) services;
in
  assert lib.assertMsg (lib.length (lib.unique domains) == lib.length domains)
  "nix/services.nix: duplicate service domain — two vhosts cannot share a name";
  assert lib.assertMsg (lib.length (lib.attrNames catchAll) == 1)
  "nix/services.nix: exactly one service must have `prefix = null` (the host proxy's catch-all)"; {
    inherit guest services;
  }
