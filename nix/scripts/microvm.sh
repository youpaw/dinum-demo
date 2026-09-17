set -euo pipefail
# Boot/eval the demo guest — one microVM for every service (Debian-native, no
# libvirt).
#   nix run .#microvm -- [run|eval]
#
# Prerequisites, both one-time per host:
#   sudo nix run .#net-setup      the tap the guest attaches to
#   sudo nix run .#host-install   the proxy, and the CA the guest must trust
#
# The CA cannot be pinned in the flake (it is generated per install and holds a
# private key), so it is read impurely at build time: the guest needs it to
# reach the OIDC issuer through the proxy the way a browser does.
cd "${DEMO_ROOT:-$PWD}"

[ -f "$CA_FILE" ] || die "demo CA missing: $CA_FILE (run: sudo nix run .#host-install)"
SELFHOSTIX_CA_FILE="$(readlink -f "$CA_FILE")"
export SELFHOSTIX_CA_FILE
msg "guest will trust $SELFHOSTIX_CA_FILE"

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
