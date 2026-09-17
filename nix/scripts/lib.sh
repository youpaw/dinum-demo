# Shared helpers for all demo Nix apps (see nix/apps.nix).
# Has no shebang and sets no options: each app script starts with
# `set -euo pipefail`, then this file is concatenated in at build time,
# after the DEMO_SERVICES/GUEST_*/<svc>_* data nix/apps.nix generates from
# nix/services.nix (the single source of truth for the guest address and each
# service's domain/manage-command).

# --- per-service lookup (reads the data generated above) ---------------------
# Every service lives on the one guest ($GUEST_IP); what differs per service
# is its vhost domain and its Django manage command.
service_domain() { eval "printf '%s' \"\$${1}_DOMAIN\""; }
service_manage() { eval "printf '%s' \"\$${1}_MANAGE\""; }

services_arg() { # $1=requested service name or empty -> validated target list
  if [ -z "${1:-}" ]; then printf '%s' "$DEMO_SERVICES"; return 0; fi
  case " $DEMO_SERVICES " in
    *" $1 "*) printf '%s' "$1" ;;
    *) die "unknown service '$1' (expected one of: $DEMO_SERVICES)" ;;
  esac
}

# --- env defaults (all optional) ---------------------------------------------
NUM_CLIENTS="${NUM_CLIENTS:-2}"
SELFHOSTIX_SSH_TARGET="${SELFHOSTIX_SSH_TARGET:-$GUEST_IP}"
CLIENT_SSH_BASE="${CLIENT_SSH_BASE:-2221}"
DEMO_ROOT="${DEMO_ROOT:-$PWD}"
DATA_DIR="${DATA_DIR:-$DEMO_ROOT/data}"
KEY_DIR="${KEY_DIR:-$DATA_DIR/demo-ssh}"
USERS_FILE="${USERS_FILE:-$DATA_DIR/users.env}"
SEED_ENV="${SEED_ENV:-$DATA_DIR/seed.env}"
SEED_DOC_TITLE="${SEED_DOC_TITLE:-Demo — live collaboration}"
# CA issued by `sudo nix run .#host-install`; the guest is built against it and
# the clients get it installed, so every demo hop validates the real chain.
CA_FILE="${CA_FILE:-$DATA_DIR/certs/ca.crt}"
GUEST_ROOT_PASS="${GUEST_ROOT_PASS:-root}"      # demo guest (see nix/guest.nix)
CLIENT_ROOT_PASS="${CLIENT_ROOT_PASS:-nixos}"   # bureautix-example default

msg() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31mXX\033[0m %s\n' "$*" >&2; exit 1; }

# Every demo SSH hop uses these, and nothing else:
#   -F /dev/null      ignore the host's ssh_config and the user's ~/.ssh/config.
#                     The demo only ever talks to a link-local guest and to
#                     localhost hostfwd ports, so inherited ProxyJump/alias
#                     rules can only surprise it — and a Debian host's
#                     GSSAPIAuthentication line makes Nix's openssh (built
#                     without GSSAPI) print "Unsupported option" on every call.
#   known_hosts off   guest rebuilds regenerate host keys; pinning them would
#                     brick every helper on rebuild.
SSH_OPTS=(-F /dev/null -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)

client_name() { echo "selfhostix-c$1"; }
client_ssh_port() { echo "$((CLIENT_SSH_BASE + $1 - 1))"; } # c1 -> 2221, c2 -> 2222
client_runner() { # -> path to bin/run-*-vm built by `nix-build -A vm`
  find client-loader/bin -maxdepth 1 -name 'run-*-vm' | head -n1
}

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
  ssh "${SSH_OPTS[@]}" -o BatchMode=yes \
    -o ConnectTimeout=5 -p "$3" -i "$KEY_DIR/demo" "$1@$2" true 2>/dev/null
}

install_demo_key() { # $1=user $2=host $3=port $4=password — one-time password auth
  msg "installing demo SSH key on $1@$2 (one-time password auth)"
  local keydata; keydata="$(cat "$KEY_DIR/demo.pub")"
  sshpass -p"$4" ssh "${SSH_OPTS[@]}" -p "$3" "$1@$2" \
    "mkdir -p ~/.ssh && chmod 700 ~/.ssh && grep -qF '$keydata' ~/.ssh/authorized_keys 2>/dev/null || echo '$keydata' >> ~/.ssh/authorized_keys"
}

ensure_guest_access() { # [$1=ssh-target] — key auth to the guest, installing the key if needed
  local target="${1:-$SELFHOSTIX_SSH_TARGET}"
  ensure_demo_key
  key_works root "$target" 22 || install_demo_key root "$target" 22 "$GUEST_ROOT_PASS"
  key_works root "$target" 22 || die "key auth still failing for root@$target (wrong GUEST_ROOT_PASS?)"
}

ensure_client_access() { # $1=client-index — key auth to a booted client
  ensure_demo_key
  local port; port="$(client_ssh_port "$1")"
  key_works root localhost "$port" || install_demo_key root localhost "$port" "$CLIENT_ROOT_PASS"
  key_works root localhost "$port" || die "key auth still failing for client c$1 (localhost:$port; is it booted?)"
}

# --- remote execution --------------------------------------------------------

# NOTE: UserKnownHostsFile=/dev/null — the guest is rebuilt regularly (new
# host keys each rebuild); pinning keys would brick every script on rebuild.
ssh_guest() { # [cmd...] — run on the guest as root via the demo key
  [ -f "$KEY_DIR/demo" ] || die "demo SSH key missing: $KEY_DIR/demo (run nix run .#users once)"
  ssh "${SSH_OPTS[@]}" -o ConnectTimeout=10 \
    -i "$KEY_DIR/demo" "root@$SELFHOSTIX_SSH_TARGET" "$@"
}

ssh_client() { # $1=user $2=host $3=port [cmd...] — run on a booted client guest
  local user="$1" host="$2" port="$3"; shift 3
  ssh "${SSH_OPTS[@]}" -o ConnectTimeout=10 \
    -p "$port" -i "$KEY_DIR/demo" "$user@$host" "$@"
}

wait_ssh() { # $1=user $2=host [SSH_PORT=port] — clients answer on a hostfwd port
  # Generous retries: first boot installs the system from the host store.
  local port="${SSH_PORT:-22}"
  msg "waiting for SSH on $2"
  for _ in $(seq 1 90); do
    if ssh "${SSH_OPTS[@]}" -o BatchMode=yes -o ConnectTimeout=3 -p "$port" \
        -i "$KEY_DIR/demo" "$1@$2" true 2>/dev/null; then return 0; fi
    sleep 5
  done
  return 1
}

start_client() { # $1=name $2=runner $3=disk $4=ssh-port
  local name="$1" runner="$2" disk="$3" port="$4"
  local pidfile="$DATA_DIR/$name.pid" log="$DATA_DIR/$name.log"
  if [ -f "$pidfile" ] && kill -0 "$(cat "$pidfile")" 2>/dev/null; then
    msg "$name already running (pid $(cat "$pidfile"))"
    return 0
  fi
  mkdir -p "$DATA_DIR"
  local qemu_display=""
  [ "${HEADLESS:-0}" = "1" ] && qemu_display="-display none"
  msg "starting $name (disk $(basename "$disk"), ssh localhost:$port)"
  # The runner creates $disk on first boot (blank image; the guest installs
  # itself from the host store via 9p) and forwards guest :22 to localhost.
  if [ -n "$qemu_display" ]; then
    NIX_DISK_IMAGE="$disk" QEMU_NET_OPTS="hostfwd=tcp::$port-:22" QEMU_OPTS="$qemu_display" \
      "$runner" >"$log" 2>&1 &
  else
    NIX_DISK_IMAGE="$disk" QEMU_NET_OPTS="hostfwd=tcp::$port-:22" \
      "$runner" >"$log" 2>&1 &
  fi
  echo "$!" >"$pidfile"
}

# --- users / seed shared helpers ---------------------------------------------

host_lan_ip() { # address clients must resolve the demo names to (the proxy)
  if [ -n "${SELFHOSTIX_HOST_IP:-}" ]; then printf '%s' "$SELFHOSTIX_HOST_IP"; return 0; fi
  local addr; addr="$(detect-origin || true)"
  [ -n "$addr" ] || die "could not detect the host LAN address (set SELFHOSTIX_HOST_IP)"
  printf '%s' "$addr"
}

# curl against a demo name, pinned to the proxy on this host and validated
# against the demo CA — the same chain a browser walks, minus the DNS.
curl_site() { # $1=domain [curl args...]
  local domain="$1"; shift
  [ -f "$CA_FILE" ] || die "demo CA missing: $CA_FILE (run: sudo nix run .#host-install)"
  curl -s --resolve "$domain:443:127.0.0.1" --cacert "$CA_FILE" "$@"
}

load_users() {
  [ -f "$USERS_FILE" ] || die "users file missing: $USERS_FILE (run: nix run .#users -- init)"
  # shellcheck disable=SC1090
  . "$USERS_FILE"
  [ -n "${USERS:-}" ] || die "USERS is empty in $USERS_FILE"
}

# Print TSV: email \t pass \t full \t short, one line per id in $USERS.
# shellcheck disable=SC2154 # email/pass/override/full/short are eval-assigned below
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

# Every managed user present and active on each requested service?
# Used by `nix run .#users -- check` and as seed.sh's precondition.
users_check() { # $1=service filter or empty for all
  local svc manage tsv b64 emails
  tsv="$(users_tsv)"
  # Data rides inside the script as base64: the heredoc below IS ssh stdin,
  # so a `printf .. | ssh .. <<heredoc` pipe would silently drop the data,
  # and /tmp does not persist across guest SSH sessions (PrivateTmp).
  b64="$(printf '%s\n' "$tsv" | base64 -w0)"
  emails="$(printf '%s\n' "$tsv" | cut -f1 | tr '\n' ' ')"
  ensure_guest_access
  for svc in $(services_arg "${1:-}"); do
    manage="$(service_manage "$svc")"
    msg "checking users exist on $svc: $emails"
    ssh_guest "$manage shell" <<PYEOF
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
  done
}
