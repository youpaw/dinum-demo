set -euo pipefail
# Install the host reverse proxy (Debian host): Caddyfile + systemd unit.
#   sudo nix run .#host-install
# Both are generated from nix/services.nix (see nix/apps.nix) and substituted
# at build time, so the unit runs the Nix store Caddy directly — no `nix run`
# at runtime, no hardcoded checkout path, no hand-maintained guest IPs.
# Re-run after changing nix/services.nix: systemd and Caddy read the /etc copy.
[ "$(id -u)" = "0" ] || die "run as root: sudo nix run .#host-install"
install -D -m 0644 "@CADDYFILE@" /etc/selfhostix-demo/Caddyfile
install -D -m 0644 "@SERVICE@" /etc/systemd/system/selfhostix-caddy.service
systemctl daemon-reload
systemctl enable --now selfhostix-caddy.service
msg "host proxy installed (config: /etc/selfhostix-demo/Caddyfile, unit: selfhostix-caddy.service)"
