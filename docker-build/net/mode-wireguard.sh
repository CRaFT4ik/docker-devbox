#!/bin/bash
# VPN_MODE=wireguard — current behaviour: bring up every /etc/wireguard/*.conf.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${DIR}/common.sh"

mapfile -t confs < <(sudo find /etc/wireguard -maxdepth 1 -type f -name '*.conf' 2>/dev/null)
[ "${#confs[@]}" -gt 0 ] || die "no *.conf found in /etc/wireguard — place your WireGuard config in ./wireguard/"

first_iface=""
for cfg in "${confs[@]}"; do
    iface="$(basename "$cfg" .conf)"
    [ -z "$first_iface" ] && first_iface="$iface"
    log "bringing up WireGuard interface ${iface}..."
    sudo wg-quick up "${iface}" || log "wg-quick up ${iface} failed"
done
echo "$first_iface" | sudo tee /run/devbox-vpn-iface >/dev/null
