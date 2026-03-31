#!/bin/sh
# VPN Split Tunneling for Netcraze Ultra (NDMS)
# NDMS periodically rebuilds ALL iptables chains — all rules must be re-applied.
# Watchdog runs every minute and calls "fix" to restore missing rules.

VPN_IF="vpn_vpn"
VPN_IP="192.168.30.11"
VPN_GW="192.168.30.1"
LAN="192.168.2.0/24"
TABLE_ID=100
MARK=0x1
SE_SERVER="188.137.180.77"
AWG_SERVER="81.91.176.218"
IPSET_FILE="/opt/etc/russia.ipset"

disable_fastnat() {
    echo 0 > /proc/sys/net/netfilter/nf_conntrack_fastnat 2>/dev/null
    echo 0 > /proc/sys/net/netfilter/nf_conntrack_fastroute 2>/dev/null
    echo 0 > /proc/sys/net/hwnat/extif_offload 2>/dev/null
}

load_ipset() {
    if ! ipset list russia >/dev/null 2>&1; then
        ipset create russia hash:net hashsize 16384 maxelem 65536
    fi
    if [ "$(ipset list russia 2>/dev/null | grep -c '^[0-9]')" -lt 1000 ]; then
        ipset flush russia 2>/dev/null
        ipset restore -exist < "$IPSET_FILE" 2>/dev/null
    fi
}

apply_all() {
    disable_fastnat
    load_ipset

    # mangle PREROUTING — mark non-Russia traffic
    if ! iptables -t mangle -C PREROUTING -s $LAN -j MARK --set-mark $MARK 2>/dev/null; then
        iptables -t mangle -A PREROUTING -s $LAN -m set --match-set russia dst -j RETURN
        iptables -t mangle -A PREROUTING -s $LAN -d $SE_SERVER -j RETURN
        iptables -t mangle -A PREROUTING -s $LAN -d $AWG_SERVER -j RETURN
        iptables -t mangle -A PREROUTING -s $LAN -j MARK --set-mark $MARK
    fi

    # filter FORWARD — allow VPN traffic
    iptables -C FORWARD -s $LAN -o $VPN_IF -j ACCEPT 2>/dev/null || \
        iptables -I FORWARD 1 -s $LAN -o $VPN_IF -j ACCEPT
    iptables -C FORWARD -i $VPN_IF -d $LAN -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || \
        iptables -I FORWARD 2 -i $VPN_IF -d $LAN -m state --state RELATED,ESTABLISHED -j ACCEPT

    # nat POSTROUTING — masquerade VPN traffic
    iptables -t nat -C POSTROUTING -o $VPN_IF -j MASQUERADE 2>/dev/null || \
        iptables -t nat -A POSTROUTING -o $VPN_IF -j MASQUERADE

    # mangle MSS clamp
    iptables -t mangle -C FORWARD -o $VPN_IF -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || \
        iptables -t mangle -A FORWARD -o $VPN_IF -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
    iptables -t mangle -C FORWARD -i $VPN_IF -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || \
        iptables -t mangle -A FORWARD -i $VPN_IF -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
    iptables -t mangle -C POSTROUTING -o $VPN_IF -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1200 2>/dev/null || \
        iptables -t mangle -A POSTROUTING -o $VPN_IF -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1200
}

case "$1" in
  start)
    echo "Starting VPN split tunneling..."
    ip addr show $VPN_IF 2>/dev/null | grep -q "$VPN_IP" || \
        ip addr add ${VPN_IP}/24 dev $VPN_IF
    ip rule add to $SE_SERVER table main priority 50 2>/dev/null
    ip rule add to $AWG_SERVER table main priority 51 2>/dev/null
    ip rule add fwmark $MARK table $TABLE_ID priority 100 2>/dev/null
    ip route replace default via $VPN_GW dev $VPN_IF table $TABLE_ID
    apply_all
    echo "VPN split tunneling started."
    ;;
  fix)
    apply_all
    ;;
  stop)
    echo "Stopping VPN split tunneling..."
    iptables -t mangle -D PREROUTING -s $LAN -m set --match-set russia dst -j RETURN 2>/dev/null
    iptables -t mangle -D PREROUTING -s $LAN -d $SE_SERVER -j RETURN 2>/dev/null
    iptables -t mangle -D PREROUTING -s $LAN -d $AWG_SERVER -j RETURN 2>/dev/null
    iptables -t mangle -D PREROUTING -s $LAN -j MARK --set-mark $MARK 2>/dev/null
    iptables -t mangle -D FORWARD -o $VPN_IF -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null
    iptables -t mangle -D FORWARD -i $VPN_IF -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null
    iptables -t mangle -D POSTROUTING -o $VPN_IF -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1200 2>/dev/null
    iptables -D FORWARD -s $LAN -o $VPN_IF -j ACCEPT 2>/dev/null
    iptables -D FORWARD -i $VPN_IF -d $LAN -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null
    iptables -t nat -D POSTROUTING -o $VPN_IF -j MASQUERADE 2>/dev/null
    ip rule del fwmark $MARK table $TABLE_ID 2>/dev/null
    ip rule del to $SE_SERVER table main 2>/dev/null
    ip rule del to $AWG_SERVER table main 2>/dev/null
    ip route del default table $TABLE_ID 2>/dev/null
    echo "VPN split tunneling stopped."
    ;;
  status)
    echo "=== FASTNAT ==="
    echo "fastnat=$(cat /proc/sys/net/netfilter/nf_conntrack_fastnat 2>/dev/null) fastroute=$(cat /proc/sys/net/netfilter/nf_conntrack_fastroute 2>/dev/null) hwnat=$(cat /proc/sys/net/hwnat/extif_offload 2>/dev/null)"
    echo "=== MANGLE PREROUTING ==="
    iptables -t mangle -L PREROUTING -n 2>&1 | grep -E "russia|MARK|188.137|81.91"
    echo "=== FORWARD ==="
    iptables -L FORWARD -n 2>&1 | grep vpn_vpn
    echo "=== NAT ==="
    iptables -t nat -L POSTROUTING -n 2>&1 | grep vpn_vpn
    echo "=== IPSET ==="
    echo "entries: $(ipset list russia 2>/dev/null | grep -c '^[0-9]')"
    echo "=== ROUTE ==="
    ip route show table $TABLE_ID 2>/dev/null
    echo "=== VPN ==="
    ip addr show $VPN_IF 2>/dev/null | grep inet
    ;;
  *)
    echo "Usage: $0 {start|stop|fix|status}"
    exit 1
    ;;
esac
