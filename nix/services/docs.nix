# LaSuite Docs on the shared guest — adapted from
# nixos/tests/web-apps/lasuite-docs.nix.
#
# Only the app itself lives here: the mock OIDC provider, the S3 backend and
# postgres are the guest's shared platform (../platform.nix), and every Host
# header / browser origin comes from ../net.nix.
{
  config,
  pkgs,
  lib,
  ...
}: let
  cfg = config.demo.docs;
  net = config.demo.net;
  oidc = config.demo.oidc;
  s3 = config.demo.s3;
  bucket = "lasuite-docs";
in {
  options.demo.docs.domain = lib.mkOption {
    type = lib.types.str;
    default = "docs.selfhostix";
    description = "Public hostname of the Docs vhost (set from ../services.nix).";
  };

  config = {
    demo.oidc.clients.lasuite-docs = {
      name = "Selfhostix";
      secret = "lasuitedocsclientsecret";
      redirectURIs = map (o: "${o}/api/v1.0/callback/") net.origins;
    };

    demo.s3.buckets.${bucket} = {
      accessKey = "GKaaaaaaaaaaaaaaaaaaaaaaaa";
      secretKey = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    };

    services.lasuite-docs = {
      enable = true;
      enableNginx = true;
      redis.createLocally = true;
      postgresql.createLocally = true;
      domain = cfg.domain;
      s3Url = "${s3.endpoint}/${bucket}";
      settings = {
        DJANGO_SECRET_KEY_FILE = pkgs.writeText "django-secret-file" ''
          8540db59c03943d48c3ed1a0f96ce3b560e0f45274f120f7ee4dace3cc366a6b
        '';
        DJANGO_ALLOWED_HOSTS = lib.concatStringsSep "," net.hosts;
        DJANGO_CSRF_TRUSTED_ORIGINS = lib.concatStringsSep "," net.origins;
        OIDC_OP_JWKS_ENDPOINT = "${oidc.issuer}/keys";
        OIDC_OP_AUTHORIZATION_ENDPOINT = "${oidc.issuer}/auth/mock";
        OIDC_OP_TOKEN_ENDPOINT = "${oidc.issuer}/token";
        OIDC_OP_USER_ENDPOINT = "${oidc.issuer}/userinfo";
        OIDC_RP_CLIENT_ID = "lasuite-docs";
        OIDC_RP_SIGN_ALGO = "RS256";
        OIDC_RP_SCOPES = "openid email";
        OIDC_RP_CLIENT_SECRET = config.demo.oidc.clients.lasuite-docs.secret;
        LOGIN_REDIRECT_URL = "http://${cfg.domain}";
        LOGIN_REDIRECT_URL_FAILURE = "http://${cfg.domain}";
        LOGOUT_REDIRECT_URL = "http://${cfg.domain}";
        MEDIA_BASE_URL = "http://${cfg.domain}";
        AWS_S3_ENDPOINT_URL = s3.endpoint;
        AWS_S3_ACCESS_KEY_ID = s3.buckets.${bucket}.accessKey;
        AWS_S3_SECRET_ACCESS_KEY = s3.buckets.${bucket}.secretKey;
        AWS_STORAGE_BUCKET_NAME = bucket;
        # HTTP-only (no TLS) — same as the NixOS test.
        DJANGO_SECURE_PROXY_SSL_HEADER = "";
        DJANGO_SECURE_SSL_REDIRECT = false;
        DJANGO_CSRF_COOKIE_SECURE = false;
        DJANGO_SESSION_COOKIE_SECURE = false;
      };
    };

    # Docs owns every Host header that isn't a service domain: bare guest IP,
    # the host LAN address, whatever a browser invents. The host proxy routes
    # `/` here and rewrites Host only for the prefixed services (see
    # nix/apps.nix), so one default server is all the disambiguation needed.
    services.nginx.virtualHosts.${cfg.domain}.default = true;

    # Soft ordering behind the shared garage bootstrap (../platform.nix).
    systemd.services.lasuite-docs = {
      wants = ["garage-bootstrap.service"];
      after = ["garage-bootstrap.service"];
    };
  };
}
