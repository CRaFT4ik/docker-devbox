#!/bin/bash
# Minimal resolvconf replacement used by wg-quick inside containers
# without systemd-resolved. Handles the two invocations wg-quick makes:
#   resolvconf -a IFACE -m METRIC -x     (stdin: resolv.conf content)
#   resolvconf -d IFACE [-f]
set -e

ACTION=""
BACKUP=/etc/resolv.conf.wg-backup

while [[ $# -gt 0 ]]; do
    case "$1" in
        -a) ACTION=add; shift 2 ;;
        -d) ACTION=del; shift 2 ;;
        -m|-p) shift 2 ;;
        -x|-f) shift ;;
        *) shift ;;
    esac
done

case "$ACTION" in
    add)
        [ -f "$BACKUP" ] || cp -f /etc/resolv.conf "$BACKUP" 2>/dev/null || true
        cat > /etc/resolv.conf
        ;;
    del)
        if [ -f "$BACKUP" ]; then
            cp -f "$BACKUP" /etc/resolv.conf
            rm -f "$BACKUP"
        fi
        ;;
esac
