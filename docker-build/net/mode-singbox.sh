#!/bin/bash
# VPN_MODE=singbox — sing-box TUN fed by the Remnawave VLESS+Reality subscription.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${DIR}/common.sh"

CFG=/var/lib/devbox/singbox/config.json
LOG=/var/lib/devbox/singbox/sing-box.log
mkdir -p /var/lib/devbox/singbox

set_resolver

SRC="$("${DIR}/fetch-subscription.sh")"          # validated sub.json path

# Structural patch only (no coupling to tags/servers/keys):
#  - route: force loop-prevention regardless of what the panel emitted.
# We do NOT touch the panel's tun inbound: it already ships auto_route+strict_route,
# and we deliberately do not add auto_redirect (it requires nftables writes, which
# OrbStack blocks from inside containers, and it is only needed to keep a
# host-published port working — not our concern for in-container traffic).
jq '.route.auto_detect_interface = true' "$SRC" > "$CFG"

sing-box check -c "$CFG" || die "sing-box check failed on the fetched config ($SRC)"

sudo pkill -x sing-box 2>/dev/null || true       # avoid clash_api/mixed-in port clash on restart
pre="$(snapshot_tuns)"
# Log to the volume dir (user-writable); run the redirect inside the root shell
# so sudo owns the file, not the unprivileged calling shell.
sudo sh -c "sing-box run -c '$CFG' >'$LOG' 2>&1 &"
log "sing-box started (singbox mode); waiting for TUN... (log: $LOG)"

if ! iface="$(wait_for_new_tun_ip "$pre")"; then
    log "TUN did not come up — last sing-box log lines:"
    tail -n 20 "$LOG" 2>/dev/null | sed 's/^/[sing-box] /' >&2 || true
    die "sing-box failed to bring up the TUN interface"
fi
echo "$iface" | sudo tee /run/devbox-vpn-iface >/dev/null
log "TUN up: $iface"
