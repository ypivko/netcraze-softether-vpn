#!/bin/sh
# VPN Watchdog — runs every minute via cron
# Re-applies rules that NDMS periodically wipes (FORWARD, NAT, fastnat)

VPN_IF="vpn_vpn"
VPNCMD="/opt/bin/vpncmd"
SPLIT="/opt/etc/vpn-split.sh"
LOG="/opt/var/log/vpn-watchdog.log"
ACCOUNT="conn1"

# Rotate log if > 100KB
[ -f "$LOG" ] && [ "$(wc -c < "$LOG" 2>/dev/null)" -gt 100000 ] && : > "$LOG"

# 1. Check VPN interface exists
if ! ip link show $VPN_IF >/dev/null 2>&1; then
    echo "$(date): vpn_vpn missing, full restart" >> $LOG
    /opt/etc/init.d/S99vpnsplit restart >> $LOG 2>&1
    exit 0
fi

# 2. Check VPN connectivity
if ! ping -c1 -W3 192.168.30.1 >/dev/null 2>&1; then
    echo "$(date): VPN ping failed, reconnecting" >> $LOG
    $VPNCMD /CLIENT localhost /CMD AccountDisconnect $ACCOUNT >/dev/null 2>&1
    sleep 3
    $VPNCMD /CLIENT localhost /CMD AccountConnect $ACCOUNT >/dev/null 2>&1
    sleep 10
    if ip link show $VPN_IF >/dev/null 2>&1; then
        $SPLIT start >> $LOG 2>&1
    else
        /opt/etc/init.d/S99vpnsplit restart >> $LOG 2>&1
    fi
    exit 0
fi

# 3. Re-apply volatile rules (FORWARD, NAT, fastnat) — cheap, idempotent
$SPLIT fix 2>/dev/null
