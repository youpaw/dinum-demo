set -euo pipefail
# Print the primary host LAN origin, e.g. http://<host-LAN-IP> (no trailing
# slash). Used to tell Django (SELFHOSTIX_PUBLIC_ORIGIN) and seed URLs which origin
# browsers actually use, so no /etc/hosts edits are needed anywhere.
# Fails silently (empty output) when no uplink route exists.
ip route get 1.1.1.1 2>/dev/null | awk '/src/{for(i=1;i<=NF;i++) if($i=="src"){print "http://"$(i+1); exit}}'
