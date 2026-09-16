# Docs quickstart — isolated Nix VM on loopback

Runs the existing nixpkgs packages (`lasuite-docs` backend, `lasuite-docs-frontend`,
`lasuite-docs-collaboration-server`) as a full stack in an ephemeral QEMU VM.
No Docker, no repo pollution. Same config is reused for the libvirt testing VM.

## Layout

| File | Purpose |
|---|---|
| `flake.nix` | `nixosConfigurations.quickstart` (ephemeral) + `testing` (libvirt) |
| `docs-vm.nix` | Shared system: `services.lasuite-docs` + dex (mock OIDC) + garage (S3) + local postgres/redis + nginx. Adapted from `nixos/tests/web-apps/lasuite-docs.nix` |
| `testing-vm.nix` | Testing-VM delta (hostname, key-only SSH) |
| `run.sh` | Boot script (uses the NixOS runner, direct kernel boot) |
| `vm-loader` | Built `system.build.vmWithBootLoader` output (self-contained qcow2 backing image) |
| `vm-disk.qcow2` | Writable overlay (all VM state; delete for a fresh start) |

## Start

```bash
nix --extra-experimental-features 'nix-command flakes' \
  build .#nixosConfigurations.quickstart.config.system.build.vmWithBootLoader -o vm-loader
./run.sh        # -nographic console; Ctrl-a x to quit (kills the VM)
```

First boot takes ~3–5 min (postgres init, django migrate, garage layout+bucket).
Wait for `http://docs.local:8081/` → 200 (add `127.0.0.1 docs.local` to `/etc/hosts`
for browser use, or `curl --resolve docs.local:8081:127.0.0.1 …`).

## Loopback endpoints (host → guest)

| URL | Guest service |
|---|---|
| `http://docs.local:8081/` | nginx: frontend + `/api` + `/collaboration` |
| `http://127.0.0.1:8082/dex/…` | dex mock OIDC (browser side) |
| `http://127.0.0.1:8083/` | garage S3 API |
| `ssh -p 2221 root@127.0.0.1` | guest shell (password `root`) |

Login: dex mock user `admin` / `password`. Full login+create-doc flow was verified
with curl (authenticate → dex mock → callback → `POST /api/v1.0/documents/`).

Note: OIDC redirect URLs point at `http://127.0.0.1:8080/dex/…` (guest-local);
from the host rewrite the port to `8082`, keeping all query params.

## Testing without SSO (password login)

The backend keeps `ModelBackend` enabled alongside OIDC, and the frontend's
only auth gate is `GET /api/v1.0/users/me/` with the session cookie — so a
Django-admin session works for the whole app, no IdP roundtrip. Verified:

```bash
# 1. in the guest: create a superuser with password
ssh -p 2221 root@127.0.0.1
lasuite-docs-manage createsuperuser --email tester@docs.local --password <secret>
lasuite-docs-manage shell <<'EOF'
from django.contrib.auth import get_user_model
u = get_user_model().objects.get(admin_email='tester@docs.local')
# OIDC normally fills these; the user serializer 500s without an email
u.email = 'tester@docs.local'
u.full_name = 'Test User'
u.short_name = 'Test'
u.language = 'en-us'
u.save()
EOF
```

```text
2. in the browser: log in at http://docs.local:8081/admin/ (email + password)
3. open http://docs.local:8081/ — you are logged in, SSO never involved
```

API-only equivalent: POST the credentials to `/admin/login/` (with CSRF token),
then call the API with the `sessionid`/`csrftoken` cookies. Backend pytest suites
do the same via `client.force_login(user)` (`src/backend/core/tests/`).

> **CSRF in browsers (fixed in config):** Django ≥5.2 validates the `Origin`
> header on *every* unsafe request — browsers always send it, bare `curl`
> doesn't, which is why scripted flows worked while browsers got
> `CSRF verification failed`. A bare `DJANGO_CSRF_TRUSTED_ORIGINS="http://*"`
> never matches; the config now lists explicit origins
> (`http://docs.local:8081`, `localhost`, `127.0.0.1`). If password login
> fails after a rebuild from an old disk, reset it:
> `lasuite-docs-manage shell` → `u.set_password(...)` (or use a fresh
> `vm-disk.qcow2`).

## Fresh start / after config changes

Direct boot pins `init=<toplevel>` from the **disk's** store, so a rebuilt image
needs a fresh overlay:

```bash
rm -f vm-disk.qcow2 && ./run.sh
```

## Testing VM (libvirt, later)

Same `docs-vm.nix` + `testing-vm.nix`: build
`.#nixosConfigurations.testing.config.system.build.vmWithBootLoader`,
import the backing `nixos.qcow2` into virt-manager/virsh (virtio disk+net,
4G RAM), or deploy with `nixos-anywhere --flake .#testing`.
Set your SSH key in `testing-vm.nix` first.

## Gotchas found while building this

- The NixOS `run-*-vm` runner shares `/nix/store` via virtiofsd, which fails
  rootless here → the image sets `sharedDirectories = mkForce {}` and
  `directBoot.enable = true` in `vmVariantWithBootLoader`, making the qcow2
  fully standalone.
- `build.vm` reads `virtualisation.vmVariant`, `build.vmWithBootLoader` reads
  `virtualisation.vmVariantWithBootLoader` **only** — set both.
- QEMU SLIRP forwards arrive on the guest eth0 address, so dex/garage must bind
  `0.0.0.0` (not `127.0.0.1`) and the guest firewall must open 8080/9000.
  Still loopback-only from the host's perspective.
- `qemu-system-x86_64` from nixpkgs (`qemu-host-cpu-only`) works with
  `-machine q35,accel=kvm:tcg`; system qemu works too for manual boots.
