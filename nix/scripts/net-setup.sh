set -euo pipefail
# Host end of the guest's network (Debian, one-time per boot): the tap the
# microVM attaches to, the gateway address on it, and forwarding + NAT so the
# guest egresses via the LAN uplink. Idempotent; safe to re-run.
#
#   sudo nix run .#net-setup
#   ip addr show tap-selfhostix
#
# One guest, one wire: the tap IS the link, so it carries the gateway address
# itself — no bridge in between. (A bridge only earns its keep once several
# guests must share one L2 segment; a tap's multi-queue support fans ONE
# guest's vCPUs across queues of ITS NIC and never joins two guests.) Adding a
# second guest means adding a bridge here and a tap per guest.
#
# Addresses come from nix/services.nix via the GUEST_* data nix/apps.nix
# injects above:
#   192.168.100.1   host end of tap-selfhostix (gateway for the guest)
#   192.168.100.10  selfhostix guest (docs + drive)

TAP="${TAP:-$GUEST_TAP}"
TAP_IP="${TAP_IP:-$GUEST_GATEWAY/24}"
SUBNET="${SUBNET:-192.168.100.0/24}"
UPLINK="${UPLINK:-$(ip route show default | awk '{print $5}' | head -n1)}"

[ "$(id -u)" = "0" ] || die "run as root: sudo nix run .#net-setup"
[ -n "$UPLINK" ] || die "no default uplink found"

if ! ip link show "$TAP" >/dev/null 2>&1; then
  msg "creating $TAP (multi-queue, required by cloud-hypervisor)"
  ip tuntap add dev "$TAP" mode tap user "${SUDO_USER:-root}" multi_queue
else
  # cloud-hypervisor opens the tap multiqueue; a tap created without
  # multi_queue (e.g. by an older revision of this script) fails attach with
  # OpenTap(MultiQueueNoTapSupport) and must be recreated.
  # IFF_MULTI_QUEUE is bit 0x100 in tun_flags.
  flags="$(cat "/sys/class/net/$TAP/tun_flags" 2>/dev/null || echo 0x0)"
  if [ "$((flags & 0x100))" = "0" ]; then
    msg "$TAP lacks multi-queue support, recreating"
    ip link set "$TAP" down 2>/dev/null || true
    ip tuntap del dev "$TAP" mode tap
    ip tuntap add dev "$TAP" mode tap user "${SUDO_USER:-root}" multi_queue
  else
    msg "$TAP exists (multi-queue)"
  fi
fi

ip addr show "$TAP" | grep -q "${TAP_IP%/*}" || ip addr add "$TAP_IP" dev "$TAP"
ip link set "$TAP" up

# NOTE: `ip link show $TAP` reporting `state DOWN` / NO-CARRIER here is
# expected: a persistent tap has no carrier until a hypervisor attaches.
# It flips to LOWER_UP once the microVM boots.

msg "enabling forwarding + NAT via $UPLINK"
sysctl -w net.ipv4.ip_forward=1 >/dev/null
if command -v nft >/dev/null 2>&1; then
  nft list table ip nat >/dev/null 2>&1 || nft add table ip nat
  nft list chain ip nat POSTROUTING >/dev/null 2>&1 || \
    nft add chain ip nat POSTROUTING '{ type nat hook postrouting priority 100 ; }'
  nft add rule ip nat POSTROUTING oifname "$UPLINK" ip saddr "$SUBNET" masquerade 2>/dev/null || true
else
  iptables -t nat -C POSTROUTING -s "$SUBNET" -o "$UPLINK" -j MASQUERADE 2>/dev/null || \
    iptables -t nat -A POSTROUTING -s "$SUBNET" -o "$UPLINK" -j MASQUERADE
  iptables -C FORWARD -i "$TAP" -o "$UPLINK" -j ACCEPT 2>/dev/null || \
    iptables -A FORWARD -i "$TAP" -o "$UPLINK" -j ACCEPT
  iptables -C FORWARD -i "$UPLINK" -o "$TAP" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || \
    iptables -A FORWARD -i "$UPLINK" -o "$TAP" -m state --state RELATED,ESTABLISHED -j ACCEPT
fi

msg "net ready: $TAP $TAP_IP -> guest $GUEST_IP via $UPLINK"
