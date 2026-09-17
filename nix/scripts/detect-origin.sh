set -euo pipefail
# Print the host's primary LAN IPv4 — the address the demo names must resolve
# to on client machines, since the host proxy is what terminates them.
# Fails silently (empty output) when no uplink route exists.
ip route get 1.1.1.1 2>/dev/null | awk '/src/{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}'
