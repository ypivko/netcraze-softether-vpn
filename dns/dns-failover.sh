#!/bin/sh
# DNS anti-poison failover -> /opt/bin/dns-failover.sh, cron every minute.
# Normal: tunnel resolver first (strict-order), Yandex as fallback.
# If the tunnel gateway does not answer, switch to Yandex only right away,
# otherwise dnsmasq keeps sending queries into the dead tunnel and browsers
# show "site not found" until the tunnel comes back.
PATH=/opt/sbin:/opt/bin:/usr/sbin:/usr/bin:/sbin:/bin; export PATH

VPN_DNS="192.168.30.1"      # resolver on the VPS, reachable through the tunnel
FALLBACK_DNS="77.88.8.8"    # direct resolver used while the tunnel is down
SF="/opt/etc/dnsmasq.servers"
LOG="/opt/var/log/vpn-watchdog.log"

pidof dnsmasq >/dev/null 2>&1 || { for s in /opt/etc/init.d/S*dnsmasq; do [ -x "$s" ] && "$s" start; done; }

if ping -c2 -W2 "$VPN_DNS" >/dev/null 2>&1; then
    WANT="server=$VPN_DNS
server=$FALLBACK_DNS"
else
    WANT="server=$FALLBACK_DNS"
fi

if [ "$(cat "$SF" 2>/dev/null)" != "$WANT" ]; then
    echo "$WANT" > "$SF"
    kill -HUP "$(pidof dnsmasq)" 2>/dev/null
    echo "$(date): dns -> $(echo $WANT | tr '\n' ' ')" >> "$LOG"
fi
