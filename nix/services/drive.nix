# LaSuite Drive on the shared guest — mirrors ./docs.nix.
#
# Served under its own name, so its frontend owns /api/v1.0/... at the origin
# root the way it expects; inside the guest it is an ordinary name-based nginx
# vhost next to Docs, sharing the platform's dex/garage/postgres
# (../platform.nix).
{
  config,
  pkgs,
  lib,
  ...
}: let
  cfg = config.demo.drive;
  net = config.demo.net;
  oidc = config.demo.oidc;
  s3 = config.demo.s3;
  bucket = "lasuite-drive";
in {
  options.demo.drive.domain = lib.mkOption {
    type = lib.types.str;
    default = "drive.selfhostix";
    description = "Public hostname of the Drive vhost (set from ../services.nix).";
  };

  config = {
    demo.oidc.clients.lasuite-drive = {
      name = "Drive";
      secret = "lasuitedriveclientsecret";
      # Only this app's own callback: every extra entry is somewhere dex
      # would be willing to send a code to.
      redirectURIs = ["https://${cfg.domain}/api/v1.0/callback/"];
    };

    demo.s3.buckets.${bucket} = {
      accessKey = "GKbbbbbbbbbbbbbbbbbbbbbbbb";
      secretKey = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    };

    services.lasuite-drive = {
      enable = true;
      enableNginx = true;
      redis.createLocally = true;
      postgresql.createLocally = true;
      domain = cfg.domain;
      # Trailing slash: nginx proxy_pass to the media bucket needs it.
      s3Url = "${s3.endpoint}/${bucket}/";
      # Works around a bug in nixpkgs' lasuite-drive-manage wrapper: it
      # interpolates this list onto its own line inside a `\`-continued
      # systemd-run command, so an empty list leaves a whitespace-only line
      # that ends the command early — every `lasuite-drive-manage <cmd>` then
      # dies with "Command line to execute required." (lasuite-docs has no
      # such interpolation, which is why only Drive breaks, and why user
      # propagation reached Docs but not Drive). One file, even an empty one,
      # keeps the continuation intact; harmless once upstream is fixed.
      environmentFiles = [(pkgs.writeText "lasuite-drive-extra.env" "")];
      settings = {
        DJANGO_SECRET_KEY_FILE = pkgs.writeText "django-secret-file" ''
          1c7f2a4e9b6d0834517ecfa2b9046d7c1a8e5f30964b2d7ea1c50f836b924d7f
        '';
        # Unlike lasuite-docs's freeform (str) settings, lasuite-drive's own
        # DJANGO_ALLOWED_HOSTS option is `listOf str` and joins with "," itself.
        DJANGO_ALLOWED_HOSTS = net.hosts;
        DJANGO_CSRF_TRUSTED_ORIGINS = lib.concatStringsSep "," net.origins;
        OIDC_OP_JWKS_ENDPOINT = "${oidc.issuer}/keys";
        OIDC_OP_AUTHORIZATION_ENDPOINT = "${oidc.issuer}/auth/mock";
        OIDC_OP_TOKEN_ENDPOINT = "${oidc.issuer}/token";
        OIDC_OP_USER_ENDPOINT = "${oidc.issuer}/userinfo";
        OIDC_RP_CLIENT_ID = "lasuite-drive";
        OIDC_RP_SIGN_ALGO = "RS256";
        OIDC_RP_SCOPES = "openid email";
        OIDC_RP_CLIENT_SECRET = config.demo.oidc.clients.lasuite-drive.secret;
        LOGIN_REDIRECT_URL = "https://${cfg.domain}";
        LOGIN_REDIRECT_URL_FAILURE = "https://${cfg.domain}";
        LOGOUT_REDIRECT_URL = "https://${cfg.domain}";
        AWS_S3_ENDPOINT_URL = s3.endpoint;
        AWS_S3_ACCESS_KEY_ID = s3.buckets.${bucket}.accessKey;
        AWS_S3_SECRET_ACCESS_KEY = s3.buckets.${bucket}.secretKey;
        AWS_STORAGE_BUCKET_NAME = bucket;
        # Same forwarded-header handling as Docs (see ./docs.nix).
        DJANGO_SECURE_PROXY_SSL_HEADER = "HTTP_X_FORWARDED_PROTO,https";
        DJANGO_SECURE_SSL_REDIRECT = false;
        DJANGO_CSRF_COOKIE_SECURE = true;
        DJANGO_SESSION_COOKIE_SECURE = true;
      };
    };

    # nixpkgs' lasuite-drive module orders its services `after
    # network-online.target` without `wants`-ing it (systemd warns on eval);
    # lasuite-docs doesn't have this gap. Soft ordering behind the shared
    # garage bootstrap comes from ../platform.nix, as for Docs.
    systemd.services = {
      lasuite-drive = {
        wants = ["network-online.target" "garage-bootstrap.service"];
        after = ["garage-bootstrap.service"];
      };
      lasuite-drive-celery.wants = ["network-online.target"];
      lasuite-drive-beat.wants = ["network-online.target"];
    };
  };
}
