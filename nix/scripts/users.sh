set -euo pipefail
# Manage demo users across every service on the guest (server-side Django
# state, NOT server startup). Both `lasuite-docs` and `lasuite-drive` share
# the same core User model (admin_email/full_name/short_name/is_staff/
# is_active — see nix/services.nix), so one users.env + one flow provisions
# both; pass a trailing [docs|drive] to target just one.
#   nix run .#users -- init
#   nix run .#users -- upsert [docs|drive]
#   nix run .#users -- list [docs|drive]
#   nix run .#users -- check [docs|drive]
#   nix run .#users -- set-password <email> [pass] [docs|drive]
#   nix run .#users -- delete <email> [docs|drive]
cd "${DEMO_ROOT:-$PWD}"

users_init() {
  local f="${1:-$USERS_FILE}"
  if [ -f "$f" ]; then msg "users file exists: $f"; return 0; fi
  mkdir -p "$(dirname "$f")"
  cat > "$f" <<'EOF'
# Selfhostix demo users — managed by `nix run .#users`, NOT by server startup.
# Shared across every service on the guest (docs, drive — see nix/services.nix).
# Edit passwords, then: nix run .#users -- upsert
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
  msg "created $f (mode 600) — edit passwords, then nix run .#users -- upsert"
}

users_upsert() { # $1=service filter or empty for all
  local svc manage tsv b64
  tsv="$(users_tsv)"
  # Data rides inside the script as base64: the heredoc below IS ssh stdin,
  # so a `printf .. | ssh .. <<heredoc` pipe would silently drop the data,
  # and /tmp does not persist across guest SSH sessions (PrivateTmp).
  b64="$(printf '%s\n' "$tsv" | base64 -w0)"
  ensure_guest_access
  for svc in $(services_arg "${1:-}"); do
    manage="$(service_manage "$svc")"
    msg "upserting users into $svc"
    ssh_guest "$manage shell" <<PYEOF
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
  done
}

users_list() { # $1=service filter or empty for all
  local svc manage
  ensure_guest_access
  for svc in $(services_arg "${1:-}"); do
    manage="$(service_manage "$svc")"
    msg "$svc users"
    ssh_guest "$manage shell" <<'PYEOF'
from django.contrib.auth import get_user_model
for u in get_user_model().objects.order_by("admin_email"):
    print(f"{u.admin_email}\t{u.full_name}\tactive={u.is_active}")
PYEOF
  done
}

users_set_password() { # $1=email $2=pass(optional) $3=service filter(optional)
  local email="${1:?email required}" pass="${2:-${USER_PASS:-}}" svc manage b64
  [ -n "$pass" ] || { printf 'new password: '; IFS= read -rs pass; echo; }
  [ -n "$pass" ] || die "empty password"
  b64="$(printf '%s\t%s' "$email" "$pass" | base64 -w0)"
  ensure_guest_access
  for svc in $(services_arg "${3:-}"); do
    manage="$(service_manage "$svc")"
    msg "setting password for $email on $svc"
    # Credentials travel base64-encoded inside the script, never interpolated
    # into remote code (no shell-injection surface for odd passwords).
    ssh_guest "$manage shell" <<PYEOF
import base64
from django.contrib.auth import get_user_model
U = get_user_model()
email, pw = base64.b64decode("$b64").decode().split("\t")
try:
    u = U.objects.get(admin_email=email.strip())
except U.DoesNotExist:
    print("not present on $svc, skipping")
    raise SystemExit(0)
u.set_password(pw.strip())
u.is_active = True
u.save()
print("password updated " + u.admin_email)
PYEOF
  done
}

users_delete() { # $1=email $2=service filter(optional)
  local email="${1:?email required}" svc manage b64
  b64="$(printf '%s' "$email" | base64 -w0)"
  ensure_guest_access
  for svc in $(services_arg "${2:-}"); do
    manage="$(service_manage "$svc")"
    msg "deactivating $email on $svc (rows + ACLs kept)"
    ssh_guest "$manage shell" <<PYEOF
import base64
from django.contrib.auth import get_user_model
U = get_user_model()
email = base64.b64decode("$b64").decode().strip()
try:
    u = U.objects.get(admin_email=email)
except U.DoesNotExist:
    print("not present on $svc, skipping")
    raise SystemExit(0)
u.is_active = False
u.save()
print("deactivated " + u.admin_email)
PYEOF
  done
}

if [ ! -f "$USERS_FILE" ]; then users_init; fi
case "${1:-upsert}" in
  init) users_init "${2:-$USERS_FILE}" ;;
  upsert) users_upsert "${2:-}" ;;
  list) users_list "${2:-}" ;;
  check) users_check "${2:-}" ;;
  set-password) shift; users_set_password "${1:-}" "${2:-}" "${3:-}" ;;
  delete) shift; users_delete "${1:-}" "${2:-}" ;;
  *) die "usage: nix run .#users -- [init|upsert|list|check|set-password <email> [pass]|delete <email>] [docs|drive]" ;;
esac
