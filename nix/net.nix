# Guest network options (etalon pattern): static tap address, the names the
# guest knows, and the origins its apps must trust.
#
# nix/guest.nix sets these from nix/services.nix; the service modules read the
# derived `hosts`/`origins` lists instead of each re-deriving them. No service
# logic here, no shell: pure and overridable.
{
  config,
  lib,
  ...
}: let
  cfg = config.demo.net;
in {
  options.demo.net = {
    ip = lib.mkOption {
      type = lib.types.str;
      description = "Guest static IPv4 on the tap link (192.168.100.0/24).";
    };
    mac = lib.mkOption {
      type = lib.types.str;
      description = "Guest NIC MAC matched by systemd-networkd (virtio names are unpredictable).";
    };
    gateway = lib.mkOption {
      type = lib.types.str;
      default = "192.168.100.1";
      description = "Next hop (host tap endpoint), which is also where the proxy listens.";
    };
    dns = lib.mkOption {
      type = lib.types.str;
      default = "10.19.254.254";
      description = "Guest resolver (host tap IP runs no DNS; use the LAN gateway like the host).";
    };
    domains = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      description = "Every name the host proxy terminates for this guest.";
    };
    proxy = lib.mkOption {
      type = lib.types.str;
      default = cfg.gateway;
      description = ''
        Address the guest itself resolves `domains` to. The host proxy, not
        the guest: a backend calling the OIDC issuer must take the same route
        and see the same certificate a browser does, so the guest's view of
        these names matches the outside world's.
      '';
    };

    hosts = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      readOnly = true;
      default = lib.unique (["localhost" "127.0.0.1" cfg.ip] ++ cfg.domains);
      description = ''
        Every `Host` header the apps may see, for Django's ALLOWED_HOSTS.
        Without them Django answers 400 DisallowedHost on /api and /admin
        while `/` still loads (nginx serves the frontend statically, so a
        working homepage with broken login is the signature symptom).
      '';
    };
    origins = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      readOnly = true;
      default = map (d: "https://${d}") cfg.domains;
      description = ''
        Every browser origin, for Django's CSRF_TRUSTED_ORIGINS. Django >= 5.2
        checks Origin on ALL unsafe requests (browsers always send it, curl
        doesn't — which is why curl worked and browsers 403'd); a bare
        "https://*" never matches, so origins must be listed explicitly.
        HTTPS only: the proxy redirects plain HTTP to it.
      '';
    };
  };

  config = {
    # Static NIC matched on MAC; anything else falls back to DHCP.
    systemd.network.enable = true;
    systemd.network.networks = {
      "10-demo-static" = {
        matchConfig.MACAddress = cfg.mac;
        networkConfig = {
          Address = "${cfg.ip}/24";
          Gateway = cfg.gateway;
          DNS = cfg.dns;
        };
      };
      "99-demo-dhcp" = {
        matchConfig.Name = "e*";
        networkConfig.DHCP = "yes";
      };
    };
    networking.useDHCP = lib.mkForce false;

    networking.hosts."${cfg.proxy}" = cfg.domains;
  };
}
