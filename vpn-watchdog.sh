#!/bin/sh
VPN_IF="vpn_vpn"
VPNCMD="/opt/bin/vpncmd"
SPLIT_SCRIPT="/opt/etc/vpn-split.sh"
IPSET_FILE="/opt/etc/russia.ipset"
LOG="/opt/var/log/vpn-watchdog.log"
ACCOUNT="conn1"

# 1. Check if mangle rules exist (NDMS may wipe them)
if ! iptables -t mangle -L VPN_SPLIT -n >/dev/null 2>&1; then
    echo "$(date): Mangle rules missing, re-applying..." >> $LOG
    # Ensure ipset is loaded
    ipset list russia >/dev/null 2>&1 || ipset restore < $IPSET_FILE 2>/dev/null
    $SPLIT_SCRIPT start >> $LOG 2>&1
    exit 0
fi

# 2. Check if FORWARD rules exist
if ! iptables -C FORWARD -s 192.168.2.0/24 -o $VPN_IF -j ACCEPT 2>/dev/null; then
    echo "$(date): FORWARD rules missing, re-applying..." >> $LOG
    $SPLIT_SCRIPT start >> $LOG 2>&1
    exit 0
fi

# 3. Check if VPN interface exists
if ! ip link show $VPN_IF >/dev/null 2>&1; then
    echo "$(date): VPN interface missing, restarting..." >> $LOG
    /opt/etc/init.d/S99vpnsplit restart >> $LOG 2>&1
    exit 0
fi

# 4. Check VPN connectivity
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
