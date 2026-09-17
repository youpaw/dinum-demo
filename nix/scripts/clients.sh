set -euo pipefail
# Boot N Bureautix demo clients + provision them (needs seed first).
#   nix run .#clients -- [N]
#
# The client image is bureautix-example (a submodule) with nix/client.nix
# layered on via `extendModules`: the upstream VM builder takes no extra
# modules, and the demo needs two things it cannot set from outside — an
# en-US keyboard and the demo SSH key. The key must be baked in because
# securix ships `PermitRootLogin prohibit-password`: there is no password
# path to install it over afterwards.
cd "${DEMO_ROOT:-$PWD}"

n="${1:-$NUM_CLIENTS}"
ensure_demo_key
SELFHOSTIX_DEMO_PUBKEY="$(cat "$KEY_DIR/demo.pub")"
export SELFHOSTIX_DEMO_PUBKEY

msg "building bureautix-example client image (once; --impure bakes in the demo key)"
nix-build --impure --expr \
  '((import ./bureautix-example {}).vmTerminal.system.extendModules {
      modules = [ ./nix/client.nix ];
    }).config.system.build.vm' \
  -o client-loader

runner="$(client_runner)"
[ -n "$runner" ] || die "no run-*-vm runner found in client-loader/bin/"
for i in $(seq 1 "$n"); do
  name="$(client_name "$i")"; port="$(client_ssh_port "$i")"
  start_client "$name" "$PWD/$runner" "$DATA_DIR/$name-disk.qcow2" "$port"
done
for i in $(seq 1 "$n"); do
  name="$(client_name "$i")"; port="$(client_ssh_port "$i")"
  msg "$name at localhost:$port"
  SSH_PORT="$port" wait_ssh root localhost \
    || die "$name: SSH not up; start it, then run: nix run .#provision -- $n"
done
# Client OS + seed-doc provisioning (fails fast without seed state).
provision "$n"
msg "clients up (QEMU windows open per client; HEADLESS=1 for no GUI)."
