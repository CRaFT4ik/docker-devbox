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

# Keep the host-gateway (and the local LAN) OUT of the TUN so the container can
# still reach services on the Docker host — the SOCKS proxy itself, the JetBrains
# MCP server, etc. sing-box's auto_route otherwise pulls host.docker.internal into
# the tunnel (table 2022) and every host-bound request loops back into the proxy.
#
# This reproduces exactly what the working WireGuard config did (wg-peer9.conf):
#   ip rule add to <host-gw>/24   lookup main pref 1
#   ip rule add to 192.168.0.0/16 lookup main pref 1
# pref 1 wins over auto_route's pref 9000+, so host/LAN traffic goes out eth0.
#
# The host-gateway address is read from /etc/hosts (Docker's host-gateway entry)
# via getent — NOT via DNS, so there is no chicken-and-egg with the proxy-routed
# resolver. Call this AFTER the TUN is up (auto_route has already run).
exclude_host_from_tun() {
    local gw net dst
    gw="$(getent hosts host.docker.internal | awk '{print $1; exit}')"
    if [ -z "$gw" ]; then
        log "WARN: host.docker.internal not in /etc/hosts; cannot exclude host-gateway from TUN"
        return 0
    fi
    net="${gw%.*}.0/24"                          # 0.250.250.254 -> 0.250.250.0/24
    for dst in "$net" 192.168.0.0/16; do
        sudo ip rule del to "$dst" lookup main pref 1 2>/dev/null || true   # idempotent
        sudo ip rule add to "$dst" lookup main pref 1
    done
    log "host-gateway ($net) and LAN (192.168.0.0/16) excluded from TUN -> direct via host NIC"
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
