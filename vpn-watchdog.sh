#!/bin/sh
# PATH: /opt first! Stock NDMS /usr/sbin/ping always returns 1, which would make
# the watchdog think the tunnel is dead and reconnect it every run.
PATH=/opt/sbin:/opt/bin:/usr/sbin:/usr/bin:/sbin:/bin; export PATH
# VPN Watchdog — runs every 5 minutes via cron
# Re-applies rules that NDMS periodically wipes (FORWARD, NAT, fastnat)

VPN_IF="vpn_vpn"
VPNCMD="/opt/bin/vpncmd"
SPLIT="/opt/bin/vpn-split.sh"
LOG="/opt/var/log/vpn-watchdog.log"
ACCOUNT="vpn_account"

# Rotate log if > 100KB
[ -f "$LOG" ] && [ "$(wc -c < "$LOG" 2>/dev/null)" -gt 100000 ] && : > "$LOG"

# 1. Check VPN interface exists
if ! ip link show $VPN_IF >/dev/null 2>&1; then
    echo "$(date): vpn_vpn missing, full restart" >> $LOG
    /opt/etc/init.d/S99vpnsplit restart >> $LOG 2>&1
    exit 0
fi

# 2. Check VPN connectivity
# 3 pings: a single lost packet on a lossy path must not tear down a working tunnel
if ! ping -c3 -W3 192.168.30.1 >/dev/null 2>&1; then
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
