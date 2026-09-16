#!/usr/bin/env bash
# Host tap networking for microVMs (Debian, one-time per boot).
# Creates tap-selfhostix (192.168.100.1/24), enables forwarding + NAT masquerade so
# guests egress via the LAN uplink. Idempotent; safe to re-run.
#
#   sudo ./host/net-setup.sh
#   ip addr show tap-selfhostix
#
# Subnet plan (see microvm/docs-guest.nix):
#   192.168.100.1   host tap endpoint (gateway for guests)
#   192.168.100.10  docs guest (host: selfhostix)
#   192.168.100.11  drive-microvm (reserved)
#   192.168.100.12  grist-microvm (reserved)
set -euo pipefail

TAP="${TAP:-tap-selfhostix}"
TAP_IP="${TAP_IP:-192.168.100.1/24}"
UPLINK="${UPLINK:-$(ip route show default | awk '{print $5}' | head -n1)}"

[ "$(id -u)" = "0" ] || { echo "XX run as root: sudo $0" >&2; exit 1; }
[ -n "$UPLINK" ] || { echo "XX no default uplink found" >&2; exit 1; }

if ! ip link show "$TAP" >/dev/null 2>&1; then
  echo "==> creating $TAP (multi-queue, required by cloud-hypervisor)"
  ip tuntap add dev "$TAP" mode tap user "${SUDO_USER:-root}" multi_queue
  ip addr add "$TAP_IP" dev "$TAP"
  ip link set "$TAP" up
else
  # cloud-hypervisor opens the tap multiqueue; a tap created without
  # multi_queue (e.g. by an older revision of this script) fails attach with
  # OpenTap(MultiQueueNoTapSupport) and must be recreated. IFF_MULTI_QUEUE is
  # bit 0x100 in tun_flags.
  flags="$(cat "/sys/class/net/$TAP/tun_flags" 2>/dev/null || echo 0x0)"
  if [ "$((flags & 0x100))" = "0" ]; then
    echo "==> $TAP lacks multi-queue support, recreating"
    ip link set "$TAP" down 2>/dev/null || true
    ip tuntap del dev "$TAP" mode tap
    ip tuntap add dev "$TAP" mode tap user "${SUDO_USER:-root}" multi_queue
    ip addr add "$TAP_IP" dev "$TAP"
    ip link set "$TAP" up
  else
    echo "==> $TAP exists (multi-queue), ensuring address/up"
    ip addr show "$TAP" | grep -q "${TAP_IP%/*}" || ip addr add "$TAP_IP" dev "$TAP"
    ip link set "$TAP" up
  fi
fi

# NOTE: `ip link show $TAP` reporting `state DOWN` / NO-CARRIER here is
# expected: a persistent tap has no carrier until a hypervisor attaches.
# It flips to LOWER_UP once `./demo.sh microvm run` boots.

echo "==> enabling forwarding + NAT via $UPLINK"
sysctl -w net.ipv4.ip_forward=1 >/dev/null
if command -v nft >/dev/null 2>&1; then
  nft list table ip nat >/dev/null 2>&1 || nft add table ip nat
  nft list chain ip nat POSTROUTING >/dev/null 2>&1 || \
    nft add chain ip nat POSTROUTING '{ type nat hook postrouting priority 100 ; }'
  nft add rule ip nat POSTROUTING oifname "$UPLINK" ip saddr 192.168.100.0/24 masquerade 2>/dev/null || true
else
  iptables -t nat -C POSTROUTING -s 192.168.100.0/24 -o "$UPLINK" -j MASQUERADE 2>/dev/null || \
    iptables -t nat -A POSTROUTING -s 192.168.100.0/24 -o "$UPLINK" -j MASQUERADE
  iptables -C FORWARD -i "$TAP" -o "$UPLINK" -j ACCEPT 2>/dev/null || \
    iptables -A FORWARD -i "$TAP" -o "$UPLINK" -j ACCEPT
  iptables -C FORWARD -i "$UPLINK" -o "$TAP" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || \
    iptables -A FORWARD -i "$UPLINK" -o "$TAP" -m state --state RELATED,ESTABLISHED -j ACCEPT
fi

echo "==> tap net ready: $TAP ${TAP_IP} via $UPLINK"
