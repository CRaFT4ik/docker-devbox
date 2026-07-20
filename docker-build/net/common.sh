#!/bin/bash
# Shared helpers for the VPN mode scripts. Sourced, not executed.

log() { echo "[vpn] $*" >&2; }
die() { echo "[vpn] FATAL: $*" >&2; exit 1; }

# Point the container at a non-loopback resolver so DNS enters the TUN and is
# captured by sing-box (Docker's default 127.0.0.11 is loopback and leaks).
set_resolver() {
    printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' | sudo tee /etc/resolv.conf >/dev/null
    log "resolv.conf set to 1.1.1.1/8.8.8.8 for TUN DNS capture"
}

# Names of current tun* links, space-separated (empty if none).
snapshot_tuns() {
    ip -o link show 2>/dev/null | awk -F': ' '$2 ~ /^tun/ {print $2}' | tr '\n' ' '
}

# Wait for a tun* link not in $1 that has an inet address. Echo its name on
# success (return 0); return 1 on timeout so the caller can surface sing-box logs.
wait_for_new_tun_ip() {
    local pre="$1" i iface
    for i in $(seq 1 50); do            # 50 * 0.2s = 10s
        for iface in $(snapshot_tuns); do
            case " $pre " in *" $iface "*) continue;; esac   # was pre-existing
            if ip -o addr show dev "$iface" 2>/dev/null | grep -q 'inet '; then
                echo "$iface"; return 0
            fi
        done
        sleep 0.2
    done
    return 1
}
