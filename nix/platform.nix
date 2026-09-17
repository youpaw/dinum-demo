# Backing services every app on the guest shares: dex (mock OIDC), garage
# (S3) and the postgres instance behind them.
#
# Each service module registers what it needs through options rather than
# redefining the backends: an OIDC client (`demo.oidc.clients.<id>`) and an S3
# bucket with its key pair (`demo.s3.buckets.<name>`). One dex, one garage,
# one bootstrap unit — the per-service duplication lived here before the two
# guests were merged into one.
{
  config,
  pkgs,
  lib,
  ...
}: let
  oidc = config.demo.oidc;
  s3 = config.demo.s3;
in {
  options.demo.oidc = {
    issuer = lib.mkOption {
      type = lib.types.str;
      default = "http://${config.demo.net.ip}:8080/dex";
      description = ''
        OIDC issuer URL. Must be reachable from clients AND from the backends
        themselves, and identical for both: hence the guest tap address rather
        than 127.0.0.1 (dex binds 0.0.0.0:8080 below).
      '';
    };
    clients = lib.mkOption {
      default = {};
      description = "dex static clients, keyed by client id, with their demo secret.";
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          name = lib.mkOption {
            type = lib.types.str;
            description = "Display name on the login screen.";
          };
          secret = lib.mkOption {
            type = lib.types.str;
            description = "Client secret (demo-only; written to /etc/dex/<id>, mode 0400).";
          };
          redirectURIs = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            description = "Allowed OIDC callback URLs.";
          };
        };
      });
    };
  };

  options.demo.s3 = {
    endpoint = lib.mkOption {
      type = lib.types.str;
      default = "http://127.0.0.1:9000";
      description = "S3 endpoint the apps use (garage, guest-local).";
    };
    buckets = lib.mkOption {
      default = {};
      description = "Garage buckets to create on first boot, keyed by bucket name.";
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          accessKey = lib.mkOption {
            type = lib.types.str;
            description = "S3 access key id (demo-only, imported into garage at bootstrap).";
          };
          secretKey = lib.mkOption {
            type = lib.types.str;
            description = "S3 secret key (demo-only).";
          };
        };
      });
    };
  };

  config = {
    services.dex = {
      enable = true;
      settings = {
        issuer = oidc.issuer;
        storage = {
          type = "postgres";
          config.host = "/var/run/postgresql";
        };
        # 0.0.0.0: reached from browsers via the guest NIC address, not 127.0.0.1.
        web.http = "0.0.0.0:8080";
        oauth2.skipApprovalScreen = true;
        staticClients =
          lib.mapAttrsToList (id: c: {
            inherit id;
            inherit (c) name redirectURIs;
            secretFile = "/etc/dex/${id}";
          })
          oidc.clients;
        connectors = [
          {
            type = "mockPassword";
            id = "mock";
            name = "Example";
            config = {
              username = "admin";
              password = "password";
            };
          }
        ];
      };
    };
    environment.etc = lib.mapAttrs' (id: c:
      lib.nameValuePair "dex/${id}" {
        mode = "0400";
        user = "dex";
        text = c.secret;
      })
    oidc.clients;

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
          # 0.0.0.0 for the same reason as dex above.
          api_bind_addr = "0.0.0.0:9000";
        };
      };
    };

    services.postgresql = {
      ensureDatabases = ["dex"];
      ensureUsers = [
        {
          name = "dex";
          ensureDBOwnership = true;
        }
      ];
    };

    # Auto-create the garage layout + every registered bucket on first boot
    # (manual in the NixOS test). Apps order themselves behind this unit with
    # `wants`/`after` (not `requires`), so a bad garage day degrades instead
    # of failing the app outright — see nix/services/docs.nix.
    systemd.services.garage-bootstrap = {
      description = "Bootstrap garage single-node layout + demo buckets";
      after = ["garage.service" "network.target"];
      wants = ["garage.service"];
      wantedBy = ["multi-user.target"];
      path = [pkgs.garage_2 pkgs.gawk];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
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
        ${lib.concatStringsSep "\n" (lib.mapAttrsToList (bucket: b: ''
            garage key import "${b.accessKey}" "${b.secretKey}" --yes || true
            garage bucket create ${bucket} || true
            garage bucket allow --read --write --owner ${bucket} --key "${b.accessKey}" || true
          '')
          s3.buckets)}
        echo "garage bootstrap done"
      '';
    };
  };
}
