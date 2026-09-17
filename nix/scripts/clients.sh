set -euo pipefail
# Boot N Bureautix demo clients + provision them (needs seed first).
#   nix run .#clients -- [N]
cd "${DEMO_ROOT:-$PWD}"

n="${1:-$NUM_CLIENTS}"
ensure_demo_key
msg "building bureautix-example client image (nix-build -A vm, once)"
nix-build ./bureautix-example -A vm -o client-loader
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
