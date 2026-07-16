#!/bin/bash
# Fetch the Remnawave sing-box subscription JSON, guard its format, cache it.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${DIR}/common.sh"

CACHE_DIR=/var/lib/devbox/singbox
CACHE="${CACHE_DIR}/sub.cache.json"
OUT="${CACHE_DIR}/sub.json"
UA="SFA/1.11 (io.nekohasekai.sfa) sing-box"

mkdir -p "${CACHE_DIR}"
[ -n "${SUB_URL:-}" ] || die "SUB_URL is not set (required for VPN_MODE=singbox)"

tmp="$(mktemp)"
ct="$(curl -fL -sS -A "$UA" --max-time 20 -w '%{content_type}' -o "$tmp" "$SUB_URL" 2>/dev/null || true)"

if [[ "$ct" == *application/json* ]] && jq empty "$tmp" 2>/dev/null; then
    cp "$tmp" "$CACHE"                       # refresh last-good
    cp "$tmp" "$OUT"
    rm -f "$tmp"
    log "subscription fetched and cached"
elif [ -s "$tmp" ] && ! [[ "$ct" == *application/json* ]]; then
    rm -f "$tmp"
    die "panel did not return sing-box JSON (content-type: ${ct:-none}); check SUB_URL / User-Agent"
elif [ -f "$CACHE" ]; then
    rm -f "$tmp"
    cp "$CACHE" "$OUT"
    log "subscription channel unreachable — using cached config"
else
    rm -f "$tmp"
    die "subscription unreachable and no cached config on the volume"
fi
echo "$OUT"
