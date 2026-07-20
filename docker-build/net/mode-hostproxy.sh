#!/bin/bash
# VPN_MODE=hostproxy — sing-box TUN forwarding everything to the host's SOCKS5.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${DIR}/common.sh"

CFG=/var/lib/devbox/singbox/config.json
LOG=/var/lib/devbox/singbox/sing-box.log
mkdir -p /var/lib/devbox/singbox
[ -n "${HOSTPROXY_PORT:-}" ] || die "HOSTPROXY_PORT is not set (required for VPN_MODE=hostproxy)"

set_resolver

sed "s/__HOSTPROXY_PORT__/${HOSTPROXY_PORT}/" "${DIR}/singbox-base.json" > "$CFG"
sing-box check -c "$CFG" || die "sing-box check failed on the hostproxy config"

sudo pkill -x sing-box 2>/dev/null || true
pre="$(snapshot_tuns)"
sudo sh -c "sing-box run -c '$CFG' >'$LOG' 2>&1 &"
log "sing-box started (hostproxy mode -> host.docker.internal:${HOSTPROXY_PORT}); waiting for TUN... (log: $LOG)"

if ! iface="$(wait_for_new_tun_ip "$pre")"; then
    log "TUN did not come up — last sing-box log lines:"
    tail -n 20 "$LOG" 2>/dev/null | sed 's/^/[sing-box] /' >&2 || true
    die "sing-box failed to bring up the TUN interface"
fi
echo "$iface" | sudo tee /run/devbox-vpn-iface >/dev/null
log "TUN up: $iface"
