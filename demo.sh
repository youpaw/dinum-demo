#!/usr/bin/env bash
# Unified entry point for the Selfhostix collaboration demo.
#
#   ./demo.sh microvm [run|eval]     boot/eval the Selfhostix microVM server (Debian-native)
#   ./demo.sh users [args...]        manage Selfhostix users (./propagate.sh users …)
#   ./demo.sh seed                   create the shared demo doc (./propagate.sh seed)
#   ./demo.sh clients [N]            boot N Bureautix demo clients + provision them
#   ./demo.sh provision [N]          provision already-booted clients (./propagate.sh provision)
#   ./demo.sh all                    users + seed + clients (server must run already)
#   ./demo.sh status                 show server + client health
#   ./demo.sh stop                   shut down client VMs (keep disks)
#   ./demo.sh logs [server|c1|c2]    tail server/client journal via SSH
#   ./demo.sh clean                  stop clients + delete overlays and seed state
#
# VM lifecycle lives here; all in-guest state (users, docs, client config)
# lives in ./propagate.sh, which also owns SSH key generation/installation.
#
# Server flow (see ./microvm/docs-guest.nix):
#   sudo ./host/net-setup.sh                        # tap-selfhostix 192.168.100.1
#   ./demo.sh microvm run                           # boot selfhostix (foreground)
#   ./demo.sh users upsert                          # manage users separately
#   ./demo.sh seed                                  # shared doc (requires users first)
# Guest adrs: docs .10, drive .11 (reserved), grist .12 (reserved).
#
# Environment (all optional):
#   NUM_CLIENTS=2  MICROVM_IP=192.168.100.10
#   SELFHOSTIX_SSH_TARGET=... (users/seed/logs SSH target, default MICROVM_IP)
#   CLIENT_SSH_BASE=2221 (client i listens on localhost:2220+i)
#   SEED_DOC_TITLE=... SELFHOSTIX_URL=...
#   ALICE_PASS=... BOB_PASS=...  DATA_DIR=./data  HEADLESS=1 (clients w/o GUI)
#   NIX_BIN=/nix/var/nix/profiles/default/bin/nix (if nix is not on PATH)
#
# Network: microVM server on tap 192.168.100.0/24 behind the host proxy
# (host/Caddyfile). Bureautix clients run as nix QEMU guests (slirp user
# networking + hostfwd SSH on localhost:CLIENT_SSH_BASE+i); guests reach the
# server through the host, the host reaches guests via the forwarded ports.
set -euo pipefail
cd "$(dirname "$0")"

msg() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31mXX\033[0m %s\n' "$*" >&2; exit 1; }

NUM_CLIENTS="${NUM_CLIENTS:-2}"
MICROVM_IP="${MICROVM_IP:-192.168.100.10}"
CLIENT_SSH_BASE="${CLIENT_SSH_BASE:-2221}"
DATA_DIR="${DATA_DIR:-$PWD/data}"
KEY_DIR="$DATA_DIR/demo-ssh"
SEED_ENV="$DATA_DIR/seed.env"
CLIENT_ROOT_PASS="nixos"

# Nix lives outside PATH on some hosts (e.g. /nix/var/nix/profiles/default/bin
# with no /usr/bin/nix symlink and no profile.d sourcing in systemd units or
# minimal shells). Resolve once, allow override: NIX_BIN=/path/to/nix ./demo.sh …
NIX_BIN="${NIX_BIN:-$(command -v nix 2>/dev/null || echo /nix/var/nix/profiles/default/bin/nix)}"
[ -x "$NIX_BIN" ] || die "nix binary not executable: $NIX_BIN (set NIX_BIN explicitly)"
NIX_BUILDBIN="$(dirname "$NIX_BIN")/nix-build"

# Guest rebuilds regenerate host keys; pinning them would brick every SSH
# helper on rebuild, so all demo SSH ignores known_hosts.
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)

client_name() { echo "selfhostix-c$1"; }
client_ssh_port() { echo "$((CLIENT_SSH_BASE + $1 - 1))"; } # c1 -> 2221, c2 -> 2222
client_runner() { # -> path to bin/run-*-vm built by `nix-build -A vm`
  find client-loader/bin -maxdepth 1 -name 'run-*-vm' | head -n1
}

ensure_ssh_key() {
  if [ ! -f "$KEY_DIR/demo" ]; then
    msg "generating demo SSH key in $KEY_DIR"
    mkdir -p "$KEY_DIR"
    ssh-keygen -t ed25519 -N "" -f "$KEY_DIR/demo" -C "selfhostix" >/dev/null
  fi
}

# ssh using the demo key; falls back to password via nixpkgs sshpass.
# Honors SSH_PORT (client guests are reached via localhost hostfwd ports).
demo_ssh() { # $1=user $2=host $3=password [cmd...]
  local user="$1" host="$2" pass="$3"; shift 3
  local port="${SSH_PORT:-22}"
  if ssh "${SSH_OPTS[@]}" -o BatchMode=yes -o ConnectTimeout=5 -p "$port" \
      -i "$KEY_DIR/demo" "$user@$host" true 2>/dev/null; then
    ssh "${SSH_OPTS[@]}" -p "$port" -i "$KEY_DIR/demo" "$user@$host" "$@"
  else
    warn "key auth not ready for $user@$host, using password (one-time)"
    "$NIX_BIN" --extra-experimental-features 'nix-command flakes' run nixpkgs#sshpass -- \
      -p"$pass" ssh "${SSH_OPTS[@]}" -p "$port" "$user@$host" "$@"
  fi
}

install_demo_key() { # $1=user $2=host $3=password
  local port="${SSH_PORT:-22}"
  msg "installing demo SSH key on $1@$2"
  local keydata; keydata="$(cat "$KEY_DIR/demo.pub")"
  "$NIX_BIN" --extra-experimental-features 'nix-command flakes' run nixpkgs#sshpass -- \
    -p"$3" ssh "${SSH_OPTS[@]}" -p "$port" "$1@$2" \
    "mkdir -p ~/.ssh && chmod 700 ~/.ssh && grep -qF '$keydata' ~/.ssh/authorized_keys 2>/dev/null || echo '$keydata' >> ~/.ssh/authorized_keys"
}

wait_ssh() { # $1=user $2=host $3=password
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

stop_client() { # $1=name
  local name="$1"
  local pidfile="$DATA_DIR/$name.pid"
  [ -f "$pidfile" ] || return 0
  local pid; pid="$(cat "$pidfile")"
  if kill -0 "$pid" 2>/dev/null; then
    msg "stopping $name (pid $pid)"
    kill "$pid" 2>/dev/null || true
    sleep 2
    kill -9 "$pid" 2>/dev/null || true
    # Catch an orphaned qemu if the runner wrapper died first.
    pkill -f "$name-disk.qcow2" 2>/dev/null || true
  fi
  rm -f "$pidfile"
}

cmd_users() {
  # Pass-through to the unified propagation script (owns users.env + keys).
  MICROVM_IP="$MICROVM_IP" KEY_DIR="$KEY_DIR" DATA_DIR="$DATA_DIR" \
    ./propagate.sh users "${@:-upsert}"
}

cmd_seed() {
  # Pass-through (propagate.sh detects the host origin for seed links itself).
  MICROVM_IP="$MICROVM_IP" KEY_DIR="$KEY_DIR" DATA_DIR="$DATA_DIR" \
    ./propagate.sh seed
}

cmd_provision() {
  # Provision already-booted clients (hosts entry, autostart, bookmarks).
  MICROVM_IP="$MICROVM_IP" KEY_DIR="$KEY_DIR" DATA_DIR="$DATA_DIR" \
    ./propagate.sh provision "${1:-$NUM_CLIENTS}"
}

cmd_clients() {
  local n="${1:-$NUM_CLIENTS}"
  ensure_ssh_key
  msg "building bureautix-example client image (nix-build -A vm, once)"
  "$NIX_BUILDBIN" ./bureautix-example -A vm -o client-loader
  local runner; runner="$(client_runner)"
  [ -n "$runner" ] || die "no run-*-vm runner found in client-loader/bin/"
  local i name port
  for i in $(seq 1 "$n"); do
    name="$(client_name "$i")"; port="$(client_ssh_port "$i")"
    start_client "$name" "$PWD/$runner" "$DATA_DIR/$name-disk.qcow2" "$port"
  done
  for i in $(seq 1 "$n"); do
    name="$(client_name "$i")"; port="$(client_ssh_port "$i")"
    echo "==> $name at localhost:$port"
    if SSH_PORT="$port" wait_ssh root localhost "$CLIENT_ROOT_PASS"; then
      SSH_PORT="$port" install_demo_key root localhost "$CLIENT_ROOT_PASS" || true
    else
      die "$name: SSH not up; start it, then run: ./demo.sh provision"
    fi
  done
  # Client OS + seed-doc provisioning (fails fast without seed state).
  cmd_provision "$n"
  msg "clients up (QEMU windows open per client; HEADLESS=1 for no GUI)."
}

cmd_status() {
  local api="${SELFHOSTIX_SSH_TARGET:-$MICROVM_IP}"
  curl -ks -o /dev/null -w 'server http://'"$api"'/ -> %{http_code}\n' --max-time 5 "http://$api/" || true
  echo "---"
  local i name port pid
  for i in $(seq 1 "$NUM_CLIENTS"); do
    name="$(client_name "$i")"; port="$(client_ssh_port "$i")"
    if [ -f "$DATA_DIR/$name.pid" ] && kill -0 "$(cat "$DATA_DIR/$name.pid")" 2>/dev/null; then
      pid="$(cat "$DATA_DIR/$name.pid")"
      if SSH_PORT="$port" ssh "${SSH_OPTS[@]}" -o BatchMode=yes -o ConnectTimeout=3 \
          -i "$KEY_DIR/demo" root@localhost true 2>/dev/null; then
        echo "$name: running (pid $pid), ssh localhost:$port OK"
      else
        echo "$name: running (pid $pid), ssh localhost:$port not ready (first boot installs the system)"
      fi
    else
      echo "$name: stopped"
    fi
  done
  if [ -f "$SEED_ENV" ]; then
    # shellcheck disable=SC1090,SC1091
    . "$SEED_ENV"; echo "seed doc: ${SEED_DOC_URL:-unknown}"
  fi
}

cmd_stop() {
  local i
  for i in $(seq 1 "$NUM_CLIENTS"); do
    stop_client "$(client_name "$i")"
  done
}

cmd_logs() {
  local target="${1:-server}"
  if [ "$target" = "server" ]; then
    demo_ssh root "${SELFHOSTIX_SSH_TARGET:-$MICROVM_IP}" "root" "journalctl -e --no-pager -n 100"
    return 0
  fi
  local i="${target#c}"
  case "$target" in
    c[0-9]*) SSH_PORT="$(client_ssh_port "$i")" demo_ssh root localhost "$CLIENT_ROOT_PASS" "journalctl -e --no-pager -n 100" ;;
    *) die "usage: ./demo.sh logs [server|c1|c2...]" ;;
  esac
}

cmd_clean() {
  read -r -p "Stop clients and DELETE disks + seed state in $DATA_DIR? [y/N] " ans
  [ "$ans" = "y" ] || exit 0
  local i
  for i in $(seq 1 "$NUM_CLIENTS"); do
    stop_client "$(client_name "$i")"
  done
  rm -f "$DATA_DIR"/selfhostix-c*-disk.qcow2 "$DATA_DIR"/selfhostix-c*.log "$DATA_DIR"/selfhostix-c*.pid "$SEED_ENV"
  # One-time leftovers from the retired libvirt path.
  rm -f "$DATA_DIR"/selfhostix-*.xml "$DATA_DIR"/*-VARS.fd
  msg "cleaned (users.env + demo-ssh key kept)"
}

cmd_microvm() {
  # Debian-native microVM server (no libvirt). TAP must exist first:
  #   sudo ./host/net-setup.sh
  # Browsers reach the guest through the host proxy under the host LAN IP
  # (no /etc/hosts edits needed), so export it for Django's CSRF origins
  # (see SELFHOSTIX_PUBLIC_ORIGIN in docs-net.nix). --impure is required for the
  # guest to read it; without it evaluation falls back to selfhostix only.
  if [ -z "${SELFHOSTIX_PUBLIC_ORIGIN:-}" ] && [ -x ./host/detect-origin.sh ]; then
    SELFHOSTIX_PUBLIC_ORIGIN="$(./host/detect-origin.sh || true)"
  fi
  if [ -n "${SELFHOSTIX_PUBLIC_ORIGIN:-}" ]; then
    export SELFHOSTIX_PUBLIC_ORIGIN
    msg "trusting browser origin $SELFHOSTIX_PUBLIC_ORIGIN"
  else
    warn "host LAN origin undetectable — Django trusts selfhostix/guest IP only"
  fi
  local sub="${1:-run}"
  case "$sub" in
    eval)
      msg "evaluating selfhostix (no boot)"
      "$NIX_BIN" --extra-experimental-features 'nix-command flakes' \
        eval --impure .#nixosConfigurations.selfhostix.config.system.build.toplevel --no-link --print-out-paths
      ;;
    run)
      ip link show tap-selfhostix >/dev/null 2>&1 || \
        die "tap-selfhostix missing — run: sudo ./host/net-setup.sh"
      msg "booting selfhostix (cloud-hypervisor, foreground, Ctrl-C to stop)"
      "$NIX_BIN" --extra-experimental-features 'nix-command flakes' \
        run --impure .#nixosConfigurations.selfhostix.config.microvm.runner.cloud-hypervisor
      ;;
    *) die "usage: ./demo.sh microvm [run|eval]" ;;
  esac
}

cmd_all() {
  # Full demo assuming the microVM server already runs
  # (see `./demo.sh microvm run`); fails fast otherwise.
  local api="${SELFHOSTIX_SSH_TARGET:-$MICROVM_IP}"
  [ "$(curl -ks -o /dev/null -w '%{http_code}' --max-time 5 "http://$api/")" = "200" ] \
    || die "server not reachable at http://$api/ — start it first: ./demo.sh microvm run"
  cmd_users upsert; cmd_seed; cmd_clients "$NUM_CLIENTS"
}

case "${1:-help}" in
  microvm) shift; cmd_microvm "${1:-run}" ;;
  users) shift; cmd_users "$@" ;;
  seed) cmd_seed ;;
  provision) shift; cmd_provision "${1:-$NUM_CLIENTS}" ;;
  clients) shift; cmd_clients "${1:-$NUM_CLIENTS}" ;;
  all) cmd_all ;;
  status) cmd_status ;;
  stop) cmd_stop ;;
  logs) shift; cmd_logs "${1:-server}" ;;
  clean) cmd_clean ;;
  *) sed -n '2,32p' "$0" ;;
esac
