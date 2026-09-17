set -euo pipefail
# Install the host reverse proxy (Debian host): certificate, Caddyfile,
# systemd unit.
#   sudo nix run .#host-install
# The Caddyfile and unit are generated from nix/services.nix (see nix/apps.nix)
# and substituted at build time, so the unit runs the Nix store Caddy directly
# — no `nix run` at runtime, no hardcoded checkout path, no hand-maintained
# guest IPs. Re-run after changing nix/services.nix: systemd and Caddy read the
# /etc copy, and a new name needs a new certificate.
[ "$(id -u)" = "0" ] || die "run as root: sudo nix run .#host-install"

CERT_DIR="@CERTDIR@"
SANS="@SANS@"

# The CA is what clients and the guest trust; the leaf covers every name the
# proxy serves. Both are regenerated only when missing or when the name set
# changed, so re-running this never invalidates trust already distributed.
install -d -m 0755 "$CERT_DIR"
if [ ! -f "$CERT_DIR/ca.crt" ]; then
  msg "generating demo CA in $CERT_DIR"
  openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 3650 \
    -keyout "$CERT_DIR/ca.key" -out "$CERT_DIR/ca.crt" \
    -subj "/CN=Selfhostix demo CA" \
    -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" 2>/dev/null
  chmod 0400 "$CERT_DIR/ca.key"
  chmod 0644 "$CERT_DIR/ca.crt"
  rm -f "$CERT_DIR/site.crt"   # any leaf from an older CA is now untrusted
fi

current_sans() { # SANs in the installed leaf, normalised for comparison
  [ -f "$CERT_DIR/site.crt" ] || return 0
  openssl x509 -in "$CERT_DIR/site.crt" -noout -ext subjectAltName 2>/dev/null \
    | tr -d ' ' | grep '^DNS:' || true
}

if [ "$(current_sans)" != "$SANS" ]; then
  msg "issuing certificate for $SANS"
  openssl req -newkey rsa:2048 -nodes -sha256 \
    -keyout "$CERT_DIR/site.key" -out "$CERT_DIR/site.csr" \
    -subj "/CN=${SANS#DNS:}" 2>/dev/null
  # 825 days: the longest lifetime browsers accept without complaint.
  openssl x509 -req -in "$CERT_DIR/site.csr" -days 825 -sha256 \
    -CA "$CERT_DIR/ca.crt" -CAkey "$CERT_DIR/ca.key" -CAcreateserial \
    -out "$CERT_DIR/site.crt" \
    -extfile <(printf 'subjectAltName=%s\nextendedKeyUsage=serverAuth\n' "$SANS") 2>/dev/null
  rm -f "$CERT_DIR/site.csr"
  chmod 0400 "$CERT_DIR/site.key"
  chmod 0644 "$CERT_DIR/site.crt"
else
  msg "certificate already covers $SANS"
fi

# The guest reads the CA at build time and the clients have it installed, so
# leave a copy the unprivileged demo apps can read (see nix/scripts/lib.sh).
install -D -m 0644 "$CERT_DIR/ca.crt" "$DEMO_ROOT/data/certs/ca.crt"
[ -n "${SUDO_USER:-}" ] && chown -R "$SUDO_USER" "$DEMO_ROOT/data/certs"

install -D -m 0644 "@CADDYFILE@" /etc/selfhostix-demo/Caddyfile
install -D -m 0644 "@SERVICE@" /etc/systemd/system/selfhostix-caddy.service
systemctl daemon-reload
systemctl enable --now selfhostix-caddy.service
systemctl reload-or-restart selfhostix-caddy.service

msg "host proxy installed (config: /etc/selfhostix-demo/Caddyfile, unit: selfhostix-caddy.service)"
msg "demo CA: $CERT_DIR/ca.crt (copy at $DEMO_ROOT/data/certs/ca.crt)"
