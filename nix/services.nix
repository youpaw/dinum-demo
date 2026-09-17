# Single source of truth for the demo's guest and the names it serves.
#
# One microVM (`selfhostix`) runs every service: LaSuite Docs and LaSuite
# Drive share its kernel, its dex (mock OIDC), its garage (S3), its postgres
# and its nginx — the apps themselves namespace everything else (own gunicorn
# socket, own redis server, own database, own vhost).
#
# Every name below is terminated by the host proxy over TLS and forwarded into
# the guest as plain HTTP on the tap link. Name-based routing is not a style
# choice: Docs and Drive are both SPAs that call /api/v1.0/... at their origin
# root, so they cannot share one origin under a path prefix.
#
# Consumed by:
#   - nix/guest.nix  (guest identity -> demo.net / demo.<service> options)
#   - nix/apps.nix   (the DEMO_SERVICES/<svc>_* shell table every app gets,
#                     the generated host Caddyfile, and the cert SAN list)
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

  # Django apps: each is a user-propagation target (its own `manage` command)
  # and an nginx vhost inside the guest, reached on :80 by name.
  services = {
    docs = {
      domain = "docs.selfhostix";
      manage = "lasuite-docs-manage";
    };
    drive = {
      domain = "drive.selfhostix";
      manage = "lasuite-drive-manage";
    };
  };

  # Names the proxy terminates that are not Django apps: they go straight to a
  # guest port instead of the guest's nginx.
  #
  # dex is here because the OIDC issuer must be one URL that browsers and the
  # backends both resolve and trust; on a raw guest IP:port it was reachable
  # only from the tap link, which is why the demo used password login.
  #
  # garage is deliberately NOT here: both apps proxy /media/ to S3 through
  # their own nginx vhost (signed by `auth_request`), so nothing in a browser
  # ever addresses S3 directly and a public s3. name would be dead surface.
  infra = {
    auth = {
      domain = "auth.selfhostix";
      port = 8080;
    };
  };

  domains = lib.mapAttrsToList (_: s: s.domain) (services // infra);
in
  assert lib.assertMsg (lib.length (lib.unique domains) == lib.length domains)
  "nix/services.nix: duplicate domain — two sites cannot share a name"; {
    inherit guest services infra domains;
  }
