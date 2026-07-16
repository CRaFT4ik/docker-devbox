#!/bin/bash
# VPN_MODE=hostproxy — sing-box TUN forwarding everything to the host's SOCKS5.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${DIR}/common.sh"

CFG=/var/lib/devbox/singbox/config.json
mkdir -p /var/lib/devbox/singbox
[ -n "${HOST_SOCKS_PORT:-}" ] || die "HOST_SOCKS_PORT is not set (required for VPN_MODE=hostproxy)"

nft_preflight
set_resolver

sed "s/__HOST_SOCKS_PORT__/${HOST_SOCKS_PORT}/" "${DIR}/singbox-base.json" > "$CFG"
sing-box check -c "$CFG" || die "sing-box check failed on the hostproxy config"

sudo pkill -x sing-box 2>/dev/null || true
pre="$(snapshot_tuns)"
sudo sing-box run -c "$CFG" >/var/log/sing-box.log 2>&1 &
log "sing-box started (hostproxy mode -> host.docker.internal:${HOST_SOCKS_PORT}); waiting for TUN..."

iface="$(wait_for_new_tun_ip "$pre")"
echo "$iface" | sudo tee /run/devbox-vpn-iface >/dev/null
log "TUN up: $iface"
