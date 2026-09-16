# Selfhostix collaboration demo

Selfhostix server as a Nix microVM (cloud-hypervisor) + N Bureautix client
VMs on libvirt, one pre-seeded shared document for live co-editing.

Runs the nixpkgs packages (`lasuite-docs` backend, `lasuite-docs-frontend`,
`lasuite-docs-collaboration-server`) as a full stack. No Docker.

## Layout

| File | Purpose |
|---|---|
| `demo.sh` | VM lifecycle + thin dispatcher (microvm/boot clients/status/stop/logs/clean; delegates state to `propagate.sh`) |
| `propagate.sh` | Single propagation flow: `users` (init/upsert/list/check/set-password/delete) → `seed` (shared doc + share) → `provision` (clients); owns SSH key generation/installation |
| `flake.nix` → `selfhostix` | Server config: `docs-vm.nix` + `microvm/docs-guest.nix` |
| `docs-vm.nix` | Base system: `services.lasuite-docs` + dex (mock OIDC) + garage (S3) + local postgres/redis + nginx |
| `docs-net.nix` | Guest network overlay: static tap IP, OIDC issuer, `DJANGO_CSRF_TRUSTED_ORIGINS`, `DJANGO_ALLOWED_HOSTS` (guest IP + LAN host), nginx aliases |
| `microvm/docs-guest.nix` | MicroVM guest: tap `192.168.100.10`, `/var/lib` volume (drive `.11` / grist `.12` reserved) |
| `host/net-setup.sh` | Host tap + NAT setup (`tap-selfhostix` `192.168.100.1/24`, `sudo` once per boot) |
| `host/Caddyfile` | Host reverse proxy on the single LAN `:80`: path routing (`/drive/*` → `.11`, `/grist/*` → `.12`, all else → docs `.10`) |
| `host/caddy.service` | Host systemd unit for the proxy — edit paths, then install |
| `host/detect-origin.sh` | Prints the host LAN origin browsers use (feeds Django origins + seed links) |

## Start

```bash
sudo ./host/net-setup.sh      # tap-selfhostix 192.168.100.1 (once per boot)
./demo.sh microvm run         # boot selfhostix (foreground)
./demo.sh users upsert        # create users from data/users.env (0600)
./demo.sh seed                # shared doc (requires users first)
./demo.sh clients [N]         # boot + provision N Bureautix clients (default 2)
./demo.sh provision [N]       # provision already-booted clients (no reboot)
./demo.sh all                 # users + seed + clients (server must run already)
./demo.sh status              # server + client health
./demo.sh stop                # shut down client VMs (keep disks)
./demo.sh clean               # delete overlays + seed state (keeps users.env + SSH key)
```

`./demo.sh users|seed|provision` are thin pass-throughs to `./propagate.sh`,
which also runs standalone (`./propagate.sh all`). Emails in `data/users.env`
need a dotted domain — Django rejects single-label domains (`user@host`).

First boot takes a while (image build, postgres init, django migrate,
garage layout+bucket). Runtime state (volumes, overlays, SSH key, seed info)
lives in `data/` (gitignored); the client image builds to `client-loader/`
(gitignored symlink).

Env knobs: `NUM_CLIENTS=2`, `MICROVM_IP=192.168.100.10`,
`SELFHOSTIX_SSH_TARGET=...` (users/seed/logs SSH target, default `MICROVM_IP`),
`SELFHOSTIX_IP=...` (IP clients use for docs.selfhostix, default: guest IP),
`SELFHOSTIX_PUBLIC_ORIGIN=http://<host-LAN-IP>` (browser origin trusted by Django;
auto-detected at boot, override only if detection picks the wrong uplink),
`ALICE_PASS`/`BOB_PASS`, `SEED_DOC_TITLE`, `SELFHOSTIX_URL` (seed link base,
defaults to the detected origin), `CLIENT_SSH_BASE=2221` (client i on
`localhost:2220+i`), `HEADLESS=1` (clients without GUI), `DATA_DIR`.

Access: no client setup needed — any browser opening the **host LAN IP**
lands on Selfhostix via the proxy (`/` → docs; `/drive/*`, `/grist/*` are
reserved for the next services on the same address). Log in at `/admin/` with
a Selfhostix user
(password login, no SSO roundtrip: the mock OIDC issuer lives on the tap
net and is unreachable from outside).
Client guests boot straight from the nix runner (`nix-build -A vm` output):
first boot installs the system into `data/selfhostix-cN-disk.qcow2` from the
host store, so allow several minutes. Each client opens its own QEMU window
and forwards guest `:22` to `localhost:222N` for provisioning
(`ssh -p 2221 root@localhost`, password `nixos` until the demo key lands).
Password SSH during provisioning uses `nixpkgs#sshpass` (no host install
needed); a persistent ed25519 key is generated at `data/demo-ssh/`.
Client OS login stays `alice/test`, `root/nixos` (stock bureautix-example
image); Selfhostix logins are `alice@docs.selfhostix` / `bob@docs.selfhostix`
(passwords in `data/users.env`, defaults `alice-demo` / `bob-demo` —
demo-only).

Walkthrough: start the server, run `all`, use both QEMU windows
— each browser lands on the seed doc; type on both sides to
show live cursors via `/collaboration`.

## Login without SSO (password login)

The backend keeps `ModelBackend` enabled alongside OIDC, so a Django-admin
session works for the whole app, no IdP roundtrip. Either manage a user via
`./demo.sh users set-password <email>`, or in the guest:

```bash
ssh root@192.168.100.10
lasuite-docs-manage shell <<'EOF'
from django.contrib.auth import get_user_model
u = get_user_model().objects.get(admin_email='tester@docs.selfhostix')
u.email = 'tester@docs.selfhostix'  # OIDC normally fills these; the serializer 500s without
u.full_name = 'Test User'
u.short_name = 'Test'
u.set_password('<secret>')
u.save()
EOF
```

Then log in at `<host-IP>/admin/` (email + password) and open `<host-IP>/`
— SSO never involved.

> **CSRF in browsers:** Django ≥5.2 validates the `Origin` header on every
> unsafe request. Trusted origins are `http://docs.selfhostix`, the guest IP, plus
> the auto-detected host LAN origin (`SELFHOSTIX_PUBLIC_ORIGIN` — see
> `docs-net.nix` and `host/detect-origin.sh`). If the host IP changes,
> reboot the microVM so the new origin is picked up. After a rebuild, reset
> the password via `./demo.sh users set-password` (or wipe `data/` for a
> fresh start).
>
> **Allowed hosts:** `DJANGO_ALLOWED_HOSTS` (also in `docs-net.nix`) must list
> every `Host` header browsers send — domain, guest IP, LAN host. Without
> them Django answers `400 DisallowedHost` on `/api` and `/admin` while `/`
> still loads (nginx serves the frontend statically, so a working homepage
> with broken login is the signature symptom).

## Gotchas

- Virtio NICs get unpredictable interface names, so the guest static IP is
  matched on MAC address (see `docs-net.nix`).
- Services reached from outside the guest (dex, garage S3) must bind
  `0.0.0.0` (not `127.0.0.1`) with the guest firewall opened accordingly.
- The microVM root filesystem is ephemeral (erofs + `/var/lib` volume only):
  the demo SSH key installed on the guest is lost on every reboot.
  `propagate.sh` reinstalls it automatically (password fallback via
  `nixpkgs#sshpass`); `demo.sh` does the same for clients.
- Only `/var/lib` persists on the guest (postgres, garage, media). Users and
  the seed doc live in postgres — they survive reboots, but a fresh
  `var-lib.img` means re-running `./demo.sh users upsert` + `./demo.sh seed`.
- Enterprise/venue WiFi often isolates clients (no machine-to-machine
  traffic): if `curl http://<host-LAN-IP>/` works on the host but a second
  machine's browser hangs, check AP client isolation before blaming the proxy.
