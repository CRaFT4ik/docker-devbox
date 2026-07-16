#!/bin/bash
# VPN_MODE=singbox — sing-box TUN fed by the Remnawave VLESS+Reality subscription.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${DIR}/common.sh"

CFG=/var/lib/devbox/singbox/config.json
mkdir -p /var/lib/devbox/singbox

nft_preflight
set_resolver

SRC="$("${DIR}/fetch-subscription.sh")"          # validated sub.json path

# Structural patch only (no coupling to tags/servers/keys):
#  - TUN inbound: Docker-compatible transparent routing
#  - route: force loop-prevention regardless of what the panel emitted
jq '(.inbounds[] | select(.type=="tun")) |= . + {auto_redirect:true, strict_route:false}
    | .route.auto_detect_interface = true' "$SRC" > "$CFG"

sing-box check -c "$CFG" || die "sing-box check failed on the fetched config ($SRC)"

sudo pkill -x sing-box 2>/dev/null || true       # avoid clash_api/mixed-in port clash on restart
pre="$(snapshot_tuns)"
sudo sing-box run -c "$CFG" >/var/log/sing-box.log 2>&1 &
log "sing-box started (singbox mode); waiting for TUN..."

iface="$(wait_for_new_tun_ip "$pre")"
echo "$iface" | sudo tee /run/devbox-vpn-iface >/dev/null
log "TUN up: $iface"
