# Guest network options (etalon pattern): static tap address, the hostnames
# the guest answers to, and the browser origins it must trust.
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
  # Host part of an http(s):// origin (for ALLOWED_HOSTS).
  originHost = o: let
    noScheme = lib.removePrefix "http://" (lib.removePrefix "https://" o);
  in
    builtins.head (lib.splitString ":" noScheme);
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
      description = "Next hop (host tap endpoint).";
    };
    dns = lib.mkOption {
      type = lib.types.str;
      default = "10.19.254.254";
      description = "Guest resolver (host tap IP runs no DNS; use the LAN gateway like the host).";
    };
    domains = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      description = "Public hostnames of the services in this guest (one vhost each).";
    };
    publicOrigins = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      description = "Extra browser origins (e.g. the host LAN origin) trusted by the apps.";
    };

    hosts = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      readOnly = true;
      default = lib.unique (["localhost" "127.0.0.1" cfg.ip] ++ cfg.domains ++ map originHost cfg.publicOrigins);
      description = ''
        Every `Host` header browsers and the proxy send, for Django's
        ALLOWED_HOSTS. Without the guest IP and the LAN host, Django answers
        400 DisallowedHost on all bare-IP / proxied /api and /admin requests
        (nginx serves the frontend statically, so `/` loads fine while login
        breaks — the signature symptom).
      '';
    };
    origins = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      readOnly = true;
      default = lib.unique (map (h: "http://${h}") cfg.hosts ++ cfg.publicOrigins);
      description = ''
        Every browser origin, for Django's CSRF_TRUSTED_ORIGINS. Django >= 5.2
        checks Origin on ALL unsafe requests (browsers always send it, curl
        doesn't — which is why curl worked and browsers 403'd); a bare
        "http://*" never matches, so origins must be listed explicitly.
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

    networking.hosts."${cfg.ip}" = cfg.domains;
  };
}
