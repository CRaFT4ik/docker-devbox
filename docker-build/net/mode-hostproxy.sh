#!/bin/bash
# VPN_MODE=hostproxy — sing-box TUN forwarding everything to the host's SOCKS5.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${DIR}/common.sh"

CFG=/var/lib/devbox/singbox/config.json
LOG=/var/lib/devbox/singbox/sing-box.log
mkdir -p /var/lib/devbox/singbox
[ -n "${HOSTPROXY_PORT:-}" ] || die "HOSTPROXY_PORT is not set (required for VPN_MODE=hostproxy)"

# Where the upstream SOCKS5 proxy lives. Default: the Docker host. Set
# HOSTPROXY_HOST to a LAN/router IP to dial that instead; empty falls back to
# the host, so the default behaviour is unchanged.
HOSTPROXY_HOST="${HOSTPROXY_HOST:-host.docker.internal}"

# DNS server the container resolves through (reached via the host proxy).
# Override for a corporate/VPN resolver.
HOSTPROXY_DNS_SERVER="${HOSTPROXY_DNS_SERVER:-8.8.8.8}"

set_resolver

sed -e "s/__HOSTPROXY_HOST__/${HOSTPROXY_HOST}/" \
    -e "s/__HOSTPROXY_PORT__/${HOSTPROXY_PORT}/" \
    -e "s/__DNS_SERVER__/${HOSTPROXY_DNS_SERVER}/" \
    "${DIR}/singbox-base.json" > "$CFG"
sing-box check -c "$CFG" || die "sing-box check failed on the hostproxy config"

sudo pkill -x sing-box 2>/dev/null || true
pre="$(snapshot_tuns)"
sudo sh -c "sing-box run -c '$CFG' >'$LOG' 2>&1 &"
log "sing-box started (hostproxy mode -> ${HOSTPROXY_HOST}:${HOSTPROXY_PORT}); waiting for TUN... (log: $LOG)"

if ! iface="$(wait_for_new_tun_ip "$pre")"; then
    log "TUN did not come up — last sing-box log lines:"
    tail -n 20 "$LOG" 2>/dev/null | sed 's/^/[sing-box] /' >&2 || true
    die "sing-box failed to bring up the TUN interface"
fi
echo "$iface" | sudo tee /run/devbox-vpn-iface >/dev/null
log "TUN up: $iface"

# TUN is up and auto_route has installed its rules; keep the upstream SOCKS dial
# (and host services) out of the tunnel, so reaching the proxy — the host, or a
# LAN/router IP — goes out the host NIC instead of looping back through the TUN.
exclude_proxy_host_from_tun "$HOSTPROXY_HOST"
