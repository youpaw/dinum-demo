set -euo pipefail
# Provision N booted clients (hosts entries, autostart, bookmarks; needs seed).
#   nix run .#provision -- [N]
cd "${DEMO_ROOT:-$PWD}"

provision_one() { # $1=client-index $2=seed-url
  local idx="$1" seed_url="$2" svc domain port
  ensure_client_access "$idx"
  port="$(client_ssh_port "$idx")"
  msg "provisioning client c$idx (root@localhost:$port, seed: $seed_url)"
  # Every service domain resolves to the one guest; its nginx picks the vhost
  # by name (see nix/services.nix).
  for svc in $DEMO_SERVICES; do
    domain="$(service_domain "$svc")"
    ssh_client root localhost "$port" \
      "grep -q '$domain' /etc/hosts || echo '$SELFHOSTIX_IP $domain' >> /etc/hosts"
  done
  ssh_client root localhost "$port" "mkdir -p /home/alice/.config/autostart && cat > /home/alice/.config/autostart/selfhostix.desktop <<EOF
[Desktop Entry]
Type=Application
Name=Selfhostix seed document
Exec=xdg-open $seed_url
X-GNOME-Autostart-enabled=true
EOF
chown -R alice:users /home/alice/.config/autostart"
  ssh_client root localhost "$port" "mkdir -p /etc/firefox/policies && cat > /etc/firefox/policies/policies.json <<EOF
{
  \"policies\": {
    \"Homepage\": { \"URL\": \"$seed_url\", \"Start\": \"homepage\" },
    \"ManagedBookmarks\": [{ \"toplevel_name\": \"Demo\", \"children\": [{ \"name\": \"Shared demo doc\", \"url\": \"$seed_url\" }] }]
  }
}
EOF" || warn "firefox policy install failed on c$idx (non-fatal)"
  msg "client c$idx provisioned"
}

n="${1:-$NUM_CLIENTS}"
[ -f "$SEED_ENV" ] || die "no seed state: $SEED_ENV (run nix run .#seed first)"
# shellcheck disable=SC1090
. "$SEED_ENV"
seed_url="${SEED_DOC_URL:?seed env corrupt: $SEED_ENV}"
for i in $(seq 1 "$n"); do
  provision_one "$i" "$seed_url"
done
