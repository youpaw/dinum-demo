# Shared Docs VM module — adapted from nixos/tests/web-apps/lasuite-docs.nix
# Runs entirely on loopback: nginx :80, dex :8080, garage S3 :9000.
{ config, pkgs, lib, ... }:
let
  domain = "docs.local";
  oidcAddr = "127.0.0.1:8080";
  s3Addr = "127.0.0.1:9000";
  garageAccessKey = "GKaaaaaaaaaaaaaaaaaaaaaaaa";
  garageSecretKey = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
in
{
  system.stateVersion = "25.11";
  time.timeZone = "UTC";
  networking.hostName = lib.mkDefault "docs-quickstart";
  networking.hosts."127.0.0.1" = [ domain ];

  # We boot the baked qcow2 standalone (direct qemu / libvirt import),
  # NOT via the NixOS runner's virtiofs host-store shares.
  # qemu-vm.nix options only exist inside the VM variant, hence the
  # vmVariant paths below. mkForce is required: qemu-vm.nix *merges*
  # xchg/shared entries into sharedDirectories, plain {} would not delete them.
  virtualisation.vmVariant.virtualisation.sharedDirectories = lib.mkForce { };
  virtualisation.vmVariantWithBootLoader.virtualisation.sharedDirectories = lib.mkForce { };
  # Boot the bootloader image via direct kernel boot in the runner too
  # (same method as boot.sh): avoids GRUB-on-serial blindness and lets the
  # runner pass the correct init=/regInfo= cmdline for the variant closure.
  virtualisation.vmVariantWithBootLoader.virtualisation.directBoot.enable = true;

  # Easy console access for an ephemeral VM (do NOT reuse for real testing VM
  # without changing — see testing-vm.nix).
  users.users.root.password = "root";
  services.getty.autologinUser = lib.mkDefault "root";
  services.openssh.enable = true;
  services.openssh.settings.PermitRootLogin = "yes";
  # 80/443 nginx; 8080 dex and 9000 garage-S3 are only reachable from the
  # host via QEMU SLIRP forwards (guest eth0), so the firewall must allow
  # them even though nothing listens on 0.0.0.0:80-style public sockets.
  networking.firewall.allowedTCPPorts = [ 80 443 8080 9000 ];

  environment.systemPackages = with pkgs; [ curl jq garage_2 ];

  services.lasuite-docs = {
    enable = true;
    enableNginx = true;
    redis.createLocally = true;
    postgresql.createLocally = true;
    inherit domain;
    s3Url = "http://${s3Addr}/lasuite-docs";
    settings = {
      DJANGO_SECRET_KEY_FILE = pkgs.writeText "django-secret-file" ''
        8540db59c03943d48c3ed1a0f96ce3b560e0f45274f120f7ee4dace3cc366a6b
      '';
      OIDC_OP_JWKS_ENDPOINT = "http://${oidcAddr}/dex/keys";
      OIDC_OP_AUTHORIZATION_ENDPOINT = "http://${oidcAddr}/dex/auth/mock";
      OIDC_OP_TOKEN_ENDPOINT = "http://${oidcAddr}/dex/token";
      OIDC_OP_USER_ENDPOINT = "http://${oidcAddr}/dex/userinfo";
      OIDC_RP_CLIENT_ID = "lasuite-docs";
      OIDC_RP_SIGN_ALGO = "RS256";
      OIDC_RP_SCOPES = "openid email";
      OIDC_RP_CLIENT_SECRET = "lasuitedocsclientsecret";
      LOGIN_REDIRECT_URL = "http://${domain}";
      LOGIN_REDIRECT_URL_FAILURE = "http://${domain}";
      LOGOUT_REDIRECT_URL = "http://${domain}";
      AWS_S3_ENDPOINT_URL = "http://${s3Addr}";
      AWS_S3_ACCESS_KEY_ID = garageAccessKey;
      AWS_S3_SECRET_ACCESS_KEY = garageSecretKey;
      AWS_STORAGE_BUCKET_NAME = "lasuite-docs";
      MEDIA_BASE_URL = "http://${domain}";
      # HTTP-only loopback (no TLS) — same as NixOS test
      DJANGO_SECURE_PROXY_SSL_HEADER = "";
      DJANGO_SECURE_SSL_REDIRECT = false;
      DJANGO_CSRF_COOKIE_SECURE = false;
      DJANGO_SESSION_COOKIE_SECURE = false;
      # Django ≥5.2 checks Origin on ALL unsafe requests (browsers always send
      # it, curl doesn't — which is why curl worked and browsers 403'd).
      # Must be explicit origins with port; a bare "http://*" never matches.
      DJANGO_CSRF_TRUSTED_ORIGINS = "http://docs.local:8081,http://localhost:8081,http://127.0.0.1:8081";
    };
  };

  services.dex = {
    enable = true;
    settings = {
      issuer = "http://${oidcAddr}/dex";
      storage = { type = "postgres"; config.host = "/var/run/postgresql"; };
      # 0.0.0.0: QEMU SLIRP forwards arrive on the guest eth0 address, not
      # 127.0.0.1. Still host-loopback-only (reached via host port forwards).
      web.http = "0.0.0.0:8080";
      oauth2.skipApprovalScreen = true;
      staticClients = [{
        id = "lasuite-docs";
        name = "Docs";
        redirectURIs = [ "http://${domain}/api/v1.0/callback/" ];
        secretFile = "/etc/dex/lasuite-docs";
      }];
      connectors = [{
        type = "mockPassword"; id = "mock"; name = "Example";
        config = { username = "admin"; password = "password"; };
      }];
    };
  };
  environment.etc."dex/lasuite-docs" = {
    mode = "0400"; user = "dex"; text = "lasuitedocsclientsecret";
  };

  services.garage = {
    enable = true;
    package = pkgs.garage_2;
    settings = {
      rpc_bind_addr = "127.0.0.1:3901";
      rpc_public_addr = "127.0.0.1:3901";
      rpc_secret = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
      replication_factor = 1;
      s3_api = {
        s3_region = "garage";
        # 0.0.0.0 for the same SLIRP reason as dex above.
        api_bind_addr = "0.0.0.0:9000";
      };
    };
  };

  services.postgresql = {
    ensureDatabases = [ "dex" ];
    ensureUsers = [{ name = "dex"; ensureDBOwnership = true; }];
  };

  # Auto-create garage layout + bucket on first boot (manual in NixOS test).
  systemd.services.garage-bootstrap = {
    description = "Bootstrap garage single-node layout + lasuite-docs bucket";
    after = [ "garage.service" "network.target" ];
    wants = [ "garage.service" ];
    wantedBy = [ "multi-user.target" ];
    path = [ pkgs.garage_2 pkgs.gawk ];
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
    script = ''
      set -eux
      for i in $(seq 1 60); do
        garage status >/dev/null 2>&1 && break
        sleep 2
      done
      if garage layout show | grep -qE 'Current cluster layout version: [1-9]'; then
        echo "garage layout already committed, skipping assign/apply"
      else
        NODE_ID=$(garage status | tail -n1 | awk '{ print $1 }')
        garage layout assign -c 100MB -z garage "$NODE_ID"
        garage layout apply --version 1
      fi
      garage key import "${garageAccessKey}" "${garageSecretKey}" --yes || true
      garage bucket create lasuite-docs || true
      garage bucket allow --read --write --owner lasuite-docs --key "${garageAccessKey}" || true
      echo "garage bootstrap done"
    '';
  };
}
