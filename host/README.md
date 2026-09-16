# Host reverse proxy unit for Debian (the microVM itself is started manually).
#
# Install:
#   sudo cp host/caddy.service /etc/systemd/system/   # edit paths first
#   sudo systemctl daemon-reload
#   sudo systemctl enable --now caddy.service
#
# Re-copy + daemon-reload after editing the repo copy — systemd runs the
# /etc copy, not this file.
