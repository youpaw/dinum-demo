set -euo pipefail
# Provision N booted clients: name resolution, the demo CA, autostart and
# bookmarks (needs seed).
#   nix run .#provision -- [N]
#
# This is the whole client-side setup the TLS names cost us: two lines in
# /etc/hosts pointing every demo name at the host proxy, and the CA imported
# into Firefox. Nothing else on the machine is touched.
cd "${DEMO_ROOT:-$PWD}"

provision_one() { # $1=client-index $2=seed-url $3=host-ip
  local idx="$1" seed_url="$2" host_ip="$3" domain port
  ensure_client_access "$idx"
  port="$(client_ssh_port "$idx")"
  msg "provisioning client c$idx (root@localhost:$port, seed: $seed_url)"

  # Every demo name resolves to the proxy, which holds the certificate for it.
  for domain in $DEMO_DOMAINS; do
    ssh_client root localhost "$port" \
      "grep -q ' $domain\$' /etc/hosts || echo '$host_ip $domain' >> /etc/hosts"
  done

  # Firefox keeps its own trust store, so the CA goes in by policy rather than
  # into the system bundle (which is read-only on a NixOS client anyway).
  ssh_client root localhost "$port" "mkdir -p /etc/firefox/certs && cat > /etc/firefox/certs/selfhostix-ca.crt" < "$CA_FILE"
  ssh_client root localhost "$port" "mkdir -p /etc/firefox/policies && cat > /etc/firefox/policies/policies.json <<EOF
{
  \"policies\": {
    \"Certificates\": { \"Install\": [\"/etc/firefox/certs/selfhostix-ca.crt\"] },
    \"Homepage\": { \"URL\": \"$seed_url\", \"Start\": \"homepage\" },
    \"ManagedBookmarks\": [{ \"toplevel_name\": \"Demo\", \"children\": [{ \"name\": \"Shared demo doc\", \"url\": \"$seed_url\" }] }]
  }
}
EOF" || warn "firefox policy install failed on c$idx (non-fatal)"

  ssh_client root localhost "$port" "mkdir -p /home/alice/.config/autostart && cat > /home/alice/.config/autostart/selfhostix.desktop <<EOF
[Desktop Entry]
Type=Application
Name=Selfhostix seed document
Exec=xdg-open $seed_url
X-GNOME-Autostart-enabled=true
EOF
chown -R alice:users /home/alice/.config/autostart"
  msg "client c$idx provisioned"
}

n="${1:-$NUM_CLIENTS}"
[ -f "$SEED_ENV" ] || die "no seed state: $SEED_ENV (run nix run .#seed first)"
[ -f "$CA_FILE" ] || die "demo CA missing: $CA_FILE (run: sudo nix run .#host-install)"
# shellcheck disable=SC1090
. "$SEED_ENV"
seed_url="${SEED_DOC_URL:?seed env corrupt: $SEED_ENV}"
host_ip="$(host_lan_ip)"
msg "clients will reach the demo at $host_ip ($DEMO_DOMAINS)"
for i in $(seq 1 "$n"); do
  provision_one "$i" "$seed_url" "$host_ip"
done
