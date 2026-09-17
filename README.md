# Selfhostix collaboration demo

Two Selfhostix services — LaSuite **Docs** and LaSuite **Drive** — in **one**
Nix microVM (cloud-hypervisor), behind one HTTPS host proxy, plus N Bureautix
client VMs and one pre-seeded shared document for live co-editing.

Runs the nixpkgs packages (`lasuite-docs`/`lasuite-drive` backends +
frontends, `lasuite-docs-collaboration-server`) as full stacks. No Docker,
no hand-rolled shell dispatcher — every verb below is a Nix flake `app`.

## Layout

| Path | Purpose |
|---|---|
| `flake.nix` | flake-parts: `nixosConfigurations.selfhostix` (the guest) + the apps from `nix/apps.nix` |
| `nix/services.nix` | Single source of truth: guest address/tap/MAC, each service's domain and manage command, and the non-app names (dex) the proxy also terminates |
| `nix/apps.nix` | Every app in one config: renders `nix/services.nix` into the shell data each script gets, declares each script's runtime tools, and generates the host `Caddyfile` (one TLS vhost per name) + systemd unit installed by `host-install` |
| `nix/guest.nix` | The microVM: hardware, base OS, and the only place demo data meets the `demo.*` options |
| `nix/net.nix` | `demo.net.*` options — static IP/MAC → systemd-networkd + `/etc/hosts`, and the derived `hosts`/`origins` (HTTPS) lists every service reuses |
| `nix/platform.nix` | `demo.oidc.*` / `demo.s3.*` options — the one dex, garage and postgres all services share, plus the garage bootstrap over registered buckets |
| `nix/services/docs.nix`, `nix/services/drive.nix` | One file per app: its settings, its OIDC client, its S3 bucket |
| `nix/scripts/lib.sh` + `nix/scripts/*.sh` | Shell bodies of each app (concatenated with `lib.sh` at build time; tool deps arrive via Nix `runtimeInputs`, not `$PATH` guessing) |

## Network

One guest, one wire, one proxy:

```
   browsers ──► https://docs.selfhostix  ─┐
                https://drive.selfhostix ─┼─► Caddy :443 (host, demo CA cert)
                https://auth.selfhostix  ─┘        │  TLS ends here
                                                   │  plain HTTP over the tap
                      host 192.168.100.1 ─── tap-selfhostix ─── guest 192.168.100.10
                                                                 nginx :80
                                                                 ├── docs.selfhostix
                                                                 └── drive.selfhostix
                                                                 dex :8080 (auth.selfhostix)
                                                                 garage :9000 — loopback only
                                                                 postgres · redis ×2
```

Both services live in **one** guest, so the tap is the whole link: `sudo nix
run .#net-setup` puts the gateway address on `tap-selfhostix` itself, with no
bridge to unify taps behind. (A tap's multi-queue support fans *one* guest's
vCPUs across queues of *its* NIC — it never joins two guests, which is what a
bridge would be for. Adding a second guest means adding a bridge back, plus a
tap per guest.)

Inside the guest the two apps only share what is genuinely one instance — dex,
garage, postgres, nginx — while nixpkgs' own modules keep the rest apart (own
gunicorn socket, own redis server, own database, own vhost).

**One name per service, not one path.** Docs and Drive are both SPAs that call
`/api/v1.0/...` at their origin root, so they cannot share an origin under a
prefix: strip `/drive` and Drive's own API calls land on Docs. Each therefore
gets a name, the proxy routes on it, and the guest's nginx picks the matching
vhost.

`auth.selfhostix` exists for the same reason the reference deployment has one:
the OIDC issuer must be a single URL that browsers *and* the backends resolve
and trust. On a raw `guest-IP:8080` only the tap link could reach it, which is
why this demo used to fall back to `/admin/` password login. Garage is
deliberately **not** exposed — both apps proxy `/media/` to S3 through their
own nginx vhost (signed via `auth_request`), so nothing in a browser ever
addresses S3 directly.

TLS ends at the proxy; the tap link carries plain HTTP. Django learns the
request was secure from `X-Forwarded-Proto` (`DJANGO_SECURE_PROXY_SSL_HEADER`),
which is also why session and CSRF cookies are `Secure`.

## Certificates

`sudo nix run .#host-install` generates a demo CA and one leaf covering every
name above, into `/etc/selfhostix-demo/certs` (plus a copy of the CA at
`data/certs/ca.crt` for the unprivileged apps). Both are only regenerated when
missing or when the name set changed, so re-running never invalidates trust
already handed out. Three parties must trust that CA:

| Who | How |
|---|---|
| The guest | read at build time (`SELFHOSTIX_CA_FILE`, exported by `nix run .#microvm`) into `security.pki.certificateFiles` — its backends call the issuer through the proxy |
| Client VMs | `provision` installs it via Firefox policy (`Certificates.Install`); Firefox keeps its own trust store, and a NixOS client's system bundle is read-only |
| Your own browser | import `data/certs/ca.crt` manually, or accept the warning once |

## Start

```bash
sudo nix run .#net-setup       # tap-selfhostix + 192.168.100.1 + NAT (once per boot)
sudo nix run .#host-install    # demo CA + certificate, then the proxy unit
nix run .#microvm              # boot the guest, docs + drive (foreground)
nix run .#users -- upsert      # create data/users.env accounts on docs AND drive (0600, both by default)
nix run .#seed                 # shared doc (requires users first)
nix run .#clients -- [N]       # boot + provision N Bureautix clients (default 2)
nix run .#provision -- [N]     # provision already-booted clients (no reboot)
```

That is the whole app surface: install the network and the proxy, boot the
guest, propagate demo data. Order matters once: `host-install` must run before
`microvm`, because the guest is built against the CA it generates.
`nix run .#microvm -- eval` evaluates the guest without booting it.

The proxy runs as the installed `selfhostix-caddy.service`, so re-run
`sudo nix run .#host-install` after changing `nix/services.nix` — systemd and
Caddy read the `/etc` copy, not the store path of the moment. Client VMs are
plain QEMU processes with their pid in `data/`: close the window or
`kill $(cat data/selfhostix-c1.pid)` to stop one, and delete
`data/selfhostix-c*-disk.qcow2` + `data/seed.env` to start over.

Emails in `data/users.env` need a dotted domain — Django rejects
single-label domains (`user@host`).

`users`' `upsert`/`list`/`check`/`set-password`/`delete` all take an
optional trailing `docs`/`drive` filter (`nix run .#users -- list docs`);
omit it and they act on every service — both `lasuite-docs` and
`lasuite-drive` share the same core Django User model, so one `users.env`
provisions logins on both in one command.

First boot takes a while (image build, postgres init, django migrate,
garage layout+buckets). Runtime state (volume, overlays, SSH key, seed info)
lives in `data/` (gitignored); the client image builds to `client-loader/`
(gitignored symlink).

Env knobs: `NUM_CLIENTS=2`, `SELFHOSTIX_SSH_TARGET=...` (guest SSH target,
default the guest IP), `ALICE_PASS`/`BOB_PASS`, `SEED_DOC_TITLE`,
`SELFHOSTIX_URL` (seed link base, default `https://docs.selfhostix/`),
`SELFHOSTIX_HOST_IP` (address clients resolve the names to; auto-detected),
`CA_FILE` (default `data/certs/ca.crt`),
`CLIENT_SSH_BASE=2221` (client i on `localhost:2220+i`), `HEADLESS=1` (clients
without GUI), `DATA_DIR`. `net-setup` additionally takes `TAP`, `TAP_IP`,
`SUBNET` and `UPLINK`.

Access: open `https://docs.selfhostix/` or `https://drive.selfhostix/`. The
names must resolve to the **host** (the proxy holds the certificate), which
`provision` arranges on the client VMs; on any other machine add one line:

```
<host-LAN-IP>  docs.selfhostix drive.selfhostix auth.selfhostix
```

That hosts line and the CA import are the entire client-side cost of using
names — and names are what let Docs and Drive each own their API root. Log in
at `/admin/` with a demo user, or through SSO now that `auth.selfhostix` is
reachable (mock connector: `admin` / `password`).

Client guests boot straight from the nix runner (`nix-build -A vm` output):
first boot installs the system into `data/selfhostix-cN-disk.qcow2` from the
host store, so allow several minutes. Each client opens its own QEMU window
and forwards guest `:22` to `localhost:222N` for provisioning
(`ssh -p 2221 root@localhost`, password `nixos` until the demo key lands).
Password SSH during provisioning uses `nixpkgs#sshpass`; a persistent
ed25519 key is generated at `data/demo-ssh/`. Client OS login stays
`alice/test`, `root/nixos` (stock bureautix-example image); service logins are
`alice@docs.selfhostix` / `bob@docs.selfhostix` (passwords in
`data/users.env`, defaults `alice-demo` / `bob-demo` — demo-only).

Walkthrough: boot the guest, then `users -- upsert`, `seed`, `clients`; each
client's browser lands on the seed doc, so typing on both sides shows live
cursors via `/collaboration`.

## Adding a service

1. Add it to `nix/services.nix` (domain, manage command, proxy prefix —
   exactly one service keeps `prefix = null`, the proxy's catch-all).
2. Add `nix/services/<name>.nix`: the app itself, plus
   `demo.oidc.clients.<id>` and `demo.s3.buckets.<name>` for the shared dex
   and garage; import it from `nix/guest.nix` and set its domain there.
3. Re-run `sudo nix run .#host-install` — the Caddyfile is generated, so the
   new route and the `users` targets follow automatically.

## Login without SSO (password login)

SSO works now that dex has a public name, but the backends also keep
`ModelBackend` enabled, so a Django-admin session works for the whole app with
no IdP roundtrip. Either manage a user via
`nix run .#users -- set-password <email>`, or in the guest:

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

Then log in at `https://docs.selfhostix/admin/` (email + password) and open
`https://docs.selfhostix/` — SSO never involved.

> **CSRF in browsers:** Django ≥5.2 validates the `Origin` header on every
> unsafe request. Trusted origins are the HTTPS form of every demo name,
> derived once in `nix/net.nix` (`demo.net.origins`, with `demo.net.hosts` for
> `DJANGO_ALLOWED_HOSTS`). Because the origins are names rather than the host's
> address, they no longer change when the host's LAN IP does — only the hosts
> entries on clients do. After a rebuild, reset the password via
> `nix run .#users -- set-password` (or wipe `data/` for a fresh start).
>
> **Allowed hosts:** without every `Host` header browsers send, Django answers
> `400 DisallowedHost` on `/api` and `/admin` while `/` still loads (nginx
> serves the frontend statically, so a working homepage with broken login is
> the signature symptom).

## Gotchas

- Virtio NICs get unpredictable interface names, so the guest's static IP is
  matched on MAC address (see `nix/net.nix`).
- dex must bind `0.0.0.0` (not `127.0.0.1`) because the host proxy dials it
  over the tap; garage binds loopback because only the guest's own nginx talks
  to it. The firewall opens exactly those two upstream ports (80, 8080).
- Regenerating the CA (deleting `/etc/selfhostix-demo/certs`) invalidates
  every copy already distributed: rebuild the guest and re-run `provision`.
- The guest's root filesystem is ephemeral (erofs + a `/var/lib` volume
  only): the demo SSH key installed on it is lost on every reboot. The
  propagation apps (`users`, `seed`, `provision`, `clients`) reinstall it
  automatically (password fallback via `nixpkgs#sshpass`).
- Only `/var/lib` persists (postgres, garage, media). Users and the seed doc
  live in Docs' postgres — they survive reboots, but a fresh
  `var-lib-selfhostix.img` means re-running `nix run .#users -- upsert` +
  `nix run .#seed`.
- One guest IP serves several vhosts, so anything reaching the guest directly
  must send the right `Host` header — the scripts use `curl --resolve`, and a
  bare-IP request always lands on Docs (the default server).
- Enterprise/venue WiFi often isolates clients (no machine-to-machine
  traffic): if `curl http://<host-LAN-IP>/` works on the host but a second
  machine's browser hangs, check AP client isolation before blaming the proxy.
