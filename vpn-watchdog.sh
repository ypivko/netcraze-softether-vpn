#!/bin/sh
VPN_IF="vpn_vpn"
VPNCMD="/opt/bin/vpncmd"
SPLIT_SCRIPT="/opt/etc/vpn-split.sh"
LOG="/opt/var/log/vpn-watchdog.log"
ACCOUNT="conn1"

if ! ip link show $VPN_IF >/dev/null 2>&1; then
    echo "$(date): VPN interface missing, restarting..." >> $LOG
    /opt/etc/init.d/S99vpnsplit restart >> $LOG 2>&1
    exit 0
fi

if ! ping -c2 -W5 -I $VPN_IF 192.168.30.1 >/dev/null 2>&1; then
    echo "$(date): VPN ping failed, reconnecting..." >> $LOG
    $VPNCMD /CLIENT localhost /CMD AccountDisconnect $ACCOUNT >/dev/null 2>&1
    sleep 2
    $VPNCMD /CLIENT localhost /CMD AccountConnect $ACCOUNT >/dev/null 2>&1
    sleep 10
    if ip link show $VPN_IF >/dev/null 2>&1; then
        $SPLIT_SCRIPT start >> $LOG 2>&1
    else
        echo "$(date): Full restart..." >> $LOG
        /opt/etc/init.d/S99vpnsplit restart >> $LOG 2>&1
    fi
fi
