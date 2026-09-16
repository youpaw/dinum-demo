#!/usr/bin/env bash
# Single propagation script for the Selfhostix collaboration demo.
#
# Unifies what used to be three scripts (users.sh, demo-seed.sh,
# clients/provision-client.sh): one flow, one SSH helper, one env resolution.
#
#   ./propagate.sh users [upsert|list|check|set-password|delete]  manage Selfhostix users
#   ./propagate.sh seed                                           create the shared demo doc (needs users)
#   ./propagate.sh provision [N]                                  provision N booted clients (needs seed)
#   ./propagate.sh all                                           users upsert + seed + provision
#
# Service-aware by design: per-service state (users, docs) lives in the
# step functions below; drive/grist slots plug into the same flow later.
#
# Env (all optional):
#   MICROVM_IP=192.168.100.10        guest address (tap net)
#   SELFHOSTIX_SSH_TARGET=...        SSH target for users/seed (default MICROVM_IP)
#   SELFHOSTIX_IP=...                IP clients use for docs.selfhostix (default MICROVM_IP)
#   SELFHOSTIX_URL=...               seed link base (default: detected host origin)
#   USERS_FILE=./data/users.env      managed users (created by `users init`, mode 0600)
#   SEED_ENV=./data/seed.env         written by `seed` (doc id + URL)
#   SEED_DOC_TITLE=...  SHARE_WITH=... (default: 2nd user)  OWNER=... (default: 1st user)
#   OWNER_PASS=... (or per-id pass from USERS_FILE)  ALICE_PASS=/BOB_PASS=... (CI overrides)
#   NUM_CLIENTS=2  CLIENT_SSH_BASE=2221 (client i on localhost:2220+i)
#   KEY_DIR=./data/demo-ssh  DATA_DIR=./data
set -euo pipefail
cd "$(dirname "$0")"

msg() { printf '==> %s\n' "$*"; }
warn() { printf '!! %s\n' "$*" >&2; }
die() { printf 'XX %s\n' "$*" >&2; exit 1; }

MICROVM_IP="${MICROVM_IP:-192.168.100.10}"
SELFHOSTIX_IP="${SELFHOSTIX_IP:-$MICROVM_IP}"
SELFHOSTIX_SSH_TARGET="${SELFHOSTIX_SSH_TARGET:-$MICROVM_IP}"
DATA_DIR="${DATA_DIR:-$PWD/data}"
KEY_DIR="${KEY_DIR:-$DATA_DIR/demo-ssh}"
USERS_FILE="${USERS_FILE:-$DATA_DIR/users.env}"
SEED_ENV="${SEED_ENV:-$DATA_DIR/seed.env}"
NUM_CLIENTS="${NUM_CLIENTS:-2}"
CLIENT_SSH_BASE="${CLIENT_SSH_BASE:-2221}"
SEED_DOC_TITLE="${SEED_DOC_TITLE:-Demo — live collaboration}"
# Nix lives outside PATH on some hosts; resolved lazily by install_demo_key.
NIX_BIN="${NIX_BIN:-$(command -v nix 2>/dev/null || echo /nix/var/nix/profiles/default/bin/nix)}"
GUEST_ROOT_PASS="${GUEST_ROOT_PASS:-root}"      # docs guest (see docs-vm.nix)
CLIENT_ROOT_PASS="${CLIENT_ROOT_PASS:-nixos}"   # bureautix-example default

# --- demo SSH key: generate locally, install on targets ---------------------

ensure_demo_key() {
  if [ ! -f "$KEY_DIR/demo" ]; then
    msg "generating demo SSH key in $KEY_DIR"
    mkdir -p "$KEY_DIR"
    ssh-keygen -t ed25519 -N "" -f "$KEY_DIR/demo" -C "selfhostix" >/dev/null
    chmod 600 "$KEY_DIR/demo" "$KEY_DIR/demo.pub"
  fi
}

key_works() { # $1=user $2=host $3=port — BatchMode probe, no side effects
  ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=5 -p "$3" -i "$KEY_DIR/demo" "$1@$2" true 2>/dev/null
}

install_demo_key() { # $1=user $2=host $3=port $4=password — one-time password auth
  [ -x "$NIX_BIN" ] || die "nix binary not executable: $NIX_BIN (set NIX_BIN explicitly)"
  msg "installing demo SSH key on $1@$2 (one-time password auth)"
  local keydata; keydata="$(cat "$KEY_DIR/demo.pub")"
  "$NIX_BIN" --extra-experimental-features 'nix-command flakes' run nixpkgs#sshpass -- \
    -p"$4" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p "$3" "$1@$2" \
    "mkdir -p ~/.ssh && chmod 700 ~/.ssh && grep -qF '$keydata' ~/.ssh/authorized_keys 2>/dev/null || echo '$keydata' >> ~/.ssh/authorized_keys"
}

ensure_guest_access() { # key auth to the docs guest, installing the key if needed
  ensure_demo_key
  key_works root "$SELFHOSTIX_SSH_TARGET" 22 || install_demo_key root "$SELFHOSTIX_SSH_TARGET" 22 "$GUEST_ROOT_PASS"
  key_works root "$SELFHOSTIX_SSH_TARGET" 22 || die "key auth still failing for root@$SELFHOSTIX_SSH_TARGET (wrong GUEST_ROOT_PASS?)"
}

ensure_client_access() { # $1=client-index — key auth to a booted client
  ensure_demo_key
  local port; port="$(client_ssh_port "$1")"
  key_works root localhost "$port" || install_demo_key root localhost "$port" "$CLIENT_ROOT_PASS"
  key_works root localhost "$port" || die "key auth still failing for client c$1 (localhost:$port; is it booted?)"
}

client_ssh_port() { # $1=client-index -> localhost hostfwd port (c1 -> 2221, …)
  echo "$((CLIENT_SSH_BASE + $1 - 1))"
}

# --- shared helpers --------------------------------------------------------

# NOTE: UserKnownHostsFile=/dev/null — the guest is rebuilt regularly (new
# host keys each rebuild); pinning keys would brick every script on rebuild.
ssh_guest() { # [cmd...] — run on the docs guest as root via the demo key
  [ -f "$KEY_DIR/demo" ] || die "demo SSH key missing: $KEY_DIR/demo (boot a client or run ./demo.sh clients once)"
  ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 \
    -i "$KEY_DIR/demo" "root@$SELFHOSTIX_SSH_TARGET" "$@"
}

ssh_client() { # $1=user $2=host $3=port [cmd...] — run on a booted client guest
  local user="$1" host="$2" port="$3"; shift 3
  ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 \
    -p "$port" -i "$KEY_DIR/demo" "$user@$host" "$@"
}

detect_origin() { # host LAN origin for seed links, e.g. http://<host-LAN-IP>
  if [ -n "${SELFHOSTIX_URL:-}" ]; then printf '%s' "$SELFHOSTIX_URL"; return 0; fi
  if [ -x ./host/detect-origin.sh ]; then
    local origin; origin="$(./host/detect-origin.sh || true)"
    [ -n "$origin" ] && { printf '%s/' "$origin"; return 0; }
  fi
  printf 'http://docs.selfhostix/'
}

load_users() {
  [ -f "$USERS_FILE" ] || die "users file missing: $USERS_FILE (run: ./propagate.sh users init)"
  # shellcheck disable=SC1090
  . "$USERS_FILE"
  [ -n "${USERS:-}" ] || die "USERS is empty in $USERS_FILE"
}

# Print TSV: email \t pass \t full \t short, one line per id in $USERS.
users_tsv() {
  load_users
  for id in $USERS; do
    upper="$(printf '%s' "$id" | tr '[:lower:]' '[:upper:]')"
    eval "email=\"\${${id}_EMAIL:?missing ${id}_EMAIL in $USERS_FILE}\""
    eval "pass=\"\${${id}_PASS:-}\""
    eval "override=\"\${${upper}_PASS:-}\""
    [ -n "$override" ] && pass="$override"
    eval "full=\"\${${id}_FULL:-$id}\""
    eval "short=\"\${${id}_SHORT:-$id}\""
    [ -n "$pass" ] || die "empty password for $email (${id}_PASS / ${upper}_PASS)"
    # shellcheck disable=SC2154 # full/short are set via eval above
    printf '%s\t%s\t%s\t%s\n' "$email" "$pass" "$full" "$short"
  done
}

# Emails of the 1st / 2nd managed users (seed owner / share target defaults).
nth_email() { # $1=1-based index
  users_tsv | sed -n "${1}p" | cut -f1
}

owner_pass() { # $1=email -> password from USERS_FILE
  users_tsv | awk -F'\t' -v want="$1" '$1 == want { print $2; exit }'
}

# --- users -----------------------------------------------------------------

users_init() {
  local f="${1:-$USERS_FILE}"
  if [ -f "$f" ]; then msg "users file exists: $f"; return 0; fi
  mkdir -p "$(dirname "$f")"
  cat > "$f" <<'EOF'
# Selfhostix demo users — managed by ./propagate.sh users, NOT by server startup.
# Edit passwords, then: ./propagate.sh users upsert
USERS="alice bob"
alice_EMAIL=alice@docs.selfhostix
alice_PASS=alice-demo
alice_FULL="Alice Demo"
alice_SHORT=Alice
bob_EMAIL=bob@docs.selfhostix
bob_PASS=bob-demo
bob_FULL="Bob Demo"
bob_SHORT=Bob
EOF
  chmod 600 "$f"
  msg "created $f (mode 600) — edit passwords, then ./propagate.sh users upsert"
}

users_upsert() {
  ensure_guest_access
  local tsv b64
  tsv="$(users_tsv)"
  # Data rides inside the script as base64: the heredoc below IS ssh stdin,
  # so a `printf .. | ssh .. <<heredoc` pipe would silently drop the data,
  # and /tmp does not persist across guest SSH sessions (PrivateTmp).
  b64="$(printf '%s\n' "$tsv" | base64 -w0)"
  msg "upserting users into Selfhostix on $SELFHOSTIX_SSH_TARGET"
  ssh_guest "lasuite-docs-manage shell" <<PYEOF
import base64
from django.contrib.auth import get_user_model
U = get_user_model()
rows = base64.b64decode("$b64").decode().splitlines()
for line in rows:
    if not line.strip():
        continue
    email, pw, full, short = line.split("\t")
    # NOTE: no get_or_create — BaseModel.save() runs full_clean() on create,
    # so a fresh row would fail validation (blank password) before we can
    # set it. Build/update in memory, set the password, save once.
    try:
        u = U.objects.get(admin_email=email)
        created = False
    except U.DoesNotExist:
        u = U(admin_email=email)
        created = True
    u.email = email
    u.full_name = full
    u.short_name = short
    u.language = "en-us"
    u.set_password(pw)
    u.is_active = True
    u.is_staff = True  # demo password login happens at /admin/
    u.save()
    print(("created " if created else "updated ") + email)
PYEOF
}

users_list() {
  ensure_guest_access
  msg "Selfhostix users on $SELFHOSTIX_SSH_TARGET"
  ssh_guest "lasuite-docs-manage shell" <<'PYEOF'
from django.contrib.auth import get_user_model
for u in get_user_model().objects.order_by("admin_email"):
    print(f"{u.admin_email}\t{u.full_name}\tactive={u.is_active}")
PYEOF
}

users_check() {
  ensure_guest_access
  local tsv b64
  tsv="$(users_tsv)"
  b64="$(printf '%s\n' "$tsv" | base64 -w0)"
  local emails; emails="$(printf '%s\n' "$tsv" | cut -f1 | tr '\n' ' ')"
  msg "checking users exist on $SELFHOSTIX_SSH_TARGET: $emails"
  ssh_guest "lasuite-docs-manage shell" <<PYEOF
import base64
from django.contrib.auth import get_user_model
U = get_user_model()
rows = base64.b64decode("$b64").decode().splitlines()
missing = []
for line in rows:
    if not line.strip():
        continue
    email = line.split("\t")[0]
    if not U.objects.filter(admin_email=email, is_active=True).exists():
        missing.append(email)
if missing:
    print("MISSING: " + " ".join(missing))
    raise SystemExit(1)
print("all users present")
PYEOF
}

users_set_password() {
  local email="${1:?email required}" pass="${2:-${USER_PASS:-}}"
  [ -n "$pass" ] || { printf 'new password: '; IFS= read -rs pass; echo; }
  [ -n "$pass" ] || die "empty password"
  ensure_guest_access
  msg "setting password for $email"
  # Credentials travel base64-encoded inside the script, never interpolated
  # into remote code (no shell-injection surface for odd passwords).
  local b64; b64="$(printf '%s\t%s' "$email" "$pass" | base64 -w0)"
  ssh_guest "lasuite-docs-manage shell" <<PYEOF
import base64
from django.contrib.auth import get_user_model
U = get_user_model()
email, pw = base64.b64decode("$b64").decode().split("\t")
u = U.objects.get(admin_email=email.strip())
u.set_password(pw.strip())
u.is_active = True
u.save()
print("password updated " + u.admin_email)
PYEOF
}

users_delete() {
  local email="${1:?email required}"
  ensure_guest_access
  msg "deactivating $email (rows + doc ACLs kept)"
  local b64; b64="$(printf '%s' "$email" | base64 -w0)"
  ssh_guest "lasuite-docs-manage shell" <<PYEOF
import base64
from django.contrib.auth import get_user_model
U = get_user_model()
email = base64.b64decode("$b64").decode().strip()
u = U.objects.get(admin_email=email)
u.is_active = False
u.save()
print("deactivated " + u.admin_email)
PYEOF
}

cmd_users() {
  if [ ! -f "$USERS_FILE" ]; then users_init; fi
  case "${1:-upsert}" in
    init) users_init "${2:-$USERS_FILE}" ;;
    upsert) users_upsert ;;
    list) users_list ;;
    check) users_check ;;
    set-password) shift; users_set_password "${1:-}" "${2:-}" ;;
    delete) shift; users_delete "${1:-}" ;;
    *) die "usage: ./propagate.sh users [init|upsert|list|check|set-password <email> [pass]|delete <email>]" ;;
  esac
}

# --- seed ------------------------------------------------------------------

cmd_seed() {
  local owner="${OWNER:-$(nth_email 1)}"
  local share_with="${SHARE_WITH:-$(nth_email 2)}"
  local owner_pass_val="${OWNER_PASS:-$(owner_pass "$owner")}"
  [ -n "$owner_pass_val" ] || die "owner password unknown for $owner: fix $USERS_FILE or set OWNER_PASS"
  local base_url; base_url="$(detect_origin)"

  msg "checking managed users exist (propagate users check)"
  users_check

  msg "waiting for Selfhostix API on $SELFHOSTIX_SSH_TARGET"
  local code=""
  for _ in $(seq 1 60); do
    code="$(curl -ks -o /dev/null -w '%{http_code}' --max-time 5 "http://$SELFHOSTIX_SSH_TARGET/")"
    [ "$code" = "200" ] && break
    sleep 5
  done
  [ "$code" = "200" ] || die "API not ready on http://$SELFHOSTIX_SSH_TARGET/ (start the server first)"

  msg "logging in as $owner and creating seed document"
  local jar; jar="$(mktemp -d)/cookies.txt"
  # Talk to Django under its own hostname (Host: docs.selfhostix resolved to
  # the guest IP): bare-IP requests 400 on guests whose ALLOWED_HOSTS lacks
  # the IP (see docs-net.nix DJANGO_ALLOWED_HOSTS).
  local guest="http://docs.selfhostix"
  local resolve="docs.selfhostix:80:$SELFHOSTIX_SSH_TARGET"
  local csrf_mid; csrf_mid="$(curl -ks --resolve "$resolve" -c "$jar" "$guest/admin/login/" | grep -o 'csrfmiddlewaretoken" value="[^"]*' | cut -d'"' -f3)"
  [ -n "${csrf_mid:-}" ] || die "no CSRF token at $guest/admin/login/ (is Django up?)"
  curl -ks --resolve "$resolve" -b "$jar" -c "$jar" -e "$guest/admin/login/" \
    -d "csrfmiddlewaretoken=$csrf_mid&username=$owner&password=$owner_pass_val" \
    "$guest/admin/login/" -o /dev/null
  local csrft sess
  csrft="$(grep csrftoken "$jar" | awk '{print $NF}')"
  sess="$(grep sessionid "$jar" | awk '{print $NF}')"
  [ -n "${sess:-}" ] || die "admin login failed for $owner (no sessionid cookie)"

  local doc_json doc_id
  doc_json="$(curl -ks --resolve "$resolve" -b "$jar" -H "X-CSRFToken: $csrft" -H "Referer: $guest/" \
    -H "Content-Type: application/json" \
    -d "{\"title\": \"$SEED_DOC_TITLE\"}" "$guest/api/v1.0/documents/")"
  doc_id="$(printf '%s' "$doc_json" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("id",""))')"
  [ -n "$doc_id" ] || die "document creation failed: $doc_json"
  msg "seed doc id: $doc_id"

  if [ -n "$share_with" ] && [ "$share_with" != "$owner" ]; then
    # Resolve the share target's id via the Django shell: the /users/ list
    # endpoint is visibility-scoped (returns [] here), so email lookup over
    # the API is unreliable.
    msg "resolving user id for $share_with"
    local share_b64; share_b64="$(printf '%s' "$share_with" | base64 -w0)"
    local share_id
    share_id="$(ssh_guest "lasuite-docs-manage shell" <<PYEOF | grep '^SHARE_ID=' | cut -d= -f2 || true
import base64
from django.contrib.auth import get_user_model
email = base64.b64decode("$share_b64").decode().strip()
print("SHARE_ID=" + str(get_user_model().objects.get(admin_email=email).id))
PYEOF
)"
    if [ -n "$share_id" ]; then
      # NOTE: the write field is `user_id` (not `user`); `team` is a string
      # that must be "" for user accesses (DB check constraint).
      curl -ks --resolve "$resolve" -b "$jar" -H "X-CSRFToken: $csrft" -H "Referer: $guest/" \
        -H "Content-Type: application/json" \
        -d "{\"user_id\": \"$share_id\", \"team\": \"\", \"role\": \"editor\"}" \
        "$guest/api/v1.0/documents/$doc_id/accesses/" -o /dev/null -w "share with $share_with -> %{http_code}\n" || true
    else
      warn "could not resolve $share_with via API; share '$SEED_DOC_TITLE' manually in the UI"
    fi
  fi

  local seed_doc_url="${base_url}docs/$doc_id/"
  mkdir -p "$(dirname "$SEED_ENV")"
  cat > "$SEED_ENV" <<EOF
SEED_DOC_ID=$doc_id
SEED_DOC_URL=$seed_doc_url
EOF
  msg "seed doc ready: $seed_doc_url"
}

# --- provision ---------------------------------------------------------------

provision_one() { # $1=client-index $2=seed-url
  local idx="$1" seed_url="$2"
  ensure_client_access "$idx"
  local port; port="$(client_ssh_port "$idx")"
  msg "provisioning client c$idx (root@localhost:$port, seed: $seed_url)"
  ssh_client root localhost "$port" "grep -q 'docs.selfhostix' /etc/hosts || echo '$SELFHOSTIX_IP docs.selfhostix' >> /etc/hosts"
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

cmd_provision() {
  local n="${1:-$NUM_CLIENTS}"
  [ -f "$SEED_ENV" ] || die "no seed state: $SEED_ENV (run ./propagate.sh seed first)"
  # shellcheck disable=SC1090
  . "$SEED_ENV"
  local seed_url="${SEED_DOC_URL:?seed env corrupt: $SEED_ENV}"
  local i
  for i in $(seq 1 "$n"); do
    provision_one "$i" "$seed_url"
  done
}

cmd_all() {
  users_upsert
  cmd_seed
  cmd_provision "$NUM_CLIENTS"
}

case "${1:-help}" in
  users) shift; cmd_users "$@" ;;
  seed) cmd_seed ;;
  provision) shift; cmd_provision "${1:-$NUM_CLIENTS}" ;;
  all) cmd_all ;;
  *) sed -n '2,20p' "$0" ;;
esac
