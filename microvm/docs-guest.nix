# Docs service microVM guest (microvm.nix + cloud-hypervisor) for Debian hosts.
# Reuses docs-vm.nix (Docs stack) + docs-net.nix (static tap IP).
#
# MicroVM net (tap, host-routed):
#   host tap endpoint  192.168.100.1   (created by host/net-setup.sh)
#   docs guest         52:54:00:64:78:0a  192.168.100.10  (host: selfhostix)
#   drive (reserved)   52:54:00:64:78:11  192.168.100.11
#   grist (reserved)   52:54:00:64:78:12  192.168.100.12
# Host reverse proxy (host/Caddyfile) binds the LAN IP and forwards to .10:80,
# so only the proxy is LAN-visible; dex (:8080) and garage (:9000) stay inside
# the tap net unless explicitly proxied.
{ ... }:
{
  imports = [ ../docs-vm.nix ../docs-net.nix ];

  _module.args = {
    docsIp = "192.168.100.10";
    docsMac = "52:54:00:64:78:0a";
    gateway = "192.168.100.1";
    # Guest egress goes through host NAT (see host/net-setup.sh); resolve via
    # the LAN gateway like the host itself (host tap IP runs no DNS server).
    dns = "10.19.254.254";
    domain = "docs.selfhostix";
  };

  microvm = {
    hypervisor = "cloud-hypervisor";
    # Full Docs stack (Django/gunicorn + celery + postgres + garage + dex +
    # collaboration server) is hungry; 4 vCPU / 4 GB lagged noticeably.
    # Host has room (clients take 4 vCPU / 4 GB each); requires guest reboot.
    mem = 8192;
    vcpu = 8;
    # erofs = faster than squashfs, read-only root with prepopulated store.
    # (microvm.nix default; pinned here so perf intent is explicit.)
    interfaces = [{
      type = "tap";
      id = "tap-selfhostix";
      mac = "52:54:00:64:78:0a";
    }];
    volumes = [{
      mountPoint = "/var/lib";
      image = "var-lib.img";
      size = 8192;
    }];
  };

  networking.hostName = "selfhostix";
}
