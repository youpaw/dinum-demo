set -euo pipefail
# Boot/eval the demo guest — one microVM for every service (Debian-native, no
# libvirt).
#   nix run .#microvm -- [run|eval]
# The tap must exist first: sudo nix run .#net-setup
#
# Browsers reach the services through the host proxy under the host LAN IP (no
# /etc/hosts edits needed), so export that origin for Django's CSRF/allowed
# hosts (see SELFHOSTIX_PUBLIC_ORIGIN in nix/guest.nix). --impure is required
# for the guest to read it; without it evaluation falls back to the service
# domains and the guest IP only.
cd "${DEMO_ROOT:-$PWD}"

if [ -z "${SELFHOSTIX_PUBLIC_ORIGIN:-}" ] && command -v detect-origin >/dev/null 2>&1; then
  SELFHOSTIX_PUBLIC_ORIGIN="$(detect-origin || true)"
fi
if [ -n "${SELFHOSTIX_PUBLIC_ORIGIN:-}" ]; then
  export SELFHOSTIX_PUBLIC_ORIGIN
  msg "trusting browser origin $SELFHOSTIX_PUBLIC_ORIGIN"
else
  warn "host LAN origin undetectable — Django trusts the service domains/guest IP only"
fi

nix_flake() { nix --extra-experimental-features 'nix-command flakes' "$@"; }
config=".#nixosConfigurations.$GUEST_HOST.config"

case "${1:-run}" in
  eval)
    msg "evaluating $GUEST_HOST (no boot)"
    nix_flake eval --impure "$config.system.build.toplevel" --raw
    ;;
  run)
    ip link show "$GUEST_TAP" >/dev/null 2>&1 || \
      die "$GUEST_TAP missing — run: sudo nix run .#net-setup"
    msg "booting $GUEST_HOST (cloud-hypervisor, foreground, Ctrl-C to stop)"
    nix_flake run --impure "$config.microvm.runner.cloud-hypervisor"
    ;;
  *) die "usage: nix run .#microvm -- [run|eval]" ;;
esac
