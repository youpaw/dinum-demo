set -euo pipefail
# Create the shared demo doc (needs users first: nix run .#users -- upsert).
#   nix run .#seed
cd "${DEMO_ROOT:-$PWD}"

owner="${OWNER:-$(nth_email 1)}"
share_with="${SHARE_WITH:-$(nth_email 2)}"
owner_pass_val="${OWNER_PASS:-$(owner_pass "$owner")}"
[ -n "$owner_pass_val" ] || die "owner password unknown for $owner: fix $USERS_FILE or set OWNER_PASS"
base_url="$(detect_origin)"
docs_domain="$(service_domain docs)"
docs_manage="$(service_manage docs)"

msg "checking managed users exist (users check docs)"
users_check docs

# Talk to Django under its own hostname (Host: docs.selfhostix resolved to the
# guest IP): the guest serves every service as a name-based vhost, and Django
# 400s on Host headers outside ALLOWED_HOSTS (see nix/net.nix).
guest="http://$docs_domain"
resolve="$docs_domain:80:$SELFHOSTIX_SSH_TARGET"

msg "waiting for the Docs API on $guest ($SELFHOSTIX_SSH_TARGET)"
code=""
for _ in $(seq 1 60); do
  code="$(curl -ks --resolve "$resolve" -o /dev/null -w '%{http_code}' --max-time 5 "$guest/")"
  [ "$code" = "200" ] && break
  sleep 5
done
[ "$code" = "200" ] || die "API not ready on $guest/ (start the guest first: nix run .#microvm)"

msg "logging in as $owner and creating seed document"
jar="$(mktemp -d)/cookies.txt"
csrf_mid="$(curl -ks --resolve "$resolve" -c "$jar" "$guest/admin/login/" | grep -o 'csrfmiddlewaretoken" value="[^"]*' | cut -d'"' -f3)"
[ -n "${csrf_mid:-}" ] || die "no CSRF token at $guest/admin/login/ (is Django up?)"
curl -ks --resolve "$resolve" -b "$jar" -c "$jar" -e "$guest/admin/login/" \
  -d "csrfmiddlewaretoken=$csrf_mid&username=$owner&password=$owner_pass_val" \
  "$guest/admin/login/" -o /dev/null
csrft="$(grep csrftoken "$jar" | awk '{print $NF}')"
sess="$(grep sessionid "$jar" | awk '{print $NF}')"
[ -n "${sess:-}" ] || die "admin login failed for $owner (no sessionid cookie)"

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
  share_b64="$(printf '%s' "$share_with" | base64 -w0)"
  share_id="$(ssh_guest "$docs_manage shell" <<PYEOF | grep '^SHARE_ID=' | cut -d= -f2 || true
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

seed_doc_url="${base_url}docs/$doc_id/"
mkdir -p "$(dirname "$SEED_ENV")"
cat > "$SEED_ENV" <<EOF
SEED_DOC_ID=$doc_id
SEED_DOC_URL=$seed_doc_url
EOF
msg "seed doc ready: $seed_doc_url"
