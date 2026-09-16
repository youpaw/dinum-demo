# Docs service network overlay for the microVM guest (see ./microvm/docs-guest.nix).
#
# Args (all optional, override via `_module.args`):
#   docsIp   guest static IP             (default 192.168.100.10, tap net)
#   docsMac  guest NIC MAC matched by systemd-networkd
#   gateway  next hop                    (default 192.168.100.1, host tap)
#   dns      resolver
#   domain   public hostname             (default docs.selfhostix)
#   publicOrigins extra Django CSRF origins (proxy/host URLs hitting the guest)
{ config, pkgs, lib, ... }:
let
  docsIp = config._module.args.docsIp or "192.168.100.10";
  docsMac = config._module.args.docsMac or "52:54:00:64:78:0a";
  gateway = config._module.args.gateway or "192.168.100.1";
  dns = config._module.args.dns or "192.168.100.1";
  domain = config._module.args.domain or "docs.selfhostix";
  # Extra origins browsers may use that cannot be known at flake pin time:
  # the host LAN IP (DHCP). Boot wrappers export SELFHOSTIX_PUBLIC_ORIGIN (see
  # host/detect-origin.sh); without --impure, getEnv reads "" and this is
  # a no-op, so pure evaluation is unaffected.
  envOrigins =
    let v = builtins.getEnv "SELFHOSTIX_PUBLIC_ORIGIN"; in lib.optional (v != "") v;
  publicOrigins = (config._module.args.publicOrigins or [ ]) ++ envOrigins;
  # Host part of an http(s):// origin (for ALLOWED_HOSTS / nginx aliases).
  originHost = o:
    let noScheme = lib.removePrefix "http://" (lib.removePrefix "https://" o);
    in builtins.head (lib.splitString ":" noScheme);
  lanHosts = map originHost publicOrigins;
  # Reachable from clients AND from the backend itself. dex already binds
  # 0.0.0.0:8080 (see docs-vm.nix); the issuer must be a URL every party
  # (browser via proxy, backend on server) resolves identically, hence the
  # guest IP instead of 127.0.0.1.
  oidcBase = "http://${docsIp}:8080/dex";
  csrfDefaults = [
    "http://${domain}"
    "http://${docsIp}"
    "http://localhost"
    "http://127.0.0.1"
  ];
in
{
  networking.hostName = lib.mkDefault "selfhostix";

  # Static NIC matched on MAC (virtio names are unpredictable: ens3, eth1…);
  # anything else falls back to DHCP.
  systemd.network.enable = true;
  systemd.network.networks = {
    "10-demo-static" = {
      matchConfig.MACAddress = docsMac;
      networkConfig = {
        Address = "${docsIp}/24";
        Gateway = gateway;
        DNS = dns;
      };
    };
    "99-demo-dhcp" = {
      matchConfig.Name = "e*";
      networkConfig.DHCP = "yes";
    };
  };
  networking.useDHCP = lib.mkForce false;

  networking.hosts."${docsIp}" = [ domain ];

  services.lasuite-docs.settings = {
    # Browsers hit the proxy/host origins; Django >= 5.2 rejects unsafe
    # requests otherwise (see STARTUP.md CSRF note).
    DJANGO_CSRF_TRUSTED_ORIGINS = lib.mkForce
      (lib.concatStringsSep "," (lib.unique (csrfDefaults ++ publicOrigins)));
    # Every Host header browsers and the proxy send: without the guest IP
    # and the LAN host here, Django answers 400 DisallowedHost on all
    # bare-IP / proxied /api and /admin requests (nginx serves the
    # frontend statically, so / loads fine while login breaks).
    DJANGO_ALLOWED_HOSTS = lib.mkForce
      (lib.concatStringsSep "," (lib.unique
        ([ "localhost" "127.0.0.1" domain docsIp ] ++ lanHosts)));
    LOGIN_REDIRECT_URL = lib.mkForce "http://${domain}";
    LOGIN_REDIRECT_URL_FAILURE = lib.mkForce "http://${domain}";
    LOGOUT_REDIRECT_URL = lib.mkForce "http://${domain}";
    MEDIA_BASE_URL = lib.mkForce "http://${domain}";
    OIDC_OP_JWKS_ENDPOINT = lib.mkForce "${oidcBase}/keys";
    OIDC_OP_AUTHORIZATION_ENDPOINT = lib.mkForce "${oidcBase}/auth/mock";
    OIDC_OP_TOKEN_ENDPOINT = lib.mkForce "${oidcBase}/token";
    OIDC_OP_USER_ENDPOINT = lib.mkForce "${oidcBase}/userinfo";
  };

  services.dex.settings = {
    issuer = lib.mkForce oidcBase;
    staticClients = lib.mkForce [{
      id = "lasuite-docs";
      name = "Selfhostix";
      redirectURIs = [
        "http://${domain}/api/v1.0/callback/"
        "http://${docsIp}/api/v1.0/callback/"
      ];
      secretFile = "/etc/dex/lasuite-docs";
    }];
  };

  # Answer the same Host headers in nginx (name-based vhost otherwise
  # misses IP-based and LAN-proxied requests).
  services.nginx.virtualHosts.${domain}.serverAliases =
    lib.unique ([ docsIp ] ++ lanHosts);
}
