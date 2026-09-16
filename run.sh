#!/usr/bin/env bash
# Boot the isolated Docs quickstart VM.
# The image (vm-loader) is self-contained (useBootLoader + no virtiofs
# shares), so the stock NixOS runner works. QEMU SLIRP maps guest ports
# to host loopback:
#   guest 80   (nginx: frontend + API + collab proxy) -> host 8081
#   guest 8080 (dex mock OIDC, browser side)          -> host 8082
#   guest 9000 (garage S3 API)                        -> host 8083
#   guest 22   (ssh, root/root)                       -> host 2221
set -euo pipefail
cd "$(dirname "$0")"
export NIX_DISK_IMAGE="${NIX_DISK_IMAGE:-$PWD/vm-disk.qcow2}"
export TMPDIR="${TMPDIR:-/home/youpaw/.cache/docs-quickstart-tmp}"
mkdir -p "$TMPDIR"
# Serial console on stdio (runner appends it after $QEMU_OPTS).
export QEMU_KERNEL_PARAMS="${QEMU_KERNEL_PARAMS:-console=ttyS0,115200n8}"
exec ./vm-loader/bin/run-docs-quickstart-vm -nographic "$@"
